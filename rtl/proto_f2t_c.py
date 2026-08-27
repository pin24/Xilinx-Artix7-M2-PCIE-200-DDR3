# -*- coding: utf-8 -*-
"""Прототип C: точное построение D (одно направление) + round-деление бит-за-битом."""
import struct, random
import sys
sys.path.insert(0, r'C:\A7_M2\EXAMPLES\XDMA_DDR3\rtl')
import proto_f2t_pipe as P
from ternary.tfloat40 import TFloat

W = 128
Q = 64
P3_13 = 3 ** 13
P3_14 = 3 ** 14
MASK = (1 << W) - 1


def f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]


def f32_bits(x):
    return struct.unpack('I', struct.pack('f', x))[0]


def build_D(val_q, NSTAGES=61):
    D = 1 << Q
    e3_off = 60
    dir_up = (val_q >= (1 << Q))
    for _ in range(NSTAGES):
        if dir_up:
            if val_q >= D * 3:
                D *= 3
                e3_off += 1
        else:
            if val_q < D:
                D //= 3
                e3_off -= 1
    return D, e3_off


def div_round_bitwise(X, D):
    """M = (X + D/2) / D (floor) бит-за-битом, модулярно 2^128 (как RTL)."""
    Xr = (X + (D >> 1)) & MASK
    q = 0
    rem = 0
    for i in range(W - 1, -1, -1):
        rem = (rem << 1) | ((Xr >> i) & 1)
        if rem >= D:
            rem -= D
            q |= (1 << i)
    return q


def f2t_c_bits(v):
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

    if value_p3 == 0:
        return (0, 0)

    D, e3_off = build_D(val_q)
    M = div_round_bitwise(value_p3, D)
    e3n_off = e3_off
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
        c = f2t_c_bits(v32)
        if r[0] in ('zero', 'err') or c[0] in ('zero', 'err'):
            if r != c:
                bad += 1
                if bad <= 10:
                    print(f"  [{label}] SPECIAL {v}: ref={r} c={c}")
            continue
        n += 1
        rp = pack(r[0], r[1])
        cp = pack(c[0], c[1])
        if rp != cp:
            bad += 1
            if bad <= 15:
                print(f"  [{label}] MISMATCH {v}: ref={hex(rp)} c={hex(cp)} Mref={r[0]} Mc={c[0]} eoff={r[1]}")
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
        e = random.uniform(-30, 40)
        rvals.append(f32(random.uniform(0.1, 10.0) * (3.0 ** e)))
    bad += check(rvals, "random")
    print("ИТОГО несовпадений:", bad)


if __name__ == "__main__":
    main()
