"""Сверка RTL-ядра TFloat40 ALU с Python-эталоном.

Генерирует пары TFloat, прогоняет add/sub/mul/div в RTL (xsim),
сверяет с Python arith.

Запуск:  python verify_rtl_alu.py
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


def gen_input(n=40):
    fixed = [1.0, -1.0, 3.0, -3.0, 0.5, -0.5, 1.5, 2.0, 2.5, 0.1, -0.1,
             100.0, -100.0, 0.001, 1234.5678, 0.25, 4.0, 7.5, 0.0001,
             123456.0, 3.14159, 2.71828, 0.3333333, -0.3333333, 42.0, -42.0]
    random.seed(7)
    for _ in range(n):
        fixed.append(float(struct.unpack("f", struct.pack("f", random.uniform(-500, 500)))[0]))
    pairs = []
    for i in range(0, len(fixed) - 1, 2):
        pairs.append((fixed[i], fixed[i+1]))
    # добавим пары с нулём и единицей
    pairs.append((1.0, 0.0))
    pairs.append((0.0, 5.0))
    pairs.append((-1.5, 1.5))
    pairs.append((0.1, 0.2))
    os.makedirs(SIM, exist_ok=True)
    with open(os.path.join(SIM, "alu_in.hex"), "w") as f:
        for x, y in pairs:
            ta = TFloat.from_float(x)
            tb = TFloat.from_float(y)
            f.write(f"{ta.to_bits():010x} {tb.to_bits():010x}\n")
    # ожидаемые результаты
    with open(os.path.join(SIM, "alu_expected.hex"), "w") as f:
        for x, y in pairs:
            ta = TFloat.from_float(x)
            tb = TFloat.from_float(y)
            for fn in [arith.add, arith.sub, arith.mul, arith.div]:
                try:
                    tr = fn(ta, tb)
                    f.write(f"{tr.to_bits():010x} ")
                except Exception:
                    f.write("ffffffffff ")   # 40-бит ERR (10 hex)
            f.write("\n")
    print(f"Сгенерировано {len(pairs)} пар")
    return pairs


def run_sim():
    files = [
        os.path.join(RTL, "rtl", "tfloat_pkg.sv"),
        os.path.join(RTL, "rtl", "int_to_trits.sv"),
        os.path.join(RTL, "rtl", "tf40_alu.sv"),
        os.path.join(RTL, "tb", "tb_tf40_alu.sv"),
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
    run(f'"{xelab}" tb_tf40_alu -debug typical')
    run(f'"{xsim}" tb_tf40_alu -runall')


def parse_bits(s):
    """40-бит int или -1 для ERR (все 1)."""
    v = int(s, 16)
    if v == 0xFFFFFFFFFF:
        return None  # ERR
    return v


def verify():
    exp_path = os.path.join(SIM, "alu_expected.hex")
    out_path = os.path.join(SIM, "alu_out.hex")
    if not os.path.exists(out_path):
        print("НЕТ alu_out.hex")
        return False
    exp = []
    for l in open(exp_path):
        if l.strip():
            exp.append([parse_bits(x) for x in l.split()])
    got = []
    for l in open(out_path):
        p = l.split()
        if len(p) == 6:
            got.append([parse_bits(x) for x in p[2:]])
    if len(exp) != len(got):
        print(f"ОШИБКА: exp {len(exp)}, got {len(got)}")
        return False
    ops = ["add", "sub", "mul", "div"]
    bad = 0
    for i, (e, g) in enumerate(zip(exp, got)):
        for j, (ee, gg) in enumerate(zip(e, g)):
            if ee is None or gg is None:
                # оба должны быть ERR
                if not (ee is None and gg is None):
                    bad += 1
                    if bad <= 15:
                        print(f"  [{i}] {ops[j]}: exp ERR={ee is None} got ERR={gg is None}")
                continue
            if ee != gg:
                bad += 1
                if bad <= 15:
                    print(f"  [{i}] {ops[j]}: exp={ee:010x} got={gg:010x}")
    if bad == 0:
        print(f"ALU: все {len(exp)} пар x 4 операции совпали (PASS)")
        return True
    else:
        print(f"ALU: несовпадений {bad}")
        return False


def main():
    gen_input()
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
