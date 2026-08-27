# -*- coding: utf-8 -*-
"""Python-модель байтовых (4 трита) операций - эталон для tbyte_add/tbyte_mul.

Кодирование байта: 4 трита, трит i -> биты [2i+1:2i] (i=0 младший).
  +1 -> 0b01, 0 -> 0b00, -1 -> 0b10, 11 -> ERR.
Значение байта (balanced): sum t_i * 3^i.
"""
from __future__ import annotations

CODE_P1 = 0b01
CODE_Z0 = 0b00
CODE_N1 = 0b10
CODE_ERR = 0b11


def code_to_trit(c: int) -> int:
    return {CODE_P1: 1, CODE_Z0: 0, CODE_N1: -1}.get(c, 0)


def trit_to_code(t: int) -> int:
    return {1: CODE_P1, 0: CODE_Z0, -1: CODE_N1}[t]


def unpack_byte(b: int) -> list:
    """Байт -> 4 трита (индекс 0 = младший трит)."""
    return [code_to_trit((b >> (2 * i)) & 3) for i in range(4)]


def pack_trits(t: list) -> int:
    """4 трита (индекс 0 младший) -> байт."""
    v = 0
    for i, tv in enumerate(t):
        v |= trit_to_code(tv) << (2 * i)
    return v


def byte_value(b: int) -> int:
    """Значение байта (balanced): sum t_i * 3^i."""
    v = 0
    for i, t in enumerate(unpack_byte(b)):
        v += t * (3 ** i)
    return v


def add_bytes(a: int, b: int, carry_in: int = 0) -> tuple:
    """Сложение двух байтов + перенос -> (результат-байт, carry_out)."""
    t = [0] * 4
    carry = carry_in
    for i in range(4):
        s = code_to_trit((a >> (2 * i)) & 3) + code_to_trit((b >> (2 * i)) & 3) + carry
        if s > 1:
            carry = 1
            s -= 3
        elif s < -1:
            carry = -1
            s += 3
        else:
            carry = 0
        t[i] = s
    return pack_trits(t), carry


def mul_bytes(a: int, b: int) -> int:
    """Умножение байта x байта -> до 8 тритов (16-бит результат)."""
    ma = byte_value(a)
    mb = byte_value(b)
    m = ma * mb
    # разложение в 8 тритов (balanced), младший первым
    out = [0] * 8
    v = m
    for i in range(8):
        r = v % 3
        v //= 3
        if r == 2:
            r = -1
            v += 1
        out[i] = r
    # упаковка: трит i -> биты [2i+1:2i]
    res = 0
    for i, tv in enumerate(out):
        res |= trit_to_code(tv) << (2 * i)
    return res


def mul_bytes_value(a: int, b: int) -> int:
    """Значение произведения (для сверки)."""
    return byte_value(a) * byte_value(b)


def mul_bytes_trits_value(res: int) -> int:
    """Значение 8-тритного результата (для сверки)."""
    v = 0
    for i in range(8):
        v += code_to_trit((res >> (2 * i)) & 3) * (3 ** i)
    return v


if __name__ == "__main__":
    import random
    # add: свойство аддитивности
    random.seed(1)
    bad = 0
    for _ in range(20000):
        a = random.randrange(0, 256)
        b = random.randrange(0, 256)
        cin = random.choice([-1, 0, 1])
        r, cout = add_bytes(a, b, cin)
        total = byte_value(a) + byte_value(b) + cin
        # результат: r + cout*3^4 == total (если не переполняет 4 трита)
        if byte_value(r) + cout * 81 != total:
            bad += 1
            if bad <= 3:
                print("ADD bad", a, b, cin, byte_value(r), cout, total)
    print("add random bad:", bad)
    # mul
    bad = 0
    for _ in range(20000):
        a = random.randrange(0, 256)
        b = random.randrange(0, 256)
        r = mul_bytes(a, b)
        if mul_bytes_trits_value(r) != mul_bytes_value(a, b):
            bad += 1
            if bad <= 3:
                print("MUL bad", a, b, mul_bytes_value(a, b), mul_bytes_trits_value(r))
    print("mul random bad:", bad)
