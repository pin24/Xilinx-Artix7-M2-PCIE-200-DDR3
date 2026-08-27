"""Сверка RTL-конвертера T2F с Python-эталоном.

1. Генерирует sim/t2f_in.hex (TFloat40 биты из эталонных значений).
2. Запускает xvlog/xelab/xsim на tb_tf40_to_f32.
3. Сверяет RTL float32 с Python TFloat.to_float().

Запуск:  python verify_rtl_t2f.py
"""
from __future__ import annotations
import sys, os, subprocess, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw"))

from ternary.tfloat40 import TFloat

RTL = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(RTL, "sim")
XIL_BIN = "C:/AMDDesignTools/Vivado/2021.2/bin"


def f32_bits(x):
    return struct.unpack("I", struct.pack("f", x))[0]


def gen_input():
    vals = [0.0, 1.0, -1.0, 3.0, -3.0, 0.5, -0.5, 0.3333333333, 1.5, 2.0,
            2.5, 0.1, -0.1, 100.0, -100.0, 0.001, 1e-5, 1234.5678, -9876.5432,
            42.0, -42.0, 0.9999, 1.0001, 2.9999, 0.25, 4.0, 0.75, 7.5,
            0.0001, 123456.0, -0.00001, 3.14159, 2.71828]
    os.makedirs(SIM, exist_ok=True)
    with open(os.path.join(SIM, "t2f_in.hex"), "w") as f:
        for v in vals:
            v32 = struct.unpack("f", struct.pack("f", v))[0]
            t = TFloat.from_float(v32)
            f.write(f"{t.to_bits():010x}\n")
    with open(os.path.join(SIM, "t2f_expected.hex"), "w") as f:
        for v in vals:
            v32 = struct.unpack("f", struct.pack("f", v))[0]
            t = TFloat.from_float(v32)
            # ожидаемый float32 = округление t.to_float() к float32
            exp = struct.unpack("f", struct.pack("f", t.to_float()))[0]
            f.write(f"{f32_bits(exp):08x}\n")
    print(f"Сгенерировано {len(vals)} векторов")


def run_sim():
    files = [
        os.path.join(RTL, "rtl", "tfloat_pkg.sv"),
        os.path.join(RTL, "rtl", "tf40_to_f32.sv"),
        os.path.join(RTL, "tb", "tb_tf40_to_f32.sv"),
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
    run(f'"{xelab}" tb_tf40_to_f32 -debug typical')
    run(f'"{xsim}" tb_tf40_to_f32 -runall')


def verify(tol_bits=2):
    exp_path = os.path.join(SIM, "t2f_expected.hex")
    out_path = os.path.join(SIM, "t2f_out.hex")
    if not os.path.exists(out_path):
        print("НЕТ выходного файла t2f_out.hex")
        return False
    exp = [int(l.strip(), 16) for l in open(exp_path) if l.strip()]
    got = []
    with open(out_path) as f:
        for line in f:
            p = line.split()
            if len(p) == 2:
                got.append(int(p[1], 16))
    if len(exp) != len(got):
        print(f"ОШИБКА: expected {len(exp)}, got {len(got)}")
        return False
    bad = 0
    for i, (e, g) in enumerate(zip(exp, got)):
        # допускаем расхождение в tol_bits ULP (округление)
        if abs(e - g) > tol_bits:
            bad += 1
            if bad <= 15:
                print(f"  [{i}] exp={e:08x} got={g:08x} (diff {abs(e-g)})")
    if bad == 0:
        print(f"T2F: все {len(exp)} векторы совпали (PASS, tol={tol_bits})")
        return True
    else:
        print(f"T2F: несовпадений {bad}/{len(exp)}")
        return False


def main():
    gen_input()
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
