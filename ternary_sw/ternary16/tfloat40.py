"""Формат TFloat40 - троичная плавающая запятая (balanced ternary).

Спецификация (согласовано с аппаратной частью):
    Всего 20 тритов = 40 бит (2 бита на трит).
    Поля (старшие триты первыми):
        M  : 15 тритов мантиссы (radix 3, диапазон [1, 3) при нормализации)
        E  :  5 тритов экспоненты (bias = 60, диапазон -60..+121 -> 3^-60..3^+61)
    Значение:
        v = m * 3^(E - 60)
        m = M-триты как число с плавающей троичной точкой, [1,3)
    Кодирование тритов: +1->01, 0->00, -1->10, 11->ошибка.

    Кодирование всего числа: 40-битный int:
        [M:30 бит][E:10 бит]  (старшие биты - первые триты мантиссы)

Число также может находиться в состоянии "ошибка" (код 11 хотя бы в одном
трите мантиссы или экспоненты) - это аналог NaN.
"""
from __future__ import annotations
from typing import Tuple, Optional
import struct

from . import trits as T

# --- параметры формата ---
M_TRITS = 15
E_TRITS = 5
TOTAL_TRITS = M_TRITS + E_TRITS   # 20
TOTAL_BITS = TOTAL_TRITS * 2      # 40
E_BIAS = 60

# границы нормализованной мантиссы [1, 3)
M_MIN = 1.0
M_MAX = 3.0

# --- поля как битовые маски (40-битный int) ---
_E_SHIFT = 0
_M_SHIFT = E_TRITS * 2  # 10

MASK_E = (1 << (_M_SHIFT)) - 1
MASK_M = ((1 << (M_TRITS * 2)) - 1) << _M_SHIFT


class TFloatError(Exception):
    """Ошибка троичной арифметики (деление на ноль, NaN и т.п.)."""


class TFloat:
    """Неизменяемое значение TFloat40.

    Хранит: m_int (15 тритов мантиссы, упакованы в int), e_int (5 тритов
    экспоненты, упакованы), err (bool - флаг ошибки/NaN).
    """

    __slots__ = ("m_int", "e_int", "err")

    def __init__(self, m_int: int, e_int: int, err: bool = False):
        self.m_int = m_int
        self.e_int = e_int
        self.err = err

    # ---- фабрики ----
    @classmethod
    def from_float(cls, value: float) -> "TFloat":
        """Преобразовать Python float (в идеале float32-значение) в TFloat40.

        Конвенция: value = M * 3^(e-13), где M - целая мантисса в [3^12, 3^13)
        (нормализована), e - троичная экспонента. M хранится как 15 тритов.
        """
        if value != value or value in (float("inf"), float("-inf")):
            return cls(0, 0, err=True)
        if value == 0.0:
            return cls(0, 0, err=False)  # ноль: мантисса 0, экспонента 0

        neg = value < 0
        av = abs(value)

        # троичная экспонента: e = floor(log3(av))
        e = _ilog3(av)
        # целевая целая мантисса: M = av * 3^13 / 3^e  in [3^12, 3^13)
        # округление к ближайшему, half-up (совпадает с RTL: (x + 0.5) floor)
        M_target = int(av * (3.0 ** (M_TRITS - 2)) / (3.0 ** e) + 0.5)
        # M_target in [3^12, 3^13); возможен ровно 3^13 при av на границе -> сдвиг
        while M_target >= (3 ** (M_TRITS - 1)):
            M_target //= 3
            e += 1
        while M_target < (3 ** (M_TRITS - 2)) and e > -E_BIAS:
            M_target *= 3
            e -= 1

        m_trits = _int_to_trits(M_target, M_TRITS)
        if neg:
            m_trits = tuple(-t for t in m_trits)

        # ограничение экспоненты
        if e < -E_BIAS:
            return cls(0, 0)  # underflow
        if e > (E_BIAS + 121):
            raise TFloatError("overflow: экспонента вне диапазона")

        e_bias = e + E_BIAS
        return cls(
            T.pack(m_trits),
            T.pack(_encode_exp(e_bias)),
        )

    @classmethod
    def from_bits(cls, bits: int) -> "TFloat":
        """Декодировать 40-битное целое в TFloat."""
        if bits < 0 or bits >= (1 << TOTAL_BITS):
            raise ValueError(f"bits вне 40-битного диапазона: {bits}")
        m_int = (bits & MASK_M) >> _M_SHIFT
        e_int = bits & MASK_E
        err = _has_err(m_int, M_TRITS) or _has_err(e_int, E_TRITS)
        return cls(m_int, e_int, err)

    # ---- представления ----
    def to_bits(self) -> int:
        """Кодировать в 40-битное целое."""
        if self.err:
            # гарантировать код ошибки: мантисса = все 11
            m_bits = (T.CODE_ERR << (2 * (M_TRITS - 1)))
            m_bits = (m_bits | ((1 << (M_TRITS * 2)) - 1))  # все биты 1 -> все 11
            return (m_bits << _M_SHIFT) | self.e_int
        return ((self.m_int & ((1 << (M_TRITS * 2)) - 1)) << _M_SHIFT) | (self.e_int & MASK_E)

    def to_float(self) -> float:
        """Приближённое значение как Python float (float32-совместимое).

        value = M * 3^(E - bias - 13), где M - целая мантисса (15 тритов),
        M = sum t_i * 3^(13-i). Для нуля M=0.
        """
        if self.err:
            return float("nan")
        if self.m_int == 0:
            return 0.0
        m = _trits_value(T.unpack(self.m_int, M_TRITS))  # целое M
        e = _decode_exp(T.unpack(self.e_int, E_TRITS)) - E_BIAS
        v = m * (3.0 ** (e - (M_TRITS - 2)))
        # приводим к float32 для честного сравнения
        return struct.unpack("f", struct.pack("f", v))[0]

    def is_zero(self) -> bool:
        return not self.err and self.m_int == 0

    def is_error(self) -> bool:
        return self.err

    def __repr__(self) -> str:
        if self.err:
            return "TFloat(ERR)"
        return f"TFloat({self.to_float():.9g})"


# --- внутренние помощники ---

def _encode_exp(e_bias: int) -> Tuple[int, ...]:
    """Экспонента (bias) в 5 тритов balanced ternary (старший первым).

    e_bias in [0,121]. Кодируем значение в balanced ternary с диапазоном
    [-121,121] (5 тритов дают 3^5=243 комбинации). Для неотрицательного
    значения используем обычное разложение по модулю 3 с остатками 0,1,2,
    но трактуем остаток 2 как -1 с переносом (balanced digit).
    """
    if e_bias < 0 or e_bias > 121:
        raise TFloatError(f"экспонента вне диапазона: {e_bias}")
    out = []
    v = e_bias
    for _ in range(E_TRITS):
        r = v % 3
        v //= 3
        if r == 2:
            r = -1
            v += 1
        out.append(r)
    if v != 0:
        raise TFloatError("экспонента не помещается в 5 тритов")
    return tuple(reversed(out))


def _decode_exp(e_trits: Tuple[int, ...]) -> int:
    """Декодировать balanced ternary экспоненту (старший трит - знаковый)."""
    v = 0
    for t in e_trits:
        v = v * 3 + t
    return v


def _has_err(packed: int, n: int) -> bool:
    for i in range(n):
        if ((packed >> (2 * i)) & 0b11) == T.CODE_ERR:
            return True
    return False


def _trits_value(trits: Tuple[int, ...]) -> float:
    """Значение кортежа тритов как целое (мантисса).

    value = sum t[i] * 3^(n-1-i)   (старший трит i=0 весит 3^(n-1))
    """
    v = 0
    for t in trits:
        v = v * 3 + t
    return float(v)


def _int_to_trits(m: int, n: int) -> Tuple[int, ...]:
    """Разложить целое m в n тритов (balanced, старший первым).

    Согласовано с _trits_value: трит i (старший i=0) весит 3^(n-1-i),
    т.е. sum t[i]*3^(n-1-i) = m.
    Для |m| > (3^n - 1)/2 происходит переполнение (старшие отбрасываются).
    """
    out = [0] * n
    v = m
    for i in range(n - 1, -1, -1):
        r = v % 3
        v //= 3
        if r == 2:
            r = -1
            v += 1
        out[i] = r
    return tuple(out)


def _ilog3(x: float) -> int:
    """floor(log3(|x|)) для x>0. Использует логарифм по основанию 2 и коррекцию."""
    import math
    # log3(x) = log2(x)/log2(3)
    e = int(math.floor(math.log2(abs(x)) / math.log2(3.0)))
    # коррекция из-за float
    if 3.0 ** (e + 1) <= abs(x):
        e += 1
    elif 3.0 ** e > abs(x):
        e -= 1
    return e
