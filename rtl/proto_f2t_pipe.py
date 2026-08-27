# -*- coding: utf-8 -*-
"""Прототип конвейерного F2T: проверка алгоритма против эталона и Python."""
import struct
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw"))
from ternary.tfloat40 import TFloat

W = 128
Q = 64
P3_13 = 3 ** 13          # 1594323
P3_14 = 3 ** 14          # 4782969
MASK = (1 << W) - 1


def f32_bits(x):
    return struct.unpack("I", struct.pack("f", x))[0]


def f32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


def pow3_table():
    pow3 = [0] * 122
    pow3[60] = 1 << Q
    for g in range(59, -1, -1):
        pow3[g] = pow3[g + 1] // 3
    for g in range(61, 122):
        pow3[g] = pow3[g - 1] * 3
    return pow3


POW3 = pow3_table()


def f2t_ref_bits(x):
    """Точная копия f32_to_tf40.sv -> (M, e3n) или (None,None) для спецслучаев."""
    bits = f32_bits(x)
    sign = (bits >> 31) & 1
    e2 = (bits >> 23) & 0xFF
    mant = bits & 0x7FFFFF
    if e2 == 0 and mant == 0:
        return ("zero",)
    if e2 == 0xFF:
        return ("err",)
    m24 = (1 << 23) | mant
    shift = e2 - 150 + Q
    if shift >= 0:
        shamt = shift
        val_q = (m24 << shamt) & MASK if shamt < W else 0
    else:
        shamt = -shift
        val_q = (m24 >> shamt) if shamt < W else 0
    value_p3 = (val_q * P3_13) & MASK
    e3_off = 0
    for i in range(0, 121):
        if val_q >= POW3[i] and val_q < POW3[i + 1]:
            e3_off = i
    if value_p3 >= POW3[121]:
        e3_off = 121
    # модулярная арифметика как в RTL (128-бит): сложение value_p3 + D/2 теряет перенос
    M_raw = ((value_p3 + (POW3[e3_off] >> 1)) & MASK) // POW3[e3_off]
    M = M_raw
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
    e3n = e3n_off - 60
    return (M, e3n)


def f2t_pipe_bits(x, dbg=False):
    """Мой конвейерный алгоритм."""
    bits = f32_bits(x)
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
    value_p3 = (val_q * P3_13) & MASK

    LOG3_2 = 41338  # round(log2(e)*2^16 * ... 0.63093*65536)
    e3_est = ((S + 23) * LOG3_2) >> 16

    # построение D от 2^64: 61 стадия до e3_est (только вверх *3)
    D = 1 << Q
    cur = 0
    n_build = 61
    for _ in range(n_build):
        if cur < e3_est:
            D = D * 3
            cur += 1
        elif cur > e3_est:
            D //= 3
            cur -= 1
    # коррекция: D == pow3_for_e[cur+60]; ищем точный e3_off
    for _ in range(8):
        if val_q >= D * 3:
            D = D * 3
            cur += 1
        elif val_q < D:
            D //= 3
            cur -= 1
    e3_off = cur + 60

    # round-деление бит-за-битом: M = (X + D/2) / D
    X = value_p3 + (D >> 1)
    q = 0
    rem = 0
    for i in range(W - 1, -1, -1):
        rem = (rem << 1) | ((X >> i) & 1)
        if rem >= D:
            rem -= D
            q |= (1 << i)
    M = q
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
    e3n = e3n_off - 60
    if dbg:
        return (M, e3n, e3_est, e3_off, e3n_off, value_p3, D)
    return (M, e3n)


def main():
    vals = [0.0, 1.0, -1.0, 3.0, -3.0, 0.5, -0.5, 0.3333333333, 1.5, 2.0,
            2.5, 0.1, -0.1, 100.0, -100.0, 0.001, 1e-5, 1234.5678, -9876.5432,
            42.0, -42.0, 0.9999, 1.0001, 2.9999, 0.25, 4.0, 0.75, 7.5,
            0.0001, 123456.0, -0.00001, 3.14159, 2.71828, 1e10, 1e-10]
    bad = 0
    for v in vals:
        v32 = f32(v)
        r = f2t_ref_bits(v32)
        p = f2t_pipe_bits(v32)
        t = TFloat.from_float(v32)
        tbits = t.to_bits()
        # собрать 40-бит из (M, e3n) для сравнения с Python
        def pack(M, e3n):
            if M == 0:
                return 0
            # M уже знаковое целое с тритами; e3n -> E bias
            # разложение в balanced ternary (как int_to_trits)
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
            for t_ in mt:
                code = {1: 1, -1: 2, 0: 0}[t_]
                mbits = (mbits << 2) | code
            ebits = 0
            for t_ in et:
                code = {1: 1, -1: 2, 0: 0}[t_]
                ebits = (ebits << 2) | code
            return (mbits << 10) | ebits

        rbits = ("zero",) if r[0] == "zero" else ("err",) if r[0] == "err" else pack(r[0], r[1])
        pbits = ("zero",) if p[0] == "zero" else ("err",) if p[0] == "err" else pack(p[0], p[1])
        tbits2 = ("zero",) if tbits == 0 else tbits
        ok_ref = (rbits == tbits2)
        ok_pipe = (pbits == tbits2)
        ok_rp = (rbits == pbits)
        if not (ok_ref and ok_pipe and ok_rp):
            bad += 1
            print(f"[{v32}] py={tbits:010x} ref={rbits} pipe={pbits} ok_ref={ok_ref} ok_pipe={ok_pipe}")
    print(f"Проверено {len(vals)} значений, несовпадений {bad}")
    # отладочные детали на паре значений
    for v in [1.0, 0.1, 1234.5678, 1e10, 1e-10]:
        d = f2t_pipe_bits(f32(v), dbg=True)
        print(f"  dbg {v}: e3_est={d[2]} e3_off={d[3]} e3n={d[4]}")


if __name__ == "__main__":
    main()
