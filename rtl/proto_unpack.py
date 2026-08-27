# -*- coding: utf-8 -*-
"""Распаковка RTL-результатов и сравнение с Python для отладки."""
import struct, sys
sys.path.insert(0, r'C:\A7_M2\EXAMPLES\XDMA_DDR3\rtl')
import proto_f2t_c as C

def unpack_rtl(bits):
    # bits: 40 бит, мантисса старшие 30 (15 тритов по 2 бита), экспонента 10 (5 тритов)
    m = (bits >> 10) & ((1 << 30) - 1)
    e = bits & ((1 << 10) - 1)
    def trits(x, n):
        out = []
        for i in range(n):
            c = (x >> (2 * (n - 1 - i))) & 3
            out.append({1: 1, 0: 0, 2: -1}.get(c, 0))
        return out
    Mt = trits(m, 15)
    Et = trits(e, 5)
    M = 0
    for t in Mt: M = M * 3 + t
    E = 0
    for t in Et: E = E * 3 + t
    return M, E - 60, Mt, Et

vals = [0.001, -1.0, -0.5, 0.1, 1.0]
rtl_bits = {
    0.001: 0x6681426982,
    -1.0: 0x0268962998,
    -0.5: 0x058148459a,
    0.1: 0x4848484984,
    1.0: 0x1000000198,
}
for v in vals:
    r = C.f2t_c_bits(v)  # (M, e3n) или спец
    M, e, Mt, Et = unpack_rtl(rtl_bits[v])
    print(f"{v}: RTL M={M} e={e} | python C (M,e3n)={r} | M совпал={M == (r[0] if r[0] not in ('zero','err') else None)}")
