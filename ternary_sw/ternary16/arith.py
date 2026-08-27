"""Арифметические операции TFloat40 - эталон для аппаратной реализации.

Единая конвенция представления:
    value = M * 3^(E - 60 - 13) = M * 3^(e - 13)
где
    M  - целая мантисса (15 тритов, balanced), диапазон норм. [-3^13, 3^13)
    E  - 5 тритов, bias 60;  e = E - 60  (троичная экспонента)
    M_TRITS = 15, масштаб мантиссы 3^13  (т.е. старший трит весит 3^12)

Операции:
  add/sub : выравнивание экспонент сдвигом M на 3^k, сложение мантисс с переносом
  mul     : P/N-разложение -> два двоичных умножения (в RTL - DSP48E1)
  div     : поразрядное деление мантисс (полная точность)
После операции результат нормализуется: M in [3^12, 3^13) и округляется.
"""
from __future__ import annotations
from typing import Tuple

from . import trits as T
from .tfloat40 import (
    TFloat, TFloatError, M_TRITS, E_TRITS, E_BIAS,
    _trits_value, _decode_exp, _encode_exp,
)

# масштаб мантиссы: норм. целая мантисса M in [3^13, 3^14)
# value = M * 3^(e-13)
M_SCALE = 3 ** (M_TRITS - 2)   # 3^13
M_NORM_MIN = M_SCALE           # 3^13
M_NORM_MAX = 3 * M_SCALE       # 3^14


def _m_trits(a: TFloat) -> Tuple[int, ...]:
    return T.unpack(a.m_int, M_TRITS)


def _e_raw(a: TFloat) -> int:
    return _decode_exp(T.unpack(a.e_int, E_TRITS)) - E_BIAS


def _neg_tf(a: TFloat) -> TFloat:
    if a.err:
        return a
    m = tuple(-t for t in _m_trits(a))
    return TFloat(T.pack(m), a.e_int)


def _shift_right_int(m: int, k: int) -> int:
    """m / 3^k (цело) с округлением к ближайшему целому."""
    if k <= 0:
        return m
    q = abs(m) // (3 ** k)
    r = abs(m) % (3 ** k)
    if r * 2 >= 3 ** k:
        q += 1
    return q if m >= 0 else -q


def _round_int_to_trits(m: int) -> Tuple[int, ...]:
    """Округлить целое m к 15 тритам (balanced). m может быть любым int."""
    # разложение в balanced ternary
    out = [0] * M_TRITS
    v = m
    for i in range(M_TRITS - 1, -1, -1):
        r = v % 3
        v //= 3
        if r == 2:
            r = -1
            v += 1
        out[i] = r
    # остаток v игнорируем (переполнение старших тритов)
    return tuple(out)


def _norm_raw(m: int, e: int, err: bool = False) -> TFloat:
    """Нормализовать (m, e): value = m * 3^(e-13). M норм. в [3^12, 3^13)."""
    if err:
        return TFloat(0, 0, err=True)
    if m == 0:
        return TFloat(0, 0)
    av = abs(m)
    # нормализация
    while av >= M_NORM_MAX:
        av //= 3
        e += 1
        if e > (E_BIAS + 121):
            raise TFloatError("overflow")
    while av < M_NORM_MIN:
        av *= 3
        e -= 1
        if e < -E_BIAS:
            return TFloat(0, 0)  # underflow
    av = _round_int_to_trits(av)
    m_trits = tuple(-t for t in av) if m < 0 else av
    e_bias = e + E_BIAS
    if e_bias < 0:
        return TFloat(0, 0)
    if e_bias > 121:
        raise TFloatError("overflow")
    return TFloat(T.pack(m_trits), T.pack(_encode_exp(e_bias)))


def _add_m_int(a: int, b: int) -> int:
    """Сложение целых мантисс (простое int; для эмулятора достаточно).
    В RTL - поразрядный balanced-сумматор с переносом, результат тот же."""
    return a + b


def _mul_m_int(a: int, b: int) -> int:
    """Умножение целых мантисс. В RTL - P/N-разложение + DSP, здесь int."""
    return a * b


def _add_tf(a: TFloat, b: TFloat) -> TFloat:
    if a.err or b.err:
        return TFloat(0, 0, err=True)
    if a.is_zero():
        return b
    if b.is_zero():
        return a
    ea = _e_raw(a)
    eb = _e_raw(b)
    ma = _trits_value(_m_trits(a))
    mb = _trits_value(_m_trits(b))
    if ea > eb:
        e = ea
        mb = _shift_right_int(int(mb), ea - eb)
    elif eb > ea:
        e = eb
        ma = _shift_right_int(int(ma), eb - ea)
    else:
        e = ea
    ms = _add_m_int(int(ma), int(mb))
    return _norm_raw(ms, e)


def _mul_tf(a: TFloat, b: TFloat) -> TFloat:
    if a.err or b.err:
        return TFloat(0, 0, err=True)
    if a.is_zero() or b.is_zero():
        return TFloat(0, 0)
    ea = _e_raw(a)
    eb = _e_raw(b)
    ma = _trits_value(_m_trits(a))
    mb = _trits_value(_m_trits(b))
    # m = ma*mb; value = (ma*3^-13)*(mb*3^-13)*3^(ea+eb) = ma*mb*3^(ea+eb-26)
    # нормализация: value = M*3^(e-13) => M=ma*mb/3^13, e=ea+eb-13
    mp = _mul_m_int(int(ma), int(mb))
    return _norm_raw(mp, ea + eb - (M_TRITS - 2))


def _div_tf(a: TFloat, b: TFloat) -> TFloat:
    if a.err or b.err:
        return TFloat(0, 0, err=True)
    if b.is_zero():
        raise TFloatError("деление на ноль")
    if a.is_zero():
        return TFloat(0, 0)
    ea = _e_raw(a)
    eb = _e_raw(b)
    ma = _trits_value(_m_trits(a))
    mb = _trits_value(_m_trits(b))
    sign = -1 if (ma < 0) != (mb < 0) else 1
    av = abs(int(ma))
    bv = abs(int(mb))
    # value = (ma/mb)*3^(ea-eb) = M*3^(e-13) => M = ma*3^13/mb, e = ea-eb
    num = av * M_SCALE
    q = num // bv
    r = num % bv
    if r * 2 >= bv:
        q += 1
    q = q if sign >= 0 else -q
    return _norm_raw(q, ea - eb)


# --- публичный API ---
def add(a: TFloat, b: TFloat) -> TFloat:
    return _add_tf(a, b)


def sub(a: TFloat, b: TFloat) -> TFloat:
    return _add_tf(a, _neg_tf(b))


def mul(a: TFloat, b: TFloat) -> TFloat:
    return _mul_tf(a, b)


def div(a: TFloat, b: TFloat) -> TFloat:
    return _div_tf(a, b)


def neg(a: TFloat) -> TFloat:
    return _neg_tf(a)
