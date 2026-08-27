# -*- coding: utf-8 -*-
"""Побитовое сравнение exp/got для отладки RTL f2t_pipe2."""
import sys
sys.path.insert(0, r'C:\A7_M2\EXAMPLES\XDMA_DDR3\rtl')

def unpack(bits):
    m = (bits >> 10) & ((1 << 30) - 1)
    e = bits & ((1 << 10) - 1)
    def trits(x, n):
        out = []
        for i in range(n):
            c = (x >> (2 * (n - 1 - i))) & 3
            out.append({1: 1, 0: 0, 2: -1, 3: 'E'}.get(c, c))
        return out
    Mt = trits(m, 15)
    Et = trits(e, 5)
    M = 0
    for t in Mt:
        if t == 'E': return None, None, Mt, Et
        M = M * 3 + t
    E = 0
    for t in Et:
        if t == 'E': return None, None, Mt, Et
        E = E * 3 + t
    return M, E - 60, Mt, Et

cases = [
    (13, 0x6681421582, 0x6681426982),
    (33, 0x8511094459, 0x8511094059),
    (47, 0x2a10040160, 0x0024000111),
    (61, 0x6014592940, 0x0000000000),
]
for idx, exp, got in cases:
    me, ee, mte, ete = unpack(exp)
    mg, eg, mtg, etg = unpack(got)
    print(f"[{idx}]")
    print(f"  exp: M={me} e={ee} Mt={mte} Et={ete}")
    print(f"  got: M={mg} e={eg} Mt={mtg} Et={etg}")
    if me is not None and mg is not None:
        print(f"  M diff: {me - mg}, e diff: {ee - eg}")
