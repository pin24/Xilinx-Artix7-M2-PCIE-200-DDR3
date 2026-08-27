"""Тритовая арифметика в представлении balanced ternary ({-1,0,+1}).

Кодирование трита в 2 бита (согласовано с аппаратным форматом):
    +1  -> 0b01
     0  -> 0b00
    -1  -> 0b10
    ERR -> 0b11   (флаг ошибки / NaN-подобное значение)

Числа хранятся в Python как int (value -1,0,+1) либо как 2-битный код.
Все функции строго детерминированы - это эталон для RTL.
"""
from __future__ import annotations
from typing import Tuple

# --- 2-битные коды ---
CODE_P1 = 0b01
CODE_Z0 = 0b00
CODE_N1 = 0b10
CODE_ERR = 0b11

# --- таблицы перекодировки ---
CODE_TO_TRIT = {CODE_P1: 1, CODE_Z0: 0, CODE_N1: -1}
TRIT_TO_CODE = {1: CODE_P1, 0: CODE_Z0, -1: CODE_N1}


def trit_to_code(t: int) -> int:
    """Трит (-1,0,+1) -> 2-битный код. ValueError для недопустимых."""
    if t not in (-1, 0, 1):
        raise ValueError(f"недопустимый трит: {t}")
    return TRIT_TO_CODE[t]


def code_to_trit(code: int) -> int:
    """2-битный код -> трит (-1,0,+1). ERR (11) -> None."""
    if code == CODE_ERR:
        return None
    try:
        return CODE_TO_TRIT[code]
    except KeyError:
        raise ValueError(f"недопустимый 2-битный код: {code:02b}")


def pack(trits: Tuple[int, ...]) -> int:
    """Упаковать кортеж тритов (старший первым) в 2*N-битное целое."""
    v = 0
    for t in trits:
        v = (v << 2) | trit_to_code(t)
    return v


def unpack(bits: int, n: int) -> Tuple[int, ...]:
    """Распаковать 2*N-битное целое в кортеж тритов (старший первым)."""
    out = []
    for i in range(n - 1, -1, -1):
        code = (bits >> (2 * i)) & 0b11
        t = code_to_trit(code)
        if t is None:
            t = 0  # ошибка трактуется как 0 в распаковке (флаг отслеживается отдельно)
        out.append(t)
    return tuple(out)


def add_trits(a: int, b: int, carry_in: int = 0) -> Tuple[int, int]:
    """Сложение двух тритов + перенос.

    Возвращает (сумма_трит, перенос_наружу).
    Полная таблица: a,b,cin in {-1,0,1}; сумма в [-3,3] -> трит + перенос.
    """
    s = a + b + carry_in
    # balanced ternary: перенос = sign(s) если |s|>1
    if s > 1:
        return (s - 3, 1)
    if s < -1:
        return (s + 3, -1)
    return (s, 0)


def sub_trits(a: int, b: int, borrow_in: int = 0) -> Tuple[int, int]:
    """Вычитание тритов: a - b - borrow_in. Возвращает (разность, заём)."""
    s = a - b - borrow_in
    if s > 1:
        return (s - 3, 1)
    if s < -1:
        return (s + 3, -1)
    return (s, 0)


def neg_trit(t: int) -> int:
    """Отрицание трита (симметрия: -(-1)=1, -(1)=-1, 0=0)."""
    return -t


def mul_trits(a: int, b: int) -> int:
    """Произведение тритов: a*b (значение в {-1,0,1})."""
    return a * b


def ternary_value(trits: Tuple[int, ...], radix_point: int = 0) -> float:
    """Числовое значение кортежа тритов (старший первым).

    value = sum(t[i] * 3^(len-1-i-radix_point))
    """
    n = len(trits)
    val = 0.0
    for i, t in enumerate(trits):
        val += t * (3.0 ** (n - 1 - i - radix_point))
    return val
