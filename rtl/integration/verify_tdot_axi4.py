"""Сверка AXI4-мастера tdot_axi4 (NUM_MAC) с Python-моделью.

Генерирует входной hex (64-битные слова: data[32] затем weights[32],
распакованно 8 байт/элемент), запускает xsim, сверяет результат из
регистров с эталоном dot_raw (см. verify_compute_dot_par_raw.py).

Эталон dot_ref_raw воспроизводит RTL tdot_axi4 БИТ-В-БИТ, включая
квантование нормализации tfadd_raw (P_can по знаковому скану sum, без
приведения |sum|). Для отрицательных сумм у границы степени 3 это даёт
НЕКОНОНИЧНУЮ мантиссу (вне [3^18,3^19)), как на железе; значение при этом
математически верно. Ключевая логика: _norm_rtl_sum + _raw_mul c
40-тритной обрезкой произведения.
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
_CANDS = ["C:/AMDDesignTools/2025.2/Vivado/bin", "C:/Xilinx/Vivado/2025.2/bin",
          "C:/AMDDesignTools/Vivado/2021.2/bin"]
XIL_BIN = os.environ.get("VIVADO_BIN")
if not XIL_BIN:
    for c in _CANDS:
        if os.path.exists(os.path.join(c, "xvlog.bat")):
            XIL_BIN = c
            break
    else:
        XIL_BIN = _CANDS[0]
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


def _shift_seq(m, k, W=42):
    # RTL ALGN-баррель tfadd_raw: чистый сдвиг вправо на k тритов СБРОСОМ
    # младших k тритов (algn_y[t] = m_small[t+k]), k = min(|de|, 22) — БЕЗ
    # round-half-up. _to_trits/_from_trits оба LSB-first: низкий трит = индекс 0.
    # Сдвиг вправо отбрасывает k НИЗКИХ тритов и дописывает нули СВЕРХУ:
    # out[i] = in[i+k]  <=>  список ts[k:] + [0]*k. Прежний _rhu_next
    # (round-half-up) расходился с RTL и давал накопленную ошибку через дерево.
    k = min(k, 22)
    if k <= 0:
        return m
    ts = _to_trits(m, W)          # LSB-first, ровно W тритов
    return _from_trits(ts[k:] + [0] * k)


def _norm_raw_rtl(m, e):
    """Нормализация к [3^18, 3^19) — ТОЧНАЯ копия P-каноники tfadd_raw.

    RTL (PH_NORM1C..PH_NORM2) нормализует ОДНИМ сдвигом с коррекцией границы,
    НЕ итерациями по одному триту:
      * P >= 19 (up_big): fq = |m| >> k (k = P-18, сброс низких k тритов),
        затем fq_dec = fq - 1, ЕСЛИ старший из отброшенных тритов (позиция
        k-1, 0-индекс LSB-first) == N1; e += k. Один шаг, не по-тритно.
      * P <= 17 (dn_small): m << (18-P) со сдвигом клампа e_sum+40; e -= (18-P).
    Прежняя версия итерировала однобитный _shift1+corr, что давало ДРУГОЕ
    округление низких тритов (накопленное расхождение через всё дерево).
    """
    W = 42
    if m == 0:
        return (0, 0)
    ts = _to_trits(m, W)                 # LSB-first, W тритов
    p_top = None; sneg = 0
    for t in range(W - 1, -1, -1):
        if ts[t] != 0:
            p_top = t; sneg = (ts[t] == -1); break
    if p_top is None:
        return (0, 0)
    rest_n1 = 0
    for t in range(p_top - 1, -1, -1):
        if ts[t] != 0:
            rest_n1 = (ts[t] == -1); break
    P = p_top - rest_n1
    if e > 40:
        return None
    mabs = abs(m)
    if P >= 19:
        k = P - 18
        kts = _to_trits(mabs, W)
        drop_hi = kts[k - 1] if k >= 1 else 0     # позиция k-1 = старший отброшенный
        fq = _from_trits(kts[k:] + [0] * k)        # |m| >> k (сброс низких k тритов)
        if drop_hi == -1:                          # старший отброшенный == N1 -> fq-1
            fq = fq - 1
        m = -fq if sneg else fq
        e = e + k
    elif P <= 17 and e > -40:
        k = 18 - P
        # RTL-клamp k_dn = min(k, e_sum+40)
        room = e + 40
        if room < k:
            k_dn = room if room > 0 else 0
        else:
            k_dn = k
        if k_dn:
            m = mabs * (3 ** k_dn)
            m = -m if sneg else m
            e = e - k_dn
    return (m, e)


def _raw_mul(a, b):
    ma = int(arith48._trits_value(arith48._m_trits(a)))
    mb = int(arith48._trits_value(arith48._m_trits(b)))
    ea = arith48._e_raw(a); eb = arith48._e_raw(b)
    # RTL tfmul_raw prod = 40 тритов (80 бит): старший выход-трит отбрасывается,
    # если произведение переполняет 40 тритов. Обычно no-op (максимум ~3^38).
    p = _from_trits(_to_trits(ma * mb, 80)[0:40])
    return (p, ea + eb - 18)


def _trunc20(v):
    """Низкие 20 тритов значения v (RTL: результат = sum[39:0])."""
    return _from_trits(_to_trits(v, 60)[0:20])


def _norm_rtl_sum(v, e_sum):
    """ТОЧНАЯ копия нормализации tfadd_raw (PH_NORM0A..PH_DONE): возвращает
    (mantissa_20_тритов, e_out). КЛЮЧЕВОЕ ОТЛИЧИЕ от идеальной каноники:
    P_can = p_top - rest_n1 считается по СКАНУ ЗНАКОВОГО sum (rest_n1 ищет
    первый ненулевой трит НИЖЕ p_top в исходных тритах sum, БЕЗ взятия |sum|).
    Для отрицательных сумм, у которых |sum| находится ровно на границе
    степени 3 (трит ниже p_top == 0, следующий вниз == N1), ПОДМЕНЯЕТ
    floor(log3|sum|) на p_top-1 (P_can=18 вместо 19) — нормализация НЕ
    срабатывает, мантисса остаётся НЕКОНОНИЧНОЙ (значение при этом верное:
    компенсируется экспонентой). Это поведение железа, и оно воспроизведено."
    """
    ts = _to_trits(v, 42)                 # LSB-first, ровно 42 трита
    p_found = any(t != 0 for t in ts)
    if not p_found:
        return (0, 0)
    p_top = None; sneg = 0
    for t in range(41, -1, -1):
        if ts[t] != 0:
            p_top = t; sneg = (ts[t] == -1); break
    rest_n1 = 0
    for t in range(p_top - 1, -1, -1):
        if ts[t] != 0:
            rest_n1 = (ts[t] == -1); break
    if p_top == 0:
        P_can = 0
    else:
        P_can = p_top - (1 if rest_n1 else 0)
    if e_sum > 40 or (P_can >= 19 and e_sum + (P_can - 18) > 40):
        return (None, None)               # sat -> все единицы
    if e_sum < -40:
        return (0, 0)                     # underflow -> 0
    t_abs = [-t if sneg else t for t in ts]
    m_abs = _from_trits(t_abs)
    if P_can >= 19:
        k = P_can - 18
        hi_drop = 0
        for i in range(k - 1, -1, -1):
            if t_abs[i] != 0:
                hi_drop = t_abs[i]; break
        fq = _from_trits(t_abs[k:] + [0] * k)
        if hi_drop == -1:
            fq -= 1
        m_out = -fq if sneg else fq
        e_out = e_sum + k
    elif P_can <= 17:
        k_dn = 18 - P_can
        room = e_sum + 40
        k_dn_c = room if room < k_dn else k_dn
        if k_dn_c < 0:
            k_dn_c = 0
        if k_dn_c:
            m_out = v * (3 ** k_dn_c)
            e_out = e_sum - k_dn_c
        else:
            m_out = v; e_out = e_sum
    else:
        m_out = v; e_out = e_sum          # P_can == 18: без сдвига
    return (_trunc20(m_out), e_out)


def _bits_to_tf(b):
    return TFloat.from_bits(((b & ((1 << 40) - 1)) << 8) | ((b >> 40) & 0xFF))


def _pack_raw(m20, e):
    """Упаковать ПРОИЗВОЛЬНЫЕ (мант., эксп.) в 48 бит файлового формата
    (E в старшем байте, M в младших 40 битах) БЕЗ повторной нормализации —
    точно как RTL output = {exp_code(e_sum), sum[39:0]}. Мант. может быть
    НЕКОНОНИЧНОЙ (вне [3^18,3^19)) — она кодируется как есть."""
    import block.trits as Tmod
    m_trits = arith48._round_int_to_trits(m20)
    e_trits = arith48._encode_exp(e)
    return to_bits48(TFloat(Tmod.pack(m_trits), Tmod.pack(e_trits)))


def _raw_add(pa, ea, pb, eb):
    if pa == 0: return _norm_rtl_flat(pb, eb)
    if pb == 0: return _norm_rtl_flat(pa, ea)
    if ea > eb:
        pb = _shift_seq(pb, ea - eb); e = ea
    elif eb > ea:
        pa = _shift_seq(pa, eb - ea); e = eb
    else:
        e = ea
    s = pa + pb
    return _norm_rtl_flat(s, e)


def _norm_rtl_flat(m, e):
    m20, e_out = _norm_rtl_sum(m, e)
    return (m20, e_out)


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
    if m == 0 and e == 0:
        return 0
    return _pack_raw(m, e)


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
        os.path.join(BLOCK, "tfadd48.sv"),
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
