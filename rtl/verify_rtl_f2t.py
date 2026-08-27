"""Сверка RTL-конвертера F2T с Python-эталоном.

1. Генерирует sim/f2t_in.hex (float32 биты) из эталонных значений.
2. Запускает xvlog/xelab/xsim (Vivado) на tb_f32_to_tf40.
3. Читает sim/f2t_out.hex (RTL вывод) и сверяет с Python TFloat40.

Запуск:  python verify_rtl_f2t.py
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
    with open(os.path.join(SIM, "f2t_in.hex"), "w") as f:
        for v in vals:
            f.write(f"{f32_bits(v):08x}\n")
    with open(os.path.join(SIM, "f2t_expected.hex"), "w") as f:
        for v in vals:
            v32 = struct.unpack("f", struct.pack("f", v))[0]  # привести к float32
            t = TFloat.from_float(v32)
            f.write(f"{t.to_bits():010x}\n")
    print(f"Сгенерировано {len(vals)} векторов")
    return vals


def run_sim():
    files = [
        os.path.join(RTL, "rtl", "tfloat_pkg.sv"),
        os.path.join(RTL, "rtl", "int_to_trits.sv"),
        os.path.join(RTL, "rtl", "f32_to_tf40.sv"),
        os.path.join(RTL, "tb", "tb_f32_to_tf40.sv"),
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

    # удалим старые артефакты
    for d in ["xsim.dir", "xsim.cmd", "xsim.log"]:
        p = os.path.join(RTL, d)
        if os.path.isdir(p):
            import shutil; shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)

    run(f'"{xvlog}" -sv {" ".join(files)}')
    run(f'"{xelab}" tb_f32_to_tf40 -debug typical')
    run(f'"{xsim}" tb_f32_to_tf40 -runall')


def verify():
    exp_path = os.path.join(SIM, "f2t_expected.hex")
    out_path = os.path.join(SIM, "f2t_out.hex")
    if not os.path.exists(out_path):
        print("НЕТ выходного файла f2t_out.hex - симуляция не выполнена")
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
        if e != g:
            bad += 1
            if bad <= 15:
                print(f"  [{i}] exp={e:010x} got={g:010x}")
    if bad == 0:
        print(f"F2T: все {len(exp)} векторы совпали (PASS)")
        return True
    else:
        print(f"F2T: несовпадений {bad}/{len(exp)}")
        return False


def main():
    gen_input()
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
