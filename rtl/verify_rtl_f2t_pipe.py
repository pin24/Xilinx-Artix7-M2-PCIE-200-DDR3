"""Сверка конвейерного F2T с Python-эталоном."""
from __future__ import annotations
import sys, os, subprocess, struct, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw"))

from ternary.tfloat40 import TFloat

RTL = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(RTL, "sim")
XIL_BIN = "C:/AMDDesignTools/Vivado/2021.2/bin"


def f32_bits(x):
    return struct.unpack("I", struct.pack("f", x))[0]


def gen_input():
    vals = [0.0, 1.0, -1.0, 3.0, -3.0, 0.5, -0.5, 1.5, 2.0, 0.1, -0.1,
            100.0, -100.0, 0.001, 1234.5678, 0.25, 4.0, 7.5, 0.0001,
            123456.0, 3.14159, 2.71828, 0.3333333, -0.3333333, 42.0, -42.0,
            0.9999, 2.9999, 12345.678, -0.00001, 1e-10, 1e10]
    random.seed(99)
    for _ in range(50):
        vals.append(float(struct.unpack("f", struct.pack("f", random.uniform(-1e4, 1e4)))[0]))
    os.makedirs(SIM, exist_ok=True)
    with open(os.path.join(SIM, "f2tp_in.hex"), "w") as f:
        for v in vals:
            f.write(f"{f32_bits(v):08x}\n")
    with open(os.path.join(SIM, "f2tp_expected.hex"), "w") as f:
        for v in vals:
            t = TFloat.from_float(v)
            f.write(f"{t.to_bits():010x}\n")
    print(f"Сгенерировано {len(vals)} векторов")


def run_sim():
    files = [
        os.path.join(RTL, "rtl", "tfloat_pkg.sv"),
        os.path.join(RTL, "rtl", "int_to_trits.sv"),
        os.path.join(RTL, "rtl", "f32_to_tf40_pipe.sv"),
        os.path.join(RTL, "tb", "tb_f2t_pipe.sv"),
    ]
    xvlog = os.path.join(XIL_BIN, "xvlog.bat")
    xelab = os.path.join(XIL_BIN, "xelab.bat")
    xsim  = os.path.join(XIL_BIN, "xsim.bat")

    def run(cmd, cwd=None):
        r = subprocess.run(cmd, shell=True, cwd=cwd or RTL, capture_output=True, text=True)
        if r.returncode != 0:
            print("CMD FAIL:", cmd); print(r.stdout[-1200:]); print(r.stderr[-1200:])
        return r

    for d in ["xsim.dir", "xsim.cmd", "xsim.log"]:
        p = os.path.join(RTL, d)
        if os.path.isdir(p):
            import shutil; shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)
    run(f'"{xvlog}" -sv {" ".join(files)}')
    run(f'"{xelab}" tb_f2t_pipe -debug typical')
    run(f'"{xsim}" tb_f2t_pipe -runall')


def verify():
    exp = [int(l.strip(),16) for l in open(os.path.join(SIM,"f2tp_expected.hex")) if l.strip()]
    got = [int(l.strip(),16) for l in open(os.path.join(SIM,"f2tp_out.hex")) if l.strip()]
    if len(exp) != len(got):
        print(f"ОШИБКА: exp {len(exp)}, got {len(got)}")
        return False
    bad = 0
    for i,(e,g) in enumerate(zip(exp,got)):
        if e != g:
            bad += 1
            if bad <= 12:
                print(f"  [{i}] exp={e:010x} got={g:010x}")
    if bad == 0:
        print(f"F2T_PIPE: все {len(exp)} совпали (PASS)")
        return True
    print(f"F2T_PIPE: несовпадений {bad}/{len(exp)}")
    return False


def main():
    gen_input()
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
