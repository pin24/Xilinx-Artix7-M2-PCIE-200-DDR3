import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ternary_sw"))
import random
import verify_tdot_axi4 as V
from block.tfloat48 import TFloat
from block import arith48

def get_me(v):
    t = TFloat.from_bits(((v & ((1 << 40) - 1)) << 8) | ((v >> 40) & 0xFF))
    m = arith48._trits_value(arith48._m_trits(t))
    e = arith48._e_raw(t)
    return int(m), e

random.seed(71)
got = [int(l.strip(), 16) for l in open(os.path.join("sim", "tb_tdot_axi4_out.hex")) if l.strip()]
tout = []
for n in range(4):
    a = [V.f32(random.uniform(-10, 10)) for _ in range(32)]
    b = [V.f32(random.uniform(-10, 10)) for _ in range(32)]
    exp = V.dot_ref_raw([V.to_bits48(TFloat.from_float(x)) for x in a],
                        [V.to_bits48(TFloat.from_float(y)) for y in b])
    g = got[n]
    gm, ge = get_me(g)
    re = arith48._norm_raw(gm, ge)
    re_bits = V.to_bits48(re)
    print("case", n, "exp=", hex(exp), " got=", hex(g), " norm(got)=", hex(re_bits), " match=%s" % (exp == re_bits))
    print("   got(m=%d,e=%d) norm-> m=%d e=%d" % (gm, ge, arith48._trits_value(arith48._m_trits(re)), arith48._e_raw(re)))