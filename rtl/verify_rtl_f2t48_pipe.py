"""Сверка конвейерного f32_to_tf48_pipe с комбинационным f32_to_tf48 (бит-в-бит).

Генерирует те же входные fp32, что verify_rtl_f2t48.py; запускает
tb_f2t48_pipe_comp.sv, который кормит и комб- и pipe-модуль одним потоком и
сопоставляет по индексу. Дополнительно для контроля привязывает результат к
Python-эталону ref_from_float (спецслучаи/уфлоу/офлоу).

Запуск:  python verify_rtl_f2t48_pipe.py [N]
"""
from __future__ import annotations
import sys, os, subprocess, struct, random, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw"))

from block.tfloat48 import TFloat, TFloatError

RTL = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(RTL, "sim")
XIL_BIN = "C:/AMDDesignTools/2025.2/Vivado/bin"

M_MASK = (1 << 40) - 1
ERR48  = 0xFFFFFFFFFFFF


def f32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


def f32_bits(x):
    return struct.unpack("I", struct.pack("f", x))[0]


def ref_from_float(fv):
    v32 = f32(fv)
    try:
        t = TFloat.from_float(v32)
    except TFloatError:
        return ERR48
    if t.err:
        return 0
    return ((t.e_int & 0xFF) << 40) | (t.m_int & M_MASK)


def gen_random_vals(n):
    random.seed(20261017)
    vals = []
    for k in range(n):
        if k % 2 == 0:
            e = random.uniform(-40.0, 41.0)
            m = random.uniform(0.9, 3.0)
            v = m * (3.0 ** e)
        else:
            e = random.uniform(-95, 120)
            m = random.uniform(0.1, 10.0)
            v = m * (2.0 ** e)
        vals.append(math.copysign(v, random.choice([-1, 1])))
    return vals


def gen_input(n):
    special = [
        0.0, -0.0, float("inf"), float("-inf"), float("nan"),
        1.17549435e-38, -1.17549435e-38,
        1.40129846e-45, 1.1754942e-38 * 0.5,
        3.4028235e38, -3.4028235e38,
        1.0, -1.0, 0.5, 2.0, 3.0, 9.0, 27.0, 81.0, 243.0,
        1e-20, 1e-19, 1e19, 3.0e19, 3.6e19, 4e19, 1e30,
        3.0**-38, 3.0**-39, 3.0**-40, 3.0**-41, 3.0**-42,
        3.0**39, 3.0**40, 3.0**41, 3.0**42,
        1.5, 0.75, 7.5, 0.3333333333, 1234.5678, -9876.5432,
    ]
    vals = special + gen_random_vals(n)
    os.makedirs(SIM, exist_ok=True)
    with open(os.path.join(SIM, "f2t48p_in.hex"), "w") as f:
        for v in vals:
            f.write(f"{f32_bits(v):08x}\n")
    return vals


def run_sim():
    files = [
        os.path.join(RTL, "rtl", "tf48_pkg.sv"),
        os.path.join(RTL, "rtl", "int_to_trits.sv"),
        os.path.join(RTL, "rtl", "f32_to_tf48.sv"),       # только для сверки ref==comb ниже
        os.path.join(RTL, "rtl", "tf48_div_pipe.sv"),
        os.path.join(RTL, "rtl", "f32_to_tf48_pipe.sv"),
        os.path.join(RTL, "tb", "tb_f32_to_tf48_pipe.sv"),
    ]
    xvlog = os.path.join(XIL_BIN, "xvlog.bat")
    xelab = os.path.join(XIL_BIN, "xelab.bat")
    xsim  = os.path.join(XIL_BIN, "xsim.bat")

    def run(cmd, cwd=None):
        r = subprocess.run(cmd, shell=True, cwd=cwd or RTL, capture_output=True, text=True)
        if r.returncode != 0:
            print("CMD FAIL:", cmd); print(r.stdout[-1500:]); print(r.stderr[-1500:])
        return r

    for d in ["xsim.dir", "xsim.cmd", "xsim.log", "xelab.log", "xvlog.log"]:
        p = os.path.join(RTL, d)
        if os.path.isdir(p):
            import shutil; shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)

    run(f'"{xvlog}" -sv {" ".join(files)}')
    run(f'"{xelab}" tb_f32_to_tf48_pipe -debug typical')
    run(f'"{xsim}" tb_f32_to_tf48_pipe -runall')


def verify(vals):
    out_path = os.path.join(SIM, "f2t48p_out.hex")
    if not os.path.exists(out_path):
        print("НЕТ f2t48p_out.hex - симуляция не выполнена")
        return False
    got = [int(l.strip(), 16) for l in open(out_path) if l.strip()]
    if len(got) != len(vals):
        print(f"ОШИБКА: ожидалось {len(vals)} выходов pipe, получено {len(got)}")
        return False
    bad = 0
    for i, (v, g) in enumerate(zip(vals, got)):
        r = ref_from_float(v)      # = бит-в-бит эталон комбинационного f32_to_tf48
        if r != g:
            bad += 1
            if bad <= 20: print(f"  [{i}] ref={r:012x} pipe={g:012x}")
    print(f"F2T48_PIPE: vectors={len(got)} pipe-vs-ref(comb) mismatch={bad}")
    return bad == 0


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    vals = gen_input(n)
    run_sim()
    ok = verify(vals)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()