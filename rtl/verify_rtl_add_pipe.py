"""Сверка конвейерного tf40_add_pipe с Python-эталоном."""
from __future__ import annotations
import sys, os, subprocess, struct, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw"))

from ternary.tfloat40 import TFloat
from ternary import arith

RTL = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(RTL, "sim")
XIL_BIN = "C:/AMDDesignTools/Vivado/2021.2/bin"


def f32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


def gen_input(n=60):
    vals = [1.0, -1.0, 3.0, -3.0, 0.5, 1.5, 2.0, 0.1, 100.0, 0.001,
            1234.5678, 0.25, 7.5, -0.5, 3.14159, 2.71828,
            1e-6, 1e6, 1e-10, 1e10, 0.0, 123.456, -0.0001]
    random.seed(71)
    pairs = []
    for _ in range(n):
        pairs.append((f32(random.uniform(-100, 100)), f32(random.uniform(-100, 100))))
    for x in vals:
        pairs.append((x, x))
        pairs.append((x, -x))
        pairs.append((x, 0.0))
    random.seed(72)
    for _ in range(30):
        # большая разница экспонент (выравнивание на границе)
        pairs.append((f32(random.uniform(-1, 1)), f32(random.uniform(-1e6, 1e6))))
    os.makedirs(SIM, exist_ok=True)
    with open(os.path.join(SIM, "addp_in.hex"), "w") as f:
        for x, y in pairs:
            ta, tb = TFloat.from_float(x), TFloat.from_float(y)
            f.write(f"{ta.to_bits():010x} {tb.to_bits():010x}\n")
    with open(os.path.join(SIM, "addp_expected.hex"), "w") as f:
        for x, y in pairs:
            ta, tb = TFloat.from_float(x), TFloat.from_float(y)
            r = arith.add(ta, tb)
            f.write(f"{r.to_bits():010x}\n")
    print(f"Сгенерировано {len(pairs)} пар")
    return pairs


def run_sim():
    files = [
        os.path.join(RTL, "rtl", "tfloat_pkg.sv"),
        os.path.join(RTL, "rtl", "int_to_trits.sv"),
        os.path.join(RTL, "rtl", "tf40_add_pipe.sv"),
        os.path.join(RTL, "tb", "tb_tf40_add_pipe.sv"),
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
    run(f'"{xelab}" tb_tf40_add_pipe -debug typical')
    run(f'"{xsim}" tb_tf40_add_pipe -runall')


def verify():
    exp = [int(l.strip(), 16) for l in open(os.path.join(SIM, "addp_expected.hex")) if l.strip()]
    got = [int(l.strip(), 16) for l in open(os.path.join(SIM, "addp_out.hex")) if l.strip()]
    n = min(len(exp), len(got))
    bad = 0
    for i in range(n):
        if exp[i] != got[i]:
            bad += 1
            if bad <= 15:
                print(f"  [{i}] exp={exp[i]:010x} got={got[i]:010x}")
    print(f"ADD_PIPE: сравнено {n} (expected={len(exp)}, got={len(got)}), несовпадений {bad}")
    return bad == 0 and len(exp) == len(got)


def main():
    gen_input()
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
