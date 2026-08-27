# -*- coding: utf-8 -*-
"""Прототип D: оптимизированный F2T (up: 64-бит деление, down: умножение)."""
import struct, random, sys
sys.path.insert(0, r'C:\A7_M2\EXAMPLES\XDMA_DDR3\rtl')
import proto_f2t_pipe as P

W = 128
Q = 64
MASK = (1 << W) - 1
P3_13 = 3 ** 13
P3_14 = 3 ** 14


def f32(x): return struct.unpack('f', struct.pack('f', x))[0]
def f32_bits(x): return struct.unpack('I', struct.pack('f', x))[0]


def build_D_opt(val_q, NSTAGES=61):
    """Up: D_hi=3^e3 (64), Down: D_lo=floor(2^64/3^k) (64) + счётчик."""
    val_q128 = val_q & MASK
    dir_up = (val_q >= (1 << Q))
    if dir_up:
        D_hi = 1
        e3_off = 60
        for _ in range(NSTAGES):
            # условие: val_q >= (D_hi*3) << 64  <=> val_q[127:64] >= D_hi*3
            vq_hi = val_q128 >> Q
            if vq_hi >= D_hi * 3:
                D_hi *= 3
                e3_off += 1
        return ('up', D_hi, e3_off, None)
    else:
        D_lo = (1 << Q)  # 2^64, но down старт: 2^64/... начнём с (1<<Q)
        e3_off = 60
        for _ in range(NSTAGES):
            # условие: val_q < D_lo  (val_q < 2^64)
            if val_q128 < D_lo:
                D_lo //= 3
                e3_off -= 1
        return ('down', None, e3_off, D_lo)


def div_round_hi(X, D_hi, N=128):
    """Бит-за-битом деление X / (D_hi << 64): сравнение старших 64 бит."""
    Xr = (X + (D_hi << 63)) & MASK   # X + 3^e3*2^63 (mod 2^128, как RTL)
    q = 0
    rem = 0  # 128 бит, но сравниваем/вычитаем старшие 64
    for i in range(W - 1, -1, -1):
        rem = ((rem << 1) | ((Xr >> i) & 1)) & MASK
        rem_hi = rem >> Q
        if rem_hi >= D_hi:
            rem = ((rem_hi - D_hi) << Q) | (rem & ((1 << Q) - 1))
            q |= (1 << i)
    return q


def div_round_bitwise(X, D):
    """M = (X + D/2) / D (floor) бит-за-битом, модулярно 2^128 (как RTL)."""
    Xr = (X + (D >> 1)) & MASK
    q = 0
    rem = 0
    for i in range(W - 1, -1, -1):
        rem = ((rem << 1) | ((Xr >> i) & 1)) & MASK
        if rem >= D:
            rem -= D
            q |= (1 << i)
    return q


def f2t_opt_bits(v, dbg=False):
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

    mode, D_hi, e3_off, D_lo = build_D_opt(val_q)

    if mode == 'up':
        M = div_round_hi(value_p3, D_hi)
    else:
        # бит-за-битом деление value_p3 / D_lo (D_lo < 2^64), с round
        # M = (value_p3 + D_lo/2) / D_lo  (mod 2^128, как эталон)
        M = div_round_bitwise(value_p3, D_lo)

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
        o = f2t_opt_bits(v32)
        if r[0] in ('zero', 'err') or o[0] in ('zero', 'err'):
            if r != o:
                bad += 1
                if bad <= 8:
                    print(f"  [{label}] SPECIAL {v}: ref={r} opt={o}")
            continue
        n += 1
        rp = pack(r[0], r[1])
        op = pack(o[0], o[1])
        if rp != op:
            bad += 1
            if bad <= 12:
                print(f"  [{label}] MISMATCH {v}: ref={hex(rp)} opt={hex(op)} Mref={r[0]} Mopt={o[0]} e={r[1]}")
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
        e = random.uniform(-30, 24)
        rvals.append(f32(random.uniform(0.1, 10.0) * (3.0 ** e)))
    bad += check(rvals, "random")
    print("ИТОГО:", bad)


if __name__ == "__main__":
    main()
