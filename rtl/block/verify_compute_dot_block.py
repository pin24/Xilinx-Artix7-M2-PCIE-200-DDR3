"""Сверка compute_core_dot_block (N=16, TFloat48) с Python-эталоном arith48."""
from __future__ import annotations
import sys, os, subprocess, struct, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ternary_sw"))

from block.tfloat48 import TFloat
from block import arith48

RTL = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(RTL, "sim")
XIL_BIN = "C:/AMDDesignTools/Vivado/2021.2/bin"
N = 16
os.makedirs(SIM, exist_ok=True)


def f32(x): return struct.unpack("f", struct.pack("f", x))[0]


def to_bits48(t):
    return ((t.e_int & 0xFF) << 40) | (t.m_int & ((1 << 40) - 1))


def from_bits48(bits):
    return TFloat(bits & ((1 << 40) - 1), (bits >> 40) & 0xFF)


def dot_ref(vals_a, vals_b):
    products = [arith48.mul(TFloat.from_float(x), TFloat.from_float(y))
                for x, y in zip(vals_a, vals_b)]
    while len(products) > 1:
        nxt = []
        for i in range(0, len(products) - 1, 2):
            nxt.append(arith48.add(products[i], products[i+1]))
        if len(products) % 2 == 1:
            nxt.append(products[-1])
        products = nxt
    return products[0]


def gen_input(ncase=10):
    random.seed(41)
    with open(os.path.join(SIM, "ccdb_in.hex"), "w") as f:
        with open(os.path.join(SIM, "ccdb_expected.hex"), "w") as fe:
            for _ in range(ncase):
                a = [f32(random.uniform(-10, 10)) for _ in range(N)]
                b = [f32(random.uniform(-10, 10)) for _ in range(N)]
                # входы как TFloat48 биты
                bits = [to_bits48(TFloat.from_float(x)) for x in a] + \
                       [to_bits48(TFloat.from_float(y)) for y in b]
                f.write(" ".join(f"{x:012x}" for x in bits) + "\n")
                r = dot_ref(a, b)
                fe.write(f"{to_bits48(r):012x}\n")
    print(f"Сгенерировано {ncase} случаев (N={N})")


def run_sim():
    files = [
        os.path.join(RTL, "tbyte_add.sv"),
        os.path.join(RTL, "tbyte_mul.sv"),
        os.path.join(RTL, "tfmac.sv"),
        os.path.join(RTL, "compute_core_dot_block.sv"),
        os.path.join(RTL, "tb_compute_dot_block.sv"),
    ]
    xvlog = os.path.join(XIL_BIN, "xvlog.bat")
    xelab = os.path.join(XIL_BIN, "xelab.bat")
    xsim = os.path.join(XIL_BIN, "xsim.bat")
    def run(cmd):
        r = subprocess.run(cmd, shell=True, cwd=RTL, capture_output=True, text=True)
        if r.returncode != 0:
            print("CMD FAIL:", cmd); print(r.stdout[-1400:]); print(r.stderr[-1400:])
        return r
    for d in ["xsim.dir", "xsim.cmd", "xsim.log"]:
        p = os.path.join(RTL, d)
        if os.path.isdir(p):
            import shutil; shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)
    run(f'"{xvlog}" -sv {" ".join(files)}')
    run(f'"{xelab}" tb_compute_dot_block -debug typical')
    run(f'"{xsim}" tb_compute_dot_block -runall')


def verify():
    exp = [int(l.strip(), 16) for l in open(os.path.join(SIM, "ccdb_expected.hex")) if l.strip()]
    got = [int(l.strip(), 16) for l in open(os.path.join(SIM, "ccdb_out.hex")) if l.strip()]
    if len(exp) != len(got):
        print(f"ОШИБКА: exp {len(exp)}, got {len(got)}")
        return False
    bad = 0
    for i, (e, g) in enumerate(zip(exp, got)):
        if e != g:
            bad += 1
            if bad <= 10:
                print(f"  [{i}] exp={e:012x} got={g:012x}")
    print(f"COMPUTE_DOT_BLOCK(N={N}): проверено {len(exp)}, несовпадений {bad}")
    return bad == 0


def main():
    gen_input()
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
