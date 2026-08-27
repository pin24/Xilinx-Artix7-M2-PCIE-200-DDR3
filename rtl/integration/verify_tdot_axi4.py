"""Сверка AXI4-мастера tdot_axi4 (NUM_MAC) с Python-моделью.

Генерирует входной hex (64-битные слова: data[32] затем weights[32],
распакованно 8 байт/элемент), запускает xsim, сверяет результат из
регистров с эталоном dot_raw (см. verify_compute_dot_par_raw.py).
"""
from __future__ import annotations
import sys, os, subprocess, struct, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ternary_sw"))

from block.tfloat48 import TFloat
from block import arith48

RTL = os.path.dirname(os.path.abspath(__file__))
BLOCK = os.path.join(RTL, "..", "block")
SIM = os.path.join(RTL, "sim")
XIL_BIN = "C:/AMDDesignTools/Vivado/2021.2/bin"
NUM_MAC = int(sys.argv[1]) if len(sys.argv) > 1 else 32
os.makedirs(SIM, exist_ok=True)


def f32(x): return struct.unpack("f", struct.pack("f", x))[0]


def to_bits48(t):
    return ((t.e_int & 0xFF) << 40) | (t.m_int & ((1 << 40) - 1))


# ---- тритовые примитивы (копия из verify_compute_dot_par_raw.py) ----

def _to_trits(v, n):
    out = [0] * n
    x = v
    for i in range(n):
        r = x % 3
        x //= 3
        if r == 2:
            r = -1; x += 1
        out[i] = r
    return out


def _from_trits(ts):
    v = 0
    for t in reversed(ts):
        v = v * 3 + t
    return v


def _add_const(ts, c):
    out = ts[:]
    for i in range(len(out)):
        s = out[i] + c
        if s > 1:
            out[i] = s - 3; c = 1
        elif s < -1:
            out[i] = s + 3; c = -1
        else:
            out[i] = s; c = 0
    return out


def _shift1(ts):
    return ts[1:] + [0]


def _rhu_next(m, W=42):
    ts = _to_trits(m, W)
    sign_neg = 0
    for t in range(W - 1, -1, -1):
        if ts[t] != 0:
            sign_neg = (ts[t] == -1); break
    mag = [-t for t in ts] if sign_neg else ts
    mp1 = _add_const(mag, 1)
    fd = _shift1(mp1)
    if mp1[0] == -1:
        fd = _add_const(fd, -1)
    if sign_neg:
        fd = [-t for t in fd]
    return _from_trits(fd)


def _shift_seq(m, k):
    for _ in range(k):
        m = _rhu_next(m)
    return m


def _norm_raw_rtl(m, e):
    W = 42
    while True:
        ts = _to_trits(m, W)
        v = abs(_from_trits(ts))
        sneg = 0
        for t in range(W - 1, -1, -1):
            if ts[t] != 0:
                sneg = (ts[t] == -1); break
        if v == 0:
            return (0, 0)
        if e > 40:
            return None
        if v >= 3 ** 19:
            mag = [-t for t in ts] if sneg else ts
            fd = _shift1(mag)
            if mag[0] == -1:
                fd = _add_const(fd, -1)
            if sneg:
                fd = [-t for t in fd]
            m = _from_trits(fd)
            e = e + 1
        elif v < 3 ** 18 and e > -40:
            m = m * 3
            e = e - 1
        else:
            return (m, e)


def _raw_mul(a, b):
    ma = int(arith48._trits_value(arith48._m_trits(a)))
    mb = int(arith48._trits_value(arith48._m_trits(b)))
    ea = arith48._e_raw(a); eb = arith48._e_raw(b)
    return (ma * mb, ea + eb - 18)


def _raw_add(pa, ea, pb, eb):
    if pa == 0: return (pb, eb)
    if pb == 0: return (pa, ea)
    if ea > eb:
        pb = _shift_seq(pb, ea - eb); e = ea
    elif eb > ea:
        pa = _shift_seq(pa, eb - ea); e = eb
    else:
        e = ea
    return _norm_raw_rtl(pa + pb, e)


def _bits_to_tf(b):
    return TFloat.from_bits(((b & ((1 << 40) - 1)) << 8) | ((b >> 40) & 0xFF))


def dot_ref_raw(vals_a, vals_b):
    a = [_bits_to_tf(v) for v in vals_a]
    b = [_bits_to_tf(v) for v in vals_b]
    products = [_raw_mul(x, y) for x, y in zip(a, b)]
    while len(products) > 1:
        nxt = []
        for i in range(0, len(products) - 1, 2):
            nxt.append(_raw_add(products[i][0], products[i][1],
                                products[i + 1][0], products[i + 1][1]))
        if len(products) % 2 == 1:
            nxt.append(products[-1])
        products = nxt
    m, e = products[0]
    if m == 0:
        return 0
    return to_bits48(arith48._norm_raw(m, e))


def gen_input(ncase=4):
    random.seed(71)
    with open(os.path.join(SIM, "tb_tdot_axi4_in.hex"), "w") as f:
        with open(os.path.join(SIM, "tb_tdot_axi4_expected.hex"), "w") as fe:
            for _ in range(ncase):
                a = [f32(random.uniform(-10, 10)) for _ in range(NUM_MAC)]
                b = [f32(random.uniform(-10, 10)) for _ in range(NUM_MAC)]
                for x in a:
                    f.write(f"{to_bits48(TFloat.from_float(x)):012x}\n")
                for y in b:
                    f.write(f"{to_bits48(TFloat.from_float(y)):012x}\n")
                r = dot_ref_raw([to_bits48(TFloat.from_float(x)) for x in a],
                                [to_bits48(TFloat.from_float(y)) for y in b])
                fe.write(f"{r:012x}\n")
    print(f"Сгенерировано {ncase} случаев (NUM_MAC={NUM_MAC}, {2*NUM_MAC} слов/случай)")


def run_sim():
    # параметризуем tb под нужный NUM_MAC
    tb_path = os.path.join(RTL, "tb_tdot_axi4.sv")
    tb_src = open(tb_path).read()
    tb_src = tb_src.replace("parameter int NUM_MAC = 32;",
                            f"parameter int NUM_MAC = {NUM_MAC};")
    tb_use = os.path.join(RTL, "tb_tdot_axi4_use.sv")
    open(tb_use, "w").write(tb_src)
    files = [
        os.path.join(BLOCK, "tbyte_add.sv"),
        os.path.join(BLOCK, "tbyte_mul.sv"),
        os.path.join(BLOCK, "tfadd_raw.sv"),
        os.path.join(BLOCK, "tfmul_raw.sv"),
        os.path.join(BLOCK, "compute_dot_par_raw.sv"),
        os.path.join(RTL, "tdot_axi4.sv"),
        tb_use,
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
    run(f'"{xelab}" tb_tdot_axi4 -debug typical')
    run(f'"{xsim}" tb_tdot_axi4 -runall')


def verify():
    exp = [int(l.strip(), 16) for l in open(os.path.join(SIM, "tb_tdot_axi4_expected.hex")) if l.strip()]
    got = [int(l.strip(), 16) for l in open(os.path.join(SIM, "tb_tdot_axi4_out.hex")) if l.strip()]
    if len(exp) != len(got):
        print(f"ОШИБКА: exp {len(exp)}, got {len(got)}")
        return False
    bad = 0
    for i, (e, g) in enumerate(zip(exp, got)):
        if e != g:
            bad += 1
            if bad <= 10:
                print(f"  [{i}] exp={e:012x} got={g:012x}")
    print(f"tdot_axi4(NUM_MAC={NUM_MAC}): проверено {len(exp)}, несовпадений {bad}")
    return bad == 0


def main():
    gen_input()
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
