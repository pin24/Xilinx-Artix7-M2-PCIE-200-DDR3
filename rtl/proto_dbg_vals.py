# -*- coding: utf-8 -*-
"""Сравнение Python-модели C для отдельных значений (для отладки RTL)."""
import struct, sys
sys.path.insert(0, r'C:\A7_M2\EXAMPLES\XDMA_DDR3\rtl')
import proto_f2t_c as C

def f32(x): return struct.unpack('f', struct.pack('f', x))[0]

for v in [0.001, -1.0, -0.5, 0.1, -0.1]:
    v32 = f32(v)
    print(v, '->', C.f2t_c_bits(v32))
