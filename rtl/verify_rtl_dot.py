"""Сверка RTL-векторного ядра dot (N=4) с Python-эталоном.

Python-эталон: dot = последовательные mul + add (как будет в FPGA-ядрах
для NN). RTL: tf40_dot (дерево).

Запуск:  python verify_rtl_dot.py
"""
from __future__ import annotations
import sys, os, subprocess, struct, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw"))

from ternary.tfloat40 import TFloat
from ternary import arith

RTL = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(RTL, "sim")
XIL_BIN = "C:/AMDDesignTools/Vivado/2021.2/bin"
N = 4


def f32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


def dot_ref(vals_a, vals_b):
    """Python-эталон: попарное дерево sum(a_i*b_i) - как FPGA.

    p[i] = a_i*b_i; затем попарные суммы (бинарное дерево).
    """
    products = []
    for x, y in zip(vals_a, vals_b):
        products.append(arith.mul(TFloat.from_float(x), TFloat.from_float(y)))
    while len(products) > 1:
        nxt = []
        for i in range(0, len(products) - 1, 2):
            nxt.append(arith.add(products[i], products[i+1]))
        if len(products) % 2 == 1:
            nxt.append(products[-1])
        products = nxt
    return products[0]


def gen_input(ncase=30):
    vals = [1.0, -1.0, 0.5, 2.0, 0.1, 3.0, -0.5, 1.5, 0.25, 4.0,
            7.5, 0.001, 100.0, -3.0, 0.333, 2.5, -0.1, 42.0, 0.75, -2.0]
    random.seed(11)
    for _ in range(ncase * 8):
        vals.append(f32(random.uniform(-50, 50)))
    os.makedirs(SIM, exist_ok=True)
    cases = []
    with open(os.path.join(SIM, "dot_in.hex"), "w") as f:
        for c in range(ncase):
            a = vals[c*8:(c+1)*8]
            b = vals[(c+1)*8:(c+2)*8]
            ta = [TFloat.from_float(x) for x in a[:N]]
            tb = [TFloat.from_float(x) for x in b[:N]]
            f.write(" ".join(f"{t.to_bits():010x}" for t in ta + tb) + "\n")
            cases.append((a[:N], b[:N]))
    with open(os.path.join(SIM, "dot_expected.hex"), "w") as f:
        for a, b in cases:
            r = dot_ref(a, b)
            f.write(f"{r.to_bits():010x}\n")
    print(f"Сгенерировано {len(cases)} случаев")
    return cases


def run_sim():
    files = [
        os.path.join(RTL, "rtl", "tfloat_pkg.sv"),
        os.path.join(RTL, "rtl", "int_to_trits.sv"),
        os.path.join(RTL, "rtl", "tf40_mul.sv"),
        os.path.join(RTL, "rtl", "tf40_add.sv"),
        os.path.join(RTL, "rtl", "tf40_dot.sv"),
        os.path.join(RTL, "tb", "tb_tf40_dot.sv"),
    ]
    xvlog = os.path.join(XIL_BIN, "xvlog.bat")
    xelab = os.path.join(XIL_BIN, "xelab.bat")
    xsim  = os.path.join(XIL_BIN, "xsim.bat")

    def run(cmd, cwd=None):
        r = subprocess.run(cmd, shell=True, cwd=cwd or RTL,
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("CMD FAIL:", cmd)
            print(r.stdout[-1200:])
            print(r.stderr[-1200:])
        return r

    for d in ["xsim.dir", "xsim.cmd", "xsim.log"]:
        p = os.path.join(RTL, d)
        if os.path.isdir(p):
            import shutil; shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)
    run(f'"{xvlog}" -sv {" ".join(files)}')
    run(f'"{xelab}" tb_tf40_dot -debug typical')
    run(f'"{xsim}" tb_tf40_dot -runall')


def verify():
    exp = [int(l.strip(), 16) for l in open(os.path.join(SIM, "dot_expected.hex")) if l.strip()]
    got = []
    for l in open(os.path.join(SIM, "dot_out.hex")):
        p = l.split()
        if len(p) == 9:
            got.append(int(p[8], 16))
    if len(exp) != len(got):
        print(f"ОШИБКА: exp {len(exp)}, got {len(got)}")
        return False
    bad = 0
    for i, (e, g) in enumerate(zip(exp, got)):
        if e != g:
            bad += 1
            if bad <= 15:
                print(f"  [{i}] exp={e:010x} got={g:010x}")
    if bad == 0:
        print(f"DOT(N={N}): все {len(exp)} совпали (PASS)")
        return True
    print(f"DOT: несовпадений {bad}/{len(exp)}")
    return False


def main():
    gen_input()
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
