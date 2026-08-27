"""Сверка блочных tbyte_add / tbyte_mul с Python-моделью."""
from __future__ import annotations
import sys, os, subprocess, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model_tbyte as M

RTL = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(RTL, "sim")
XIL_BIN = "C:/AMDDesignTools/Vivado/2021.2/bin"
os.makedirs(SIM, exist_ok=True)


def gen_add(n=5000):
    random.seed(11)
    with open(os.path.join(SIM, "tbyte_add_in.hex"), "w") as f:
        with open(os.path.join(SIM, "tbyte_add_expected.hex"), "w") as fe:
            for _ in range(n):
                a = random.randrange(256)
                b = random.randrange(256)
                c = random.choice([0, 1, 2, 1, 2])  # 0,1,2 (2=-1), чаще 0
                cin = [0, 1, 2][c % 3]
                f.write(f"{a:02x} {b:02x} {cin:02x}\n")
                s, co = M.add_bytes(a, b, M.code_to_trit(cin))
                co_code = M.trit_to_code(co)
                fe.write(f"{s:02x} {co_code:02x}\n")
    print("add vectors ok")


def gen_mul(n=5000):
    random.seed(12)
    with open(os.path.join(SIM, "tbyte_mul_in.hex"), "w") as f:
        with open(os.path.join(SIM, "tbyte_mul_expected.hex"), "w") as fe:
            for _ in range(n):
                a = random.randrange(256)
                b = random.randrange(256)
                f.write(f"{a:02x} {b:02x}\n")
                p = M.mul_bytes(a, b)
                fe.write(f"{p:04x}\n")
    print("mul vectors ok")


def run_sim(tb, files):
    xvlog = os.path.join(XIL_BIN, "xvlog.bat")
    xelab = os.path.join(XIL_BIN, "xelab.bat")
    xsim = os.path.join(XIL_BIN, "xsim.bat")
    def run(cmd):
        r = subprocess.run(cmd, shell=True, cwd=RTL, capture_output=True, text=True)
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
    run(f'"{xelab}" {tb} -debug typical')
    run(f'"{xsim}" {tb} -runall')


def verify(exp_path, out_path, label, ncols):
    exp = [tuple(int(x, 16) for x in l.strip().split()) for l in open(exp_path) if l.strip()]
    got = [tuple(int(x, 16) for x in l.strip().split()) for l in open(out_path) if l.strip()]
    bad = 0
    for i, (e, g) in enumerate(zip(exp, got)):
        if e != g:
            bad += 1
            if bad <= 10:
                print(f"  [{i}] exp={e} got={g}")
    print(f"{label}: проверено {len(exp)}, несовпадений {bad}")
    return bad == 0


def main():
    gen_add()
    run_sim("tb_tbyte_add", [
        os.path.join(RTL, "tbyte_add.sv"),
        os.path.join(RTL, "tb_tbyte_add.sv"),
    ])
    ok1 = verify(os.path.join(SIM, "tbyte_add_expected.hex"),
                 os.path.join(SIM, "tbyte_add_out.hex"), "TBYTE_ADD", 2)
    gen_mul()
    run_sim("tb_tbyte_mul", [
        os.path.join(RTL, "tbyte_mul.sv"),
        os.path.join(RTL, "tb_tbyte_mul.sv"),
    ])
    ok2 = verify(os.path.join(SIM, "tbyte_mul_expected.hex"),
                 os.path.join(SIM, "tbyte_mul_out.hex"), "TBYTE_MUL", 1)
    sys.exit(0 if (ok1 and ok2) else 1)


if __name__ == "__main__":
    main()
