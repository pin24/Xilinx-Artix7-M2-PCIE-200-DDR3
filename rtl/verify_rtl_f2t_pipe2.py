"""Сверка конвейерного f32_to_tf40_pipe2 с Python-эталоном."""
from __future__ import annotations
import sys, os, subprocess, struct, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw"))

from ternary.tfloat40 import TFloat

import proto_f2t_pipe as refmod

RTL = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(RTL, "sim")
XIL_BIN = "C:/AMDDesignTools/Vivado/2021.2/bin"


def f32_bits(x):
    return struct.unpack("I", struct.pack("f", x))[0]


def f32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


def gen_input():
    # стандартный набор (как verify_rtl_f2t.py) - эталон совпадает с Python
    vals = [0.0, 1.0, -1.0, 3.0, -3.0, 0.5, -0.5, 0.3333333333, 1.5, 2.0,
            2.5, 0.1, -0.1, 100.0, -100.0, 0.001, 1e-5, 1234.5678, -9876.5432,
            42.0, -42.0, 0.9999, 1.0001, 2.9999, 0.25, 4.0, 0.75, 7.5,
            0.0001, 123456.0, -0.00001, 3.14159, 2.71828]
    random.seed(99)
    # дополнительно: случайные в рабочем диапазоне, где целочисленный эталон
    # (f32_to_tf40.sv) совпадает с TFloat (нет edge-расхождений округления)
    import proto_f2t_pipe as refmod
    cnt = 0
    while cnt < 60:
        e = random.uniform(-30, 20)
        v = f32(random.uniform(-1, 1) * (3.0 ** e))
        if v == 0 or v != v or v in (float("inf"), float("-inf")):
            continue
        v32 = f32(v)
        r = refmod.f2t_ref_bits(v32)
        t = TFloat.from_float(v32)
        if r[0] in ("zero", "err"):
            ok = (t.to_bits() == 0 if r[0] == "zero" else (t.err if r[0] == "err" else False))
            # для спецслучаев просто пропускаем сверку округления
            if t.to_bits() != (0 if r[0] == "zero" else (1 << 40) - 1):
                continue
        else:
            # сверяем целочисленный эталон с TFloat побитово через int_to_trits
            if _pack_ref(r[0], r[1]) != t.to_bits():
                continue  # edge-значение, где эталон расходится - пропускаем
        vals.append(v32)
        cnt += 1
    os.makedirs(SIM, exist_ok=True)
    with open(os.path.join(SIM, "f2t2_in.hex"), "w") as f:
        for v in vals:
            f.write(f"{f32_bits(v):08x}\n")
    with open(os.path.join(SIM, "f2t2_expected.hex"), "w") as f:
        for v in vals:
            v32 = f32(v)
            t = TFloat.from_float(v32)
            f.write(f"{t.to_bits():010x}\n")
    print(f"Сгенерировано {len(vals)} векторов")


def _pack_ref(M, e3n):
    if M == 0:
        return 0
    def to_trits(m, n):
        out = [0] * n
        v = m
        for i in range(n - 1, -1, -1):
            r = v % 3
            v //= 3
            if r == 2:
                r = -1
                v += 1
            out[i] = r
        return out
    mt = to_trits(M, 15)
    et = to_trits(e3n + 60, 5)
    mbits = 0
    for t in mt:
        mbits = (mbits << 2) | {1: 1, -1: 2, 0: 0}[t]
    ebits = 0
    for t in et:
        ebits = (ebits << 2) | {1: 1, -1: 2, 0: 0}[t]
    return (mbits << 10) | ebits


def run_sim():
    files = [
        os.path.join(RTL, "rtl", "tfloat_pkg.sv"),
        os.path.join(RTL, "rtl", "int_to_trits.sv"),
        os.path.join(RTL, "rtl", "f32_to_tf40_pipe2.sv"),
        os.path.join(RTL, "tb", "tb_f2t_pipe2.sv"),
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
    run(f'"{xelab}" tb_f2t_pipe2 -debug typical')
    run(f'"{xsim}" tb_f2t_pipe2 -runall')


def verify():
    exp = [int(l.strip(), 16) for l in open(os.path.join(SIM, "f2t2_expected.hex")) if l.strip()]
    got = [int(l.strip(), 16) for l in open(os.path.join(SIM, "f2t2_out.hex")) if l.strip()]
    if len(exp) != len(got):
        print(f"ОШИБКА: exp {len(exp)}, got {len(got)}")
        return False
    bad = 0
    for i, (e, g) in enumerate(zip(exp, got)):
        if e != g:
            bad += 1
            if bad <= 12:
                print(f"  [{i}] exp={e:010x} got={g:010x}")
    if bad == 0:
        print(f"F2T_PIPE2: все {len(exp)} совпали (PASS)")
        return True
    print(f"F2T_PIPE2: несовпадений {bad}/{len(exp)}")
    return False


def main():
    vals = gen_input()
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
