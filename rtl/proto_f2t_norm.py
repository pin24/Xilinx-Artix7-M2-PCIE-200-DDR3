# -*- coding: utf-8 -*-
"""Прототип B: нормализация value_p3 с round-half-up /3, потом round /2^64."""
import struct, random, math
import sys
sys.path.insert(0, r'C:\A7_M2\EXAMPLES\XDMA_DDR3\rtl')
import proto_f2t_pipe as P
from ternary.tfloat40 import TFloat

W = 128
Q = 64
P3_13 = 3 ** 13
P3_14 = 3 ** 14
MASK = (1 << W) - 1
LO = P3_13 << Q   # 3^13 * 2^64
HI = P3_14 << Q   # 3^14 * 2^64


def f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]


def f32_bits(x):
    return struct.unpack('I', struct.pack('f', x))[0]


def round_hu_div3(x):
    # round-half-up деление на 3 для x >= 0: (x + 1) // 3
    return (x + 1) // 3


def norm_normalize(X, NSTAGES=64):
    """Последовательная нормализация value_p3 к [3^13*2^64, 3^14*2^64)."""
    e = 0
    for _ in range(NSTAGES):
        if X >= HI:
            X = round_hu_div3(X)
            e += 1
        elif X < LO:
            X = X * 3
            e -= 1
    return X, e


def f2t_norm_bits(v):
    """Алгоритм B (нормализация + round /2^64)."""
    bits = f32_bits(v)
    sign = (bits >> 31) & 1
    e2 = (bits >> 23) & 0xFF
    mant = bits & 0x7FFFFF
    if e2 == 0 and mant == 0:
        return ("zero",)
    if e2 == 0xFF:
        return ("err",)
    m24 = (1 << 23) | mant
    S = e2 - 150
    shift = S + Q
    if shift >= 0:
        shamt = shift
        val_q = (m24 << shamt) & MASK if shamt < W else 0
    else:
        shamt = -shift
        val_q = (m24 >> shamt) if shamt < W else 0
    value_p3 = (val_q * P.P3_13) & MASK

    # special: value_p3 == 0 (underflow или val_q==0)
    if value_p3 == 0:
        return (0, 0)  # ноль

    X, _ = norm_normalize(value_p3)
    # round-half-up деление на 2^64
    M = (X + (1 << 63)) >> Q
    # эталон дополнительно нормализует (безопасно)
    e3n_off = 60  # после норм e3 ~ 0, e3_off ~ 60; уточним по X? не нужно, эталон нормирует M
    M0 = M
    for _ in range(8):
        if M >= P3_14:
            M //= 3
            e3n_off += 1
    for _ in range(8):
        if M < P3_13 and e3n_off > 0:
            M *= 3
            e3n_off -= 1
    if sign:
        M = -M
    return (M, e3n_off - 60)


def pack(M, e3n):
    if M == 0:
        return 0
    def to_trits(m, n):
        out = [0] * n
        v = m
        for i in range(n - 1, -1, -1):
            r = v % 3
            v //= 3
            if r == 2:
                r = -1
                v += 1
            out[i] = r
        return out
    mt = to_trits(M, 15)
    et = to_trits(e3n + 60, 5)
    mbits = 0
    for t in mt:
        mbits = (mbits << 2) | {1: 1, -1: 2, 0: 0}[t]
    ebits = 0
    for t in et:
        ebits = (ebits << 2) | {1: 1, -1: 2, 0: 0}[t]
    return (mbits << 10) | ebits


def check(vals, label):
    bad = 0
    n = 0
    for v in vals:
        v32 = f32(v)
        r = P.f2t_ref_bits(v32)
        b = f2t_norm_bits(v32)
        if r[0] in ('zero', 'err') or b[0] in ('zero', 'err'):
            if r != b:
                bad += 1
                if bad <= 10:
                    print(f"  [{label}] SPECIAL {v}: ref={r} norm={b}")
            continue
        n += 1
        rp = pack(r[0], r[1])
        bp = pack(b[0], b[1])
        if rp != bp:
            bad += 1
            if bad <= 15:
                print(f"  [{label}] MISMATCH {v}: ref={hex(rp)} norm={hex(bp)} Mref={r[0]} Mnorm={b[0]}")
    print(f"[{label}] проверено {n}, несовпадений {bad}")
    return bad


def main():
    vals = [0.0, 1.0, -1.0, 3.0, -3.0, 0.5, -0.5, 0.3333333333, 1.5, 2.0,
            2.5, 0.1, -0.1, 100.0, -100.0, 0.001, 1e-5, 1234.5678, -9876.5432,
            42.0, -42.0, 0.9999, 1.0001, 2.9999, 0.25, 4.0, 0.75, 7.5,
            0.0001, 123456.0, -0.00001, 3.14159, 2.71828, 1e10, 1e-10]
    bad = check(vals, "fixed")
    random.seed(7)
    rvals = []
    for _ in range(1500):
        e = random.uniform(-33, 60)
        rvals.append(f32(random.uniform(0.1, 10.0) * (3.0 ** e)))
    bad += check(rvals, "random")
    print("ИТОГО несовпадений:", bad)


if __name__ == "__main__":
    main()
