# -*- coding: utf-8 -*-
"""Сверка RTL f2t_pipe2 вывода с Python-моделью C для каждого тестового значения."""
import sys, struct, random, os
sys.path.insert(0, r'C:\A7_M2\EXAMPLES\XDMA_DDR3\rtl')
sys.path.insert(0, r'C:\A7_M2\EXAMPLES\XDMA_DDR3\ternary_sw')
import proto_f2t_c as C
import proto_f2t_pipe as P
from ternary.tfloat40 import TFloat

def f32_bits(x): return struct.unpack("I", struct.pack("f", x))[0]
def f32(x): return struct.unpack("f", struct.pack("f", x))[0]

vals = [0.0, 1.0, -1.0, 3.0, -3.0, 0.5, -0.5, 1.5, 2.0, 0.1, -0.1,
        100.0, -100.0, 0.001, 1234.5678, 0.25, 4.0, 7.5, 0.0001,
        123456.0, 3.14159, 2.71828, 0.3333333, -0.3333333, 42.0, -42.0,
        0.9999, 2.9999, 12345.678, -0.00001, 1e-10, 1e10,
        123456789.0, -1e-12, 5.5, 0.5, 2.0, 8.0, 27.0, -27.0]
random.seed(99)
for _ in range(60):
    e = random.uniform(-80, 80)
    v = f32(random.uniform(-1, 1) * (2.0 ** e))
    if v == 0 or v != v or v in (float("inf"), float("-inf")):
        continue
    vals.append(v)

got = [int(l.strip(), 16) for l in open(r'C:\A7_M2\EXAMPLES\XDMA_DDR3\rtl\sim\f2t2_out.hex') if l.strip()]

def pack(M, e3n):
    if M == 0: return 0
    def to_trits(m, n):
        out=[0]*n; v=m
        for i in range(n-1,-1,-1):
            r=v%3; v//=3
            if r==2: r=-1; v+=1
            out[i]=r
        return out
    mt=to_trits(M,15); et=to_trits(e3n+60,5)
    mbits=0
    for t in mt: mbits=(mbits<<2)|{1:1,-1:2,0:0}[t]
    ebits=0
    for t in et: ebits=(ebits<<2)|{1:1,-1:2,0:0}[t]
    return (mbits<<10)|ebits

nbad = 0
for i, (v, g) in enumerate(zip(vals, got)):
    v32 = f32(v)
    t = TFloat.from_float(v32)
    ebits = t.to_bits()
    if ebits != g:
        c = C.f2t_c_bits(v32)
        cbits = pack(c[0], c[1]) if c[0] not in ('zero','err') else 0
        ok_algo = (cbits == g)
        print(f"[{i}] v={v} exp={ebits:010x} got={g:010x} C={c} C_matches_got={ok_algo}")
        nbad += 1
print("всего mismatch:", nbad)
