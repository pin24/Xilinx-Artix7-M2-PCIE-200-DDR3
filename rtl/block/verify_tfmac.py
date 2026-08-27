"""Сверка MAC-блока (tfmac) с Python-эталоном arith48 (mul/add)."""
from __future__ import annotations
import sys, os, subprocess, struct, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ternary_sw"))

from block.tfloat48 import TFloat, M_TRITS, E_TRITS
from block import arith48

RTL = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(RTL, "sim")
XIL_BIN = "C:/AMDDesignTools/Vivado/2021.2/bin"
os.makedirs(SIM, exist_ok=True)


def f32(x): return struct.unpack("f", struct.pack("f", x))[0]


def to_bits48(t):
    """TFloat -> 48-бит: {E(8), M(40)}. E хранит e напрямую (4 трита)."""
    m = t.m_int & ((1 << 40) - 1)
    e = t.e_int & 0xFF
    return (e << 40) | m


def gen_input(ncase=300):
    random.seed(31)
    with open(os.path.join(SIM, "tfmac_in.hex"), "w") as f:
        with open(os.path.join(SIM, "tfmac_expected.hex"), "w") as fe:
            n = 0
            while n < ncase:
                a = f32(random.uniform(-10, 10))
                b = f32(random.uniform(-10, 10))
                if a == 0 or b == 0:
                    continue
                ta, tb = TFloat.from_float(a), TFloat.from_float(b)
                op = n % 2
                if op == 0:
                    ref = arith48.mul(ta, tb)
                else:
                    ref = arith48.add(ta, tb)
                f.write(f"{op:02x} {to_bits48(ta):012x} {to_bits48(tb):012x}\n")
                fe.write(f"{to_bits48(ref):012x}\n")
                n += 1
    print(f"Сгенерировано {ncase} векторов")


def run_sim():
    files = [
        os.path.join(RTL, "tbyte_add.sv"),
        os.path.join(RTL, "tbyte_mul.sv"),
        os.path.join(RTL, "tfmac.sv"),
        os.path.join(RTL, "tb_tfmac.sv"),
    ]
    xvlog = os.path.join(XIL_BIN, "xvlog.bat")
    xelab = os.path.join(XIL_BIN, "xelab.bat")
    xsim = os.path.join(XIL_BIN, "xsim.bat")
    def run(cmd):
        r = subprocess.run(cmd, shell=True, cwd=RTL, capture_output=True, text=True)
        if r.returncode != 0:
            print("CMD FAIL:", cmd); print(r.stdout[-1400:]); print(r.stderr[-1400:])
        return r
    for d in ["xsim.dir", "xsim.cmd", "xsim.log"]:
        p = os.path.join(RTL, d)
        if os.path.isdir(p):
            import shutil; shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)
    run(f'"{xvlog}" -sv {" ".join(files)}')
    run(f'"{xelab}" tb_tfmac -debug typical')
    run(f'"{xsim}" tb_tfmac -runall')


def verify():
    exp = [int(l.strip(), 16) for l in open(os.path.join(SIM, "tfmac_expected.hex")) if l.strip()]
    got = [int(l.strip(), 16) for l in open(os.path.join(SIM, "tfmac_out.hex")) if l.strip()]
    if len(exp) != len(got):
        print(f"ОШИБКА: exp {len(exp)}, got {len(got)}")
        return False
    bad = 0
    for i, (e, g) in enumerate(zip(exp, got)):
        if e != g:
            bad += 1
            if bad <= 12:
                print(f"  [{i}] exp={e:012x} got={g:012x}")
    print(f"TFMAC: проверено {len(exp)}, несовпадений {bad}")
    return bad == 0


def main():
    gen_input()
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
