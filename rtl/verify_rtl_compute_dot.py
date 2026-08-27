"""Сверка конвейерного compute_core_dot (N=64) с Python-эталоном."""
from __future__ import annotations
import sys, os, subprocess, struct, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw"))

from ternary.tfloat40 import TFloat
from ternary import arith

RTL = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(RTL, "sim")
XIL_BIN = "C:/AMDDesignTools/Vivado/2021.2/bin"
N = 64


def f32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


def f32_bits(x):
    return struct.unpack("I", struct.pack("f", x))[0]


def dot_ref(vals_a, vals_b):
    products = [arith.mul(TFloat.from_float(x), TFloat.from_float(y))
                for x, y in zip(vals_a, vals_b)]
    while len(products) > 1:
        nxt = []
        for i in range(0, len(products) - 1, 2):
            nxt.append(arith.add(products[i], products[i+1]))
        if len(products) % 2 == 1:
            nxt.append(products[-1])
        products = nxt
    return products[0]


def gen_input(ncase=10):
    random.seed(41)
    os.makedirs(SIM, exist_ok=True)
    with open(os.path.join(SIM, "ccd_in.hex"), "w") as f:
        with open(os.path.join(SIM, "ccd_expected.hex"), "w") as fe:
            for _ in range(ncase):
                a = [f32(random.uniform(-10, 10)) for _ in range(N)]
                b = [f32(random.uniform(-10, 10)) for _ in range(N)]
                f.write(" ".join(f"{f32_bits(x):08x}" for x in a + b) + "\n")
                r = dot_ref(a, b)
                fe.write(f"{f32_bits(f32(r.to_float())):08x}\n")
    print(f"Сгенерировано {ncase} случаев (N={N})")


def run_sim():
    files = [
        os.path.join(RTL, "rtl", "tfloat_pkg.sv"),
        os.path.join(RTL, "rtl", "int_to_trits.sv"),
        os.path.join(RTL, "rtl", "f32_to_tf40.sv"),
        os.path.join(RTL, "rtl", "tf40_to_f32.sv"),
        os.path.join(RTL, "rtl", "tf40_mul.sv"),
        os.path.join(RTL, "rtl", "tf40_add.sv"),
        os.path.join(RTL, "rtl", "tf40_mul_pipe.sv"),
        os.path.join(RTL, "rtl", "compute_core_dot.sv"),
        os.path.join(RTL, "tb", "tb_compute_dot.sv"),
    ]
    xvlog = os.path.join(XIL_BIN, "xvlog.bat")
    xelab = os.path.join(XIL_BIN, "xelab.bat")
    xsim  = os.path.join(XIL_BIN, "xsim.bat")

    def run(cmd, cwd=None):
        r = subprocess.run(cmd, shell=True, cwd=cwd or RTL,
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("CMD FAIL:", cmd)
            print(r.stdout[-1500:])
            print(r.stderr[-1500:])
        return r

    for d in ["xsim.dir", "xsim.cmd", "xsim.log"]:
        p = os.path.join(RTL, d)
        if os.path.isdir(p):
            import shutil; shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)
    run(f'"{xvlog}" -sv {" ".join(files)}')
    run(f'"{xelab}" tb_compute_dot -debug typical')
    run(f'"{xsim}" tb_compute_dot -runall')


def verify(tol=2):
    exp = [int(l.strip(), 16) for l in open(os.path.join(SIM, "ccd_expected.hex")) if l.strip()]
    got = [int(l.strip(), 16) for l in open(os.path.join(SIM, "ccd_out.hex")) if l.strip()]
    if len(exp) != len(got):
        print(f"ОШИБКА: exp {len(exp)}, got {len(got)}")
        return False
    bad = 0
    for i, (e, g) in enumerate(zip(exp, got)):
        if abs(e - g) > tol:
            bad += 1
            if bad <= 10:
                print(f"  [{i}] exp={e:08x} got={g:08x}")
    if bad == 0:
        print(f"COMPUTE_DOT(N={N}): все {len(exp)} совпали (PASS, tol={tol})")
        return True
    print(f"COMPUTE_DOT: несовпадений {bad}/{len(exp)}")
    return False


def main():
    gen_input()
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
