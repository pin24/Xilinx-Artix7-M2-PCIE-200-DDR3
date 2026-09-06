#!/usr/bin/env python3
# =============================================================================
# proof_tree_par.py
# Доказательство Шага 2 пайплайнинга дерева (compute_dot_par_raw, ADDERS
# barrel-аддеров) и фикса BUG-041 (нулевые операнды tfadd_raw). Локально,
# без HDL-симулятора.
#
# Секции:
#   T0: конвенции 48-битного слова: мои декодеры (m,e) == arith48/_bits_to_tf
#   Z1: BUG-041: аддер БЕЗ zero-shortcut (коммиченная семантика до фикса)
#       теряет ненулевой операнд при нулевом «большом»; фикс: x+0 == norm(x),
#       0+0 == 0 (семантика golden _raw_add)
#   Z2: фикс не трогает ненулевые операнды: add_fixed == add_barrel
#   T1: цикл-точная модель дерева (стрид-локстеп, back-to-back) == golden
#       dot_ref_raw (verify_compute_dot_par_raw.py): random, тернарные веса
#       (нули!), все-нулевые веса, нули в данных — бит-в-бит + K-инвариантность
#   T2: K-инвариантность на прямых словах, ВКЛЮЧАЯ SAT/underflow/нули:
#       K из {1,2,3,4,5,7,8,13,16,31} дают идентичные результаты
#   T3: инварианты протокола (период аддера >= 6, нет deadlock) + таблица
#       латентностей tree/dot по K (NUM_MAC 16/32)
# Запуск: python3 proof_tree_par.py [NUM_MAC]   -> ALL PROOFS PASSED
# =============================================================================
import sys, os, random

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# verify_compute_dot_par_raw при импорте читает argv[1] как NUM_MAC —
# сознательно: тот же аргумент, что и у этого скрипта.
from verify_compute_dot_par_raw import (
    dot_ref_raw, _bits_to_tf, f32, to_bits48,
)
from block import arith48
from block.tfloat48 import TFloat

W  = 42
M40 = (3 ** 40 - 1) // 2
SAT = (0xFF << 40) | ((1 << 40) - 1)
random.seed(20260907)

fails = 0
def check(name, ok, detail=""):
    global fails
    if not ok:
        print(f"FAIL {name}: {detail}")
        fails += 1

# ---------- сбалансированные триты (как в proof_tfadd_barrel.py) ----------
def to_trits(x, w=W):
    t = []
    for _ in range(w):
        r = x % 3
        if r == 2:
            r = -1; x = (x + 1) // 3
        else:
            x = (x - r) // 3
        t.append(r)
    assert x == 0, f"value {x} does not fit in {w} trits"
    return t

def shift_k(x, k):
    if k == 0:
        return x
    t = to_trits(x, W + 8)
    rbal = sum(t[i] * 3 ** i for i in range(k))
    return (x - rbal) // (3 ** k)

def floor_k(x, k):
    if k == 0:
        return x
    return (abs(x) // (3 ** k)) * (1 if x >= 0 else -1)

def canon_P_hw(x):
    t = to_trits(abs(x), W)
    p = -1
    for i in range(W - 1, -1, -1):
        if t[i] != 0:
            p = i
            break
    if p <= 0:
        return p
    rest_top = 0
    for i in range(p - 1, -1, -1):
        if t[i] != 0:
            rest_top = t[i]
            break
    return p - 1 if rest_top == -1 else p

def exp_code(e):
    out = 0
    x = e
    for i in range(4):
        q = abs(x) // 3 * (1 if x >= 0 else -1)
        rv = x - 3 * q
        if rv == 2:    code, q = 2, q + 1   # N1 (x = 3(q+1) - 1)
        elif rv == -2: code, q = 1, q - 1   # P1 (x = 3(q-1) + 1) — КАК В SV (2'b01); было 2 — транскрипционная ошибка
        elif rv == 1:  code = 1             # P1
        elif rv == -1: code = 2             # N1
        else:          code = 0
        out |= code << (2 * i)
        x = q
    return out

def trit_pattern(t):
    p = 0
    for i, ti in enumerate(t):
        if ti == 1:   c = 1
        elif ti == -1: c = 2
        else:         c = 0
        p |= c << (2 * i)
    return p

def pack48(e_sum, s):
    if s == 0 or e_sum < -40:
        return 0
    if e_sum > 40:
        return SAT
    return (exp_code(e_sum) << 40) | trit_pattern(to_trits(s, 20))

def norm_barrel(s, e_sum):
    if s == 0:
        return 0
    if e_sum > 40:
        return SAT
    P = canon_P_hw(s)
    if P >= 19:
        k = P - 18
        if e_sum + k > 40:
            return SAT
        s = floor_k(s, k); e_sum += k   # FLOOR — как в оригинале Шага 1 (shift_k = nearest — ОШИБКА копии)
    elif P <= 17:
        k = min(18 - P, e_sum + 40)
        if k > 0:
            s = s * (3 ** k); e_sum -= k
    return pack48(e_sum, s)

def add_barrel(a, ae, b, be):
    if ae > be:
        big, small, e_sum = a, b, ae
    else:
        big, small, e_sum = b, a, be
    de = abs(ae - be)
    small = shift_k(small, min(de, 22))
    return norm_barrel(big + small, e_sum)

# ---------- BUG-041: семантика нулевых операндов (как в RTL после фикса) ----------
def add_fixed(pa, ea, pb, eb):
    """Точный порт ИСПРАВЛЕННОГО tfadd_raw (za/zb в PH_IDLE)."""
    if pa == 0 and pb == 0:
        return pack48(0, 0)
    if pa == 0:
        return norm_barrel(pb, eb)     # m_big = b, m_small = 0, k = 0
    if pb == 0:
        return norm_barrel(pa, ea)     # m_big = a, m_small = 0, k = 0
    return add_barrel(pa, ea, pb, eb)  # обычный путь (не изменён)

def add_fixed_old(pa, ea, pb, eb):
    """Семантика ДО фикса BUG-041: big по экспоненте, нули не-special."""
    return add_barrel(pa, ea, pb, eb)

# ---------- декодеры 48-битного слова (RTL-раскладка: [47:40]=e, [39:0]=m) ----------
def _pat_val(pat, n_trits):
    v = 0
    for t in range(n_trits - 1, -1, -1):
        c = (pat >> (2 * t)) & 3
        tv = 1 if c == 1 else (-1 if c == 2 else 0)
        v = v * 3 + tv
    return v

def dec_m(word):
    return _pat_val(word & ((1 << 40) - 1), 20)

def dec_e(word):
    return _pat_val((word >> 40) & 0xFF, 4)

def word_direct(m, e):
    """Прямая сборка 48-битного слова из (знаковая мантисса, экспонента)."""
    ts = to_trits(abs(m), 20)
    if m < 0:
        ts = [-x for x in ts]
    return ((exp_code(e) & 0xFF) << 40) | trit_pattern(ts)

def word_from_float(x):
    return to_bits48(TFloat.from_float(f32(x)))

def rnd_prod():
    return random.randint(3 ** 36, 3 ** 38 - 1) * random.choice([-1, 1])

def rnd_tf48():
    return random.randint(3 ** 18, 3 ** 19 - 1) * random.choice([-1, 1])

def rnd_any():
    return random.randint(-M40, M40)

# =========================== T0: конвенции слова =============================
n = 0
for _ in range(3000):
    m = random.choice([random.randint(3 ** 18, 3 ** 19 - 1),
                       -random.randint(3 ** 18, 3 ** 19 - 1), 0,
                       random.randint(-(3 ** 20 - 1) // 2, (3 ** 20 - 1) // 2)])
    e = random.randint(-40, 40)
    w = word_direct(m, e)
    tf = _bits_to_tf(w)
    check("T0m", dec_m(w) == int(arith48._trits_value(arith48._m_trits(tf))),
          f"m={m} e={e}: {dec_m(w)} vs {arith48._trits_value(arith48._m_trits(tf))}")
    check("T0e", dec_e(w) == arith48._e_raw(tf),
          f"m={m} e={e}: {dec_e(w)} vs {arith48._e_raw(tf)}")
    # Оракул замысла: кодирование/декодирование обязаны вернуть ИСХОДНОЕ e
    # (ловит транскрипционные ошибки exp_code — самосогласованный кривой
    # кодировщик тут не проходит)
    check("T0i", dec_e(w) == e, f"m={m} e={e}: enc/dec дал {dec_e(w)}")
    n += 1
print(f"T0 word conventions (dec==arith48==intent): {n} cases")

# =========================== Z1: BUG-041 =====================================
n = n_old_diff = 0
zero_es = (-98, -40, -58, -18, -1, 0, 5, 22, 40, 62)
nonzeros = ((3 ** 18, 0), (3 ** 19 - 1, 40), (-(3 ** 19 - 1), -30),
            (1, -20), (-(3 ** 38), 30), (3 ** 18 + 5, -18))
for ez in zero_es:
    for (m, e) in nonzeros:
        for (pa, ea, pb, eb) in ((0, ez, m, e), (m, e, 0, ez)):
            r_new = add_fixed(pa, ea, pb, eb)
            r_old = add_fixed_old(pa, ea, pb, eb)
            if r_new != r_old:
                n_old_diff += 1
            want = norm_barrel(pb, eb) if pa == 0 else norm_barrel(pa, ea)
            check("Z1", r_new == want,
                  f"pa={pa} ea={ea} pb={pb} eb={eb}: {r_new:x} vs {want:x}")
            n += 1
for _ in range(20000):
    ez = random.randint(-98, 62)
    m = random.choice([rnd_prod, rnd_tf48, rnd_any])()
    e = random.randint(-98, 62)
    if random.random() < 0.5:
        pa, ea, pb, eb = 0, ez, m, e
    else:
        pa, ea, pb, eb = m, e, 0, ez
    r_new = add_fixed(pa, ea, pb, eb)
    if r_new != add_fixed_old(pa, ea, pb, eb):
        n_old_diff += 1
    want = norm_barrel(pb, eb) if pa == 0 else norm_barrel(pa, ea)
    check("Z1", r_new == want, f"pa={pa} ea={ea} pb={pb} eb={eb}")
    n += 1
print(f"Z1 BUG-041 fix: {n} cases (x+0==norm(x), 0+0==0); "
      f"old semantics diverges in {n_old_diff}/{n}")

# =========================== Z2: фикс не трогает ненулевые ==================
n = 0
for _ in range(5000):
    a = random.choice([rnd_prod, rnd_tf48, rnd_any])()
    b = random.choice([rnd_prod, rnd_tf48, rnd_any])()
    ae = random.randint(-98, 62); be = random.randint(-98, 62)
    if a == 0 or b == 0:
        continue
    check("Z2", add_fixed(a, ae, b, be) == add_barrel(a, ae, b, be),
          f"a={a} ae={ae} b={b} be={be}")
    n += 1
print(f"Z2 nonzero regression (fix==barrel): {n} cases")

# ===================== цикл-точная модель дерева (Шаг 2) =====================
class Adder:
    __slots__ = ("phase", "res")
    def __init__(self):
        self.phase = 0        # 0 IDLE,1 INIT,2 ALGN,3 ADD,4 NORM,5 DONE
        self.res = 0

class TreeStats:
    def __init__(self):
        self.last_done = {}
        self.min_period = 1 << 30
        self.dones = 0
    def add_done(self, k, t):
        if k in self.last_done:
            self.min_period = min(self.min_period, t - self.last_done[k])
        self.last_done[k] = t
        self.dones += 1

def run_tree(words_a, words_b, num_mac, n_add, mul_lat=49, stats=None):
    """Цикл-точная модель compute_dot_par_raw (Шаг 2).
    Интервал 0 = первый такт PH_MUL (входной пульс valid_in абстрагирован,
    к оценке dot добавляется +2 такта). Возвращает (слово, t_финиша, t_TREE)."""
    K = n_add
    NL = (num_mac - 1).bit_length()                 # $clog2 для степеней 2
    m_vis = 1 + mul_lat                             # m_valid_out видим здесь
    phase = 1                                       # PH_MUL
    t_lvl = t_cnt = 0; t_dst = 0; rnd_issue = 0; collected = 0
    busy = [False] * K; r_q = [0] * K
    ad_in = [False] * K; ad_ops = [None] * K
    ads = [Adder() for _ in range(K)]
    prod = [0] * num_mac; pe = [0] * num_mac
    tbuf = [[0] * num_mac, [0] * num_mac]
    dot_res = 0; res_reg = 0; valid_q = False
    t = 0; t_entry = None
    while t < 50000:
        # --- снимки ТЕКУЩЕГО интервала ---
        vout = [a.phase == 5 for a in ads]
        can_issue = all((not busy[k]) or vout[k] for k in range(K))
        # --- следующие состояния (порядок как в always_ff RTL) ---
        n_phase = phase; n_t_lvl = t_lvl; n_t_cnt = t_cnt; n_t_dst = t_dst
        n_rnd = rnd_issue; n_col = collected
        n_busy = busy[:]; n_r_q = r_q[:]
        n_ad_in = [False] * K; n_ad_ops = ad_ops[:]
        n_tbuf = [tbuf[0][:], tbuf[1][:]]
        n_dot = dot_res; n_res = res_reg; n_valid = False
        if phase == 1:                                        # PH_MUL
            if t == m_vis:
                for x in range(num_mac):
                    ma = dec_m(words_a[x]); ea = dec_e(words_a[x])
                    mb = dec_m(words_b[x]); eb = dec_e(words_b[x])
                    prod[x] = ma * mb; pe[x] = ea + eb - 18
                n_phase = 2; n_t_lvl = 0; n_t_dst = 0
                n_t_cnt = num_mac // 2; n_rnd = 0; n_col = 0
                n_busy = [False] * K
                t_entry = t + 1
        elif phase == 2:                                      # PH_TREE
            cdone = 0
            for k in range(K):                                # 1) сбор
                if vout[k]:
                    n_busy[k] = False
                    cdone += 1
                    if stats is not None:
                        stats.add_done(k, t)
                    if t_lvl == NL - 1:
                        if k == 0 and r_q[0] == 0:
                            n_dot = ads[0].res
                    else:
                        slot = k + r_q[k] * K
                        assert slot < t_cnt, f"запись мимо уровня: slot={slot} t_cnt={t_cnt}"
                        n_tbuf[t_dst][slot] = ads[k].res
            if can_issue and rnd_issue * K < t_cnt:           # 2) выдача (lockstep)
                base = rnd_issue * K
                for k in range(K):
                    if base + k < t_cnt:
                        n_ad_in[k] = True
                        n_busy[k] = True
                        n_r_q[k] = rnd_issue
                        if t_lvl == 0:
                            pa = prod[2 * (base + k)]; ea = pe[2 * (base + k)]
                            pb = prod[2 * (base + k) + 1]; eb = pe[2 * (base + k) + 1]
                        else:
                            va = tbuf[1 - t_dst][2 * (base + k)]
                            vb = tbuf[1 - t_dst][2 * (base + k) + 1]
                            pa = dec_m(va); ea = dec_e(va)
                            pb = dec_m(vb); eb = dec_e(vb)
                        n_ad_ops[k] = (pa, ea, pb, eb)
                n_rnd = rnd_issue + 1
            if collected + cdone >= t_cnt:                    # 3) уровень завершён
                assert collected + cdone == t_cnt, "пересбор результатов"
                assert not any(n_busy), "busy не очищен на выходе уровня"
                if t_lvl == NL - 1:
                    n_phase = 3
                else:
                    n_t_lvl = t_lvl + 1; n_t_dst = 1 - t_dst
                    n_t_cnt = t_cnt >> 1; n_rnd = 0; n_col = 0
            else:
                n_col = collected + cdone
                assert n_col <= t_cnt, "collected > t_cnt"
        else:                                                 # PH_DONE
            n_res = dot_res; n_valid = True; n_phase = 0
        # --- аддеры: сэмплируют ad_in текущего интервала (как tfadd_raw) ---
        for k in range(K):
            a = ads[k]
            if a.phase == 0:
                if ad_in[k]:
                    a.res = add_fixed(*ad_ops[k])
                    a.phase = 1
            elif a.phase == 5:
                a.phase = 0
            else:
                a.phase += 1
        # --- коммит ---
        phase = n_phase; t_lvl = n_t_lvl; t_cnt = n_t_cnt; t_dst = n_t_dst
        rnd_issue = n_rnd; collected = n_col
        busy = n_busy; r_q = n_r_q
        ad_in = n_ad_in; ad_ops = n_ad_ops
        tbuf = n_tbuf; dot_res = n_dot; res_reg = n_res; valid_q = n_valid
        t += 1
        if valid_q:
            break
    assert valid_q, "deadlock дерева (50000 интервалов)"
    return res_reg, t, t_entry

# =========================== T1: модель == golden ============================
NUM_MAC = int(sys.argv[1]) if len(sys.argv) > 1 else 32

def t1_vectors(num_mac):
    vecs = []
    for _ in range(60):                                   # оба random
        vecs.append(([f32(random.uniform(-10, 10)) for _ in range(num_mac)],
                     [f32(random.uniform(-10, 10)) for _ in range(num_mac)]))
    for _ in range(60):                                   # тернарные веса (нули!)
        vecs.append(([f32(random.uniform(-10, 10)) for _ in range(num_mac)],
                     [float(random.choice([-1, 0, 1])) for _ in range(num_mac)]))
    for _ in range(15):                                   # все веса нулевые
        vecs.append(([f32(random.uniform(-10, 10)) for _ in range(num_mac)],
                     [0.0] * num_mac))
    for _ in range(30):                                   # точные нули в данных
        a = [f32(random.uniform(-10, 10)) for _ in range(num_mac)]
        for j in random.sample(range(num_mac), max(1, num_mac // 4)):
            a[j] = 0.0
        vecs.append((a, [f32(random.uniform(-10, 10)) for _ in range(num_mac)]))
    for _ in range(15):                                   # тернарные данные и веса
        vecs.append(([float(random.choice([-1, 0, 1])) for _ in range(num_mac)],
                     [float(random.choice([-1, 0, 1])) for _ in range(num_mac)]))
    return vecs

n = 0; n_sat = 0
for (a, b) in t1_vectors(NUM_MAC):
    wa = [word_from_float(x) for x in a]
    wb = [word_from_float(y) for y in b]
    gold = dot_ref_raw(wa, wb)
    r8, _, _ = run_tree(wa, wb, NUM_MAC, 8)
    if r8 == SAT or gold == SAT:
        n_sat += 1
        continue
    check("T1", r8 == gold, f"K=8 {r8:012x} vs golden {gold:012x}\n  a={a}\n  b={b}")
    r1, _, _ = run_tree(wa, wb, NUM_MAC, 1)
    r4, _, _ = run_tree(wa, wb, NUM_MAC, 4)
    check("T1", r1 == r8 == r4, f"K-инвариантность на real-векторе: {r1:012x}/{r4:012x}/{r8:012x}")
    n += 1
print(f"T1 model==golden (NUM_MAC={NUM_MAC}, K=8, zeros/ternary included): "
      f"{n} vectors (SAT-skipped {n_sat})")

# ============== T2: K-инвариантность на прямых словах (SAT и др.) ============
K_LIST = [1, 2, 3, 4, 5, 7, 8, 13, 16, 31]
def t2_vector(num_mac):
    es = [-40, -30, -18, 0, 18, 19, 39, 40]
    M20 = (3 ** 20 - 1) // 2
    va = []
    for _ in range(num_mac):
        if random.random() < 0.25:
            va.append(0)                                  # нулевое слово
        else:
            # мантисса обязана влезать в 20 тритов (|m| <= (3^20-1)/2)
            m = random.choice([rnd_tf48(), random.randint(-M20, M20),
                               M20, -M20, M20 - 1, -(M20 - 1)])
            va.append(word_direct(m, random.choice(es)))
    return va
n = 0
for _ in range(120):
    wa = t2_vector(NUM_MAC)
    wb = t2_vector(NUM_MAC)
    res = {}
    for K in K_LIST:
        res[K], _, _ = run_tree(wa, wb, NUM_MAC, K)
    base = res[1]
    for K in K_LIST:
        check("T2", res[K] == base, f"K={K}: {res[K]:012x} vs K=1 {base:012x}")
    n += 1
# направленные: все-нулевые, сатурация, одиночный ненулевой
directed = [([0] * NUM_MAC, [0] * NUM_MAC),
            ([word_direct((3 ** 20 - 1) // 2, 40)] * NUM_MAC,
             [word_direct((3 ** 20 - 1) // 2, 40)] * NUM_MAC),
            ([0] * NUM_MAC, [word_direct(3 ** 18, -40)] * NUM_MAC),
            ([word_direct(3 ** 19, 0)] + [0] * (NUM_MAC - 1),
             [word_direct(-(3 ** 19), 0)] + [0] * (NUM_MAC - 1))]
for wa, wb in directed:
    res = {}
    for K in K_LIST:
        res[K], _, _ = run_tree(wa, wb, NUM_MAC, K)
    for K in K_LIST:
        check("T2d", res[K] == res[1], f"K={K}: {res[K]:012x} vs {res[1]:012x}")
    n += 1
print(f"T2 K-invariance (incl. SAT/underflow/zeros, K={K_LIST}): {n} vectors")

# ===================== T3: инварианты протокола + латентности ================
n = 0
for nm in (16, 32):
    for K in (1, 2, 3, 4, 5, 6, 8, 12, 16, 32):
        st = TreeStats()
        wa = [word_direct(3 ** 18 + (j % 7), (j % 5) - 2) for j in range(nm)]
        wb = [word_direct(3 ** 19 - (j % 11), (j % 3)) for j in range(nm)]
        _, t_fin, t_entry = run_tree(wa, wb, nm, K, stats=st)
        assert st.min_period >= 6, f"период аддера {st.min_period} < 6 (K={K})"
        tree_cyc = t_fin - t_entry
        dot_est = t_fin + 2                                # + пульс valid_in и m_valid_in
        if nm == 32:
            print(f"  T3 NUM_MAC={nm} ADDERS={K:2d}: tree={tree_cyc:3d} тактов, "
                  f"dot~{dot_est:3d} (PH_MUL~49 абстрактно)")
        n += 1
print(f"T3 protocol invariants (period>=6, no deadlock): {n} конфигураций")

print("=" * 60)
if fails == 0:
    print("ALL PROOFS PASSED")
else:
    print(f"PROOFS FAILED: {fails}")
