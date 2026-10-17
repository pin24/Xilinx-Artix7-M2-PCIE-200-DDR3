"""Сверка RTL-конвертера F2T (float32 -> TFloat48) с Python-эталоном.

Эталон = TFloat.from_float(v) в конвенции ЯДРА _to_bits48 = ((e&0xFF)<<40)|(m&mask).
Спецслучаи (как host fpga_backend._to_bits48):
  inf/nan -> 0;  ±0 -> 0;  субнормал -> 0;
  overflow (from_float бросает TFloatError) -> RTL кодирует ERR (0xFFFFFFFFFFFF).

Запуск:  python verify_rtl_f2t48.py [N]
"""
from __future__ import annotations
import sys, os, subprocess, struct, random, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw"))

from block.tfloat48 import TFloat, TFloatError, MASK_E, E_TRITS

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
    """Бит-в-бит эталон: _to_bits48(TFloat.from_float(f32(fv))); overflow -> ERR.

    ВАЖНО: эталон считаем от float32-значения f32(fv) (как попадает в RTL),
    а не от double v - иначе для больших/малых чисел расходятся.
    """
    v32 = f32(fv)
    try:
        t = TFloat.from_float(v32)
    except TFloatError:
        return ERR48          # host не может (бросает): RTL резервирует ERR
    if t.err:
        return 0              # inf/nan
    return ((t.e_int & 0xFF) << 40) | (t.m_int & M_MASK)


def gen_random_vals(n):
    random.seed(20261017)
    vals = []
    # половина векторов - лог-равномерные в ДИАПАЗОНЕ tf48 [3^-40, 3^41]
    # (густая выборка мантиссы/округления), половина - широкий диапазон
    # (вкл. уфлоу/офлоу/спецслучаи).
    for k in range(n):
        if k % 2 == 0:
            e = random.uniform(-40.0, 41.0)          # тройная экспонента (в диапазоне)
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
        1.17549435e-38, -1.17549435e-38,        # min normal
        1.40129846e-45, 1.1754942e-38 * 0.5,    # subnormals (->0)
        3.4028235e38, -3.4028235e38,            # max normal (overflow)
        1.0, -1.0, 0.5, 2.0, 3.0, 9.0, 27.0, 81.0, 243.0,
        1e-20, 1e-19, 1e19, 3.0e19, 3.6e19, 4e19, 1e30,
        3.0**-38, 3.0**-39, 3.0**-40, 3.0**-41, 3.0**-42,
        3.0**39, 3.0**40, 3.0**41, 3.0**42,
        1.5, 0.75, 7.5, 0.3333333333, 1234.5678, -9876.5432,
    ]
    vals = special + gen_random_vals(n)
    os.makedirs(SIM, exist_ok=True)
    with open(os.path.join(SIM, "f2t48_in.hex"), "w") as f:
        for v in vals:
            f.write(f"{f32_bits(v):08x}\n")
    with open(os.path.join(SIM, "f2t48_expected.hex"), "w") as f:
        for v in vals:
            f.write(f"{ref_from_float(v):012x}\n")
    print(f"Сгенерировано {len(vals)} векторов (random={n}, special={len(special)})")
    return vals


def run_sim():
    files = [
        os.path.join(RTL, "rtl", "tf48_pkg.sv"),
        os.path.join(RTL, "rtl", "int_to_trits.sv"),
        os.path.join(RTL, "rtl", "f32_to_tf48.sv"),
        os.path.join(RTL, "tb", "tb_f32_to_tf48.sv"),
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

    for d in ["xsim.dir", "xsim.cmd", "xsim.log", "xelab.log", "xvlog.log"]:
        p = os.path.join(RTL, d)
        if os.path.isdir(p):
            import shutil; shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)

    run(f'"{xvlog}" -sv {" ".join(files)}')
    run(f'"{xelab}" tb_f32_to_tf48 -debug typical')
    run(f'"{xsim}" tb_f32_to_tf48 -runall')


def verify():
    exp_path = os.path.join(SIM, "f2t48_expected.hex")
    out_path = os.path.join(SIM, "f2t48_out.hex")
    if not os.path.exists(out_path):
        print("НЕТ выходного файла f2t48_out.hex - симуляция не выполнена")
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
    n_err = n_zero = 0
    for i, (e, g) in enumerate(zip(exp, got)):
        if e == ERR48: n_err += 1
        if e == 0: n_zero += 1
        if e != g:
            bad += 1
            if bad <= 20:
                print(f"  [{i}] exp={e:012x} got={g:012x}")
    if bad == 0:
        print(f"F2T48 PASS: {len(exp)} векторы бит-в-бит (ERR={n_err}, zero={n_zero})")
        return True
    else:
        print(f"F2T48 FAIL: несовпадений {bad}/{len(exp)}")
        return False


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    gen_input(n)
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()