#!/usr/bin/env python3
# =============================================================================
# proof_tfadd_barrel.py
# Доказательство эквивалентности (локально, без HDL-симулятора):
#   serial FSM tfadd_raw (текущий RTL, точная модель) VS barrel-версия (Шаг 1).
#
# Секции:
#   A0: точная потритовая модель rhu/fd3 == быстрая целочисленная модель
#   A1: rhu_next (танцы +1/-1) == чистый сбалансированный сдвиг на 1 (nearest)
#   A2: fd3 (floor по модулю) == sign*floor(|x|/3)
#   A3: k последовательных сдвигов == однотактный barrel (nearest и floor)
#   A4b: каноническая позиция P (HW-правило: P = p - [rest_top==N1]) == floor(log3|x|)
#   A4: NORM: serial-цикл == barrel (P, floor/3^k, x3^k, клампы e_sum)
#   A5: полный конвейер: serial == barrel бит-в-бит при de <= 63
#   A6: полный диапазон de: barrel == intent; de >= 64 — BUG-040 (cnt[5:0])
# Запуск: python3 proof_tfadd_barrel.py   (завершение: ALL PROOFS PASSED)
# =============================================================================
import random

W  = 42
M40 = (3 ** 40 - 1) // 2

random.seed(20260906)

# ---------- сбалансированные триты ----------
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

def from_trits(t):
    return sum(ti * 3 ** i for i, ti in enumerate(t))

def lsb_trit(x):
    r = x % 3
    return r - 3 if r == 2 else r

def top_pos_bal(x):
    """Позиция старшего ненулевого сбалансированного трита |x| (p)."""
    if x == 0:
        return -1
    t = to_trits(abs(x), W)
    for i in range(W - 1, -1, -1):
        if t[i] != 0:
            return i
    return -1

def canon_P_hw(x):
    """HW-правило: |x|>0 имеет старший трит P1 на позиции p;
    P = p - 1, если старший ненулевой трит НИЖЕ p равен N1, иначе P = p."""
    t = to_trits(abs(x), W)
    p = -1
    for i in range(W - 1, -1, -1):
        if t[i] != 0:
            p = i
            break
    if p <= 0:
        return p                      # x == 1 (p=0) -> P=0
    rest_top = 0
    for i in range(p - 1, -1, -1):
        if t[i] != 0:
            rest_top = t[i]
            break
    return p - 1 if rest_top == -1 else p

def canon_P_ref(x):
    """Референс: floor(log3(|x|)) — наибольшее j: 3^j <= |x|."""
    if x == 0:
        return -1
    # точный перебор по степеням (до 42 — дёшево)
    j = 0
    while j < 60 and 3 ** (j + 1) <= abs(x):
        j += 1
    return j if 3 ** j <= abs(x) else j - 1

# ---------- точные порты RTL-танцев ----------
def rhu_rtl(x):
    t = to_trits(x, W)
    sign_neg = False
    for i in range(W - 1, -1, -1):
        if t[i] != 0:
            sign_neg = (t[i] == -1)
            break
    mag = -x if sign_neg else x
    assert 0 <= mag <= M40, "rhu domain"
    mp1 = mag + 1
    ml = lsb_trit(mp1)
    fd = (mp1 - ml) // 3
    if ml == -1:
        fd -= 1
    return -fd if sign_neg else fd

def fd3_rtl(x):
    ax = abs(x)
    al = lsb_trit(ax)
    fd = (ax - al) // 3
    if al == -1:
        fd -= 1
    return -fd if x < 0 else fd

# ---------- быстрые примитивы ----------
def shift1(x):
    l = lsb_trit(x)
    return (x - l) // 3

def shift_k(x, k):
    if k == 0:
        return x
    t = to_trits(x, W + 8)
    rbal = sum(t[i] * 3 ** i for i in range(k))
    return (x - rbal) // (3 ** k)

def floor3(x):
    return (abs(x) // 3) * (1 if x >= 0 else -1)

def floor_k(x, k):
    if k == 0:
        return x
    return (abs(x) // (3 ** k)) * (1 if x >= 0 else -1)

def exp_code(e):
    out = 0
    x = e
    for i in range(4):
        q = abs(x) // 3 * (1 if x >= 0 else -1)
        rv = x - 3 * q
        if rv == 2:    code, q = 2, q + 1
        elif rv == -2: code, q = 1, q - 1   # P1, как в SV (2'b01); было 2 — транскрипционная ошибка модели (найдена proof_tree_par.py T0/T1, 2026-09-06)
        elif rv == 1:  code = 1
        elif rv == -1: code = 2
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
    """Точный порт PH_DONE: 48-битный результат (None-эквиваленты фиксированы)."""
    if s == 0 or e_sum < -40:
        return 0
    if e_sum > 40:
        return (0xFF << 40) | ((1 << 40) - 1)
    return (exp_code(e_sum) << 40) | trit_pattern(to_trits(s, 20))

# ---------- полные модели (возвращают pack48) ----------
def norm_serial(s, e_sum):
    while True:
        val = abs(s)
        if val == 0:
            break
        if e_sum > 40:
            break
        if val >= 3 ** 19:
            s = floor3(s); e_sum += 1
        elif val < 3 ** 18 and e_sum > -40:
            s = s * 3; e_sum -= 1
        else:
            break
    return pack48(e_sum, s)

def add_serial(a, ae, b, be):
    """Serial с багом cnt[5:0] (BUG-040)."""
    if ae > be:
        big, small, e_sum, de = a, b, ae, ae - be
    else:
        big, small, e_sum, de = b, a, be, be - ae
    cnt = de & 0x3F
    if cnt > 22:
        cnt = 22
    for _ in range(cnt):
        small = shift1(small)
    return norm_serial(big + small, e_sum)

def add_intent(a, ae, b, be):
    """Serial БЕЗ BUG-040: cnt = min(|de|, 22)."""
    if ae > be:
        big, small, e_sum, de = a, b, ae, ae - be
    else:
        big, small, e_sum, de = b, a, be, be - ae
    for _ in range(min(abs(de), 22)):
        small = shift1(small)
    return norm_serial(big + small, e_sum)

SAT = (0xFF << 40) | ((1 << 40) - 1)

def norm_barrel(s, e_sum):
    """NORM barrel: каноническая P, floor/3^k вверх, x3^k вниз, клампы."""
    if s == 0:
        return 0
    if e_sum > 40:
        return SAT
    P = canon_P_hw(s)
    if P >= 19:
        k = P - 18
        if e_sum + k > 40:
            return SAT
        s = floor_k(s, k); e_sum += k
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

# ---------- генераторы ----------
def edge_values():
    vs = [0, 1, -1, 2, -2, 3, -3]
    for j in range(0, 40):
        vs += [3 ** j, -(3 ** j), 3 ** j + 1, -(3 ** j + 1), 3 ** j - 1, -(3 ** j - 1)]
    vs += [M40, -M40, M40 - 1, -(M40 - 1), 3 ** 36, 3 ** 38 - 1, -(3 ** 38 - 1)]
    vs += [3 ** 18, 3 ** 19 - 1, -(3 ** 19 - 1), 3 ** 20 - 1, -(3 ** 20 - 1)]
    vs += [3 ** 19, 3 ** 19 + 1, -(3 ** 19 + 1), (3 ** 19 + 1) // 2]
    return [v for v in vs if -M40 <= v <= M40]

def rnd_prod():
    return random.randint(3 ** 36, 3 ** 38 - 1) * random.choice([-1, 1])

def rnd_tf48():
    return random.randint(3 ** 18, 3 ** 19 - 1) * random.choice([-1, 1])

def rnd_any():
    return random.randint(-M40, M40)

fails = 0
def check(name, ok, detail=""):
    global fails
    if not ok:
        print(f"FAIL {name}: {detail}")
        fails += 1

# =========================== A1: rhu == shift1 ==============================
n = 0
for v in edge_values():
    check("A1", rhu_rtl(v) == shift1(v), f"x={v}"); n += 1
for _ in range(20000):
    v = random.randint(-M40, M40)
    check("A1", rhu_rtl(v) == shift1(v), f"x={v}"); n += 1
print(f"A1 rhu_rtl==shift1: {n} cases")

# =========================== A2: fd3 == floor ==============================
n = 0
for v in edge_values():
    want = (abs(v) // 3) * (1 if v >= 0 else -1)
    check("A2", fd3_rtl(v) == want, f"x={v}"); n += 1
print(f"A2 fd3_rtl==floor3: {n} cases")

# =========================== A0: faithful == fast serial ===================
def add_serial_faithful(a, ae, b, be):
    if ae > be:
        big, small, e_sum, de = a, b, ae, ae - be
    else:
        big, small, e_sum, de = b, a, be, be - ae
    cnt = de & 0x3F
    if cnt > 22:
        cnt = 22
    for _ in range(cnt):
        small = rhu_rtl(small)
    s = big + small
    while True:
        val = abs(s)
        if val == 0 or e_sum > 40:
            break
        if val >= 3 ** 19:
            s = fd3_rtl(s); e_sum += 1
        elif val < 3 ** 18 and e_sum > -40:
            s = s * 3; e_sum -= 1
        else:
            break
    return pack48(e_sum, s)

n = 0
for _ in range(3000):
    a = random.choice([rnd_prod, rnd_tf48, rnd_any])()
    b = random.choice([rnd_prod, rnd_tf48, rnd_any])()
    ae = random.randint(-98, 62); be = random.randint(-98, 62)
    r1 = add_serial_faithful(a, ae, b, be)
    r2 = add_serial(a, ae, b, be)
    check("A0", r1 == r2, f"a={a} ae={ae} b={b} be={be}: {r1} vs {r2}"); n += 1
print(f"A0 faithful==fast serial: {n} cases")

# =========================== A3: iterated == barrel =========================
n = 0
for k in range(0, 24):
    for v in edge_values()[:40]:
        x = v
        for _ in range(k):
            x = shift1(x)
        check("A3n", x == shift_k(v, k), f"v={v} k={k}"); n += 1
        y = v
        for _ in range(k):
            y = floor3(y)
        check("A3f", y == floor_k(v, k), f"v={v} k={k}"); n += 1
    for _ in range(200):
        v = random.randint(-M40, M40)
        x = v
        for _ in range(k):
            x = shift1(x)
        check("A3n", x == shift_k(v, k), f"v={v} k={k}"); n += 1
        y = v
        for _ in range(k):
            y = floor3(y)
        check("A3f", y == floor_k(v, k), f"v={v} k={k}"); n += 1
print(f"A3 iterated==barrel (nearest+floor): {n} cases")

# =========================== A4b: canon P HW == floor(log3) =================
n = 0
for v in edge_values():
    if v == 0:
        continue
    check("A4b", canon_P_hw(v) == canon_P_ref(v), f"v={v}: {canon_P_hw(v)} vs {canon_P_ref(v)}")
    n += 1
for _ in range(50000):
    v = random.randint(1, M40)
    check("A4b", canon_P_hw(v) == canon_P_ref(v), f"v={v}"); n += 1
print(f"A4b canonP(hw-rule)==floor(log3): {n} cases")

# =========================== A4: NORM serial == barrel ======================
n = 0
s_set = set()
for p in range(0, 42):
    for base in (3 ** p, (3 ** (p + 1) - 1) // 2, 3 ** p + 1, max(3 ** p - 1, 0),
                 3 ** p - 3 ** p // 2 if p > 0 else 1):
        for sg in (1, -1):
            v = sg * base
            if abs(v) <= M40:
                s_set.add(v)
s_set |= {0, 1, -1, 2, -2, 3 ** 19 - 1, -(3 ** 19 - 1), 3 ** 18 - 1, -(3 ** 18 - 1)}
e_list = [-100, -41, -40, -39, -1, 0, 1, 17, 18, 19, 39, 40, 41, 45, 62, 80, 100]
for s in sorted(s_set):
    for es in e_list:
        check("A4", norm_serial(s, es) == norm_barrel(s, es), f"s={s} e={es}")
        n += 1
for _ in range(50000):
    P = random.randint(0, 41)
    base = random.choice([3 ** P, (3 ** (P + 1) - 1) // 2, 3 ** P + random.randint(0, 3)])
    s = base * random.choice([-1, 1])
    s = max(-M40, min(M40, s))
    es = random.randint(-100, 100)
    check("A4", norm_serial(s, es) == norm_barrel(s, es), f"s={s} e={es}")
    n += 1
print(f"A4 NORM serial==barrel: {n} cases")

# =========================== A5: full pipeline, de <= 63 ====================
n = 0
def one_full(a, ae, b, be):
    global n
    r1 = add_serial(a, ae, b, be)
    r2 = add_barrel(a, ae, b, be)
    check("A5", r1 == r2, f"de={abs(ae-be)} a={a} ae={ae} b={b} be={be}: {r1:x} vs {r2:x}")
    n += 1

for _ in range(60000):
    a, b = rnd_prod(), rnd_prod()
    ae = random.randint(-98, 62)
    be = ae + random.choice([-1, 1]) * random.randint(0, 63)
    be = max(-98, min(62, be))
    one_full(a, ae, b, be)
for _ in range(30000):
    a, b = rnd_tf48(), rnd_tf48()
    ae = random.randint(-40, 40)
    be = ae + random.choice([-1, 1]) * random.randint(0, 63)
    be = max(-40, min(40, be))
    one_full(a, ae, b, be)
for _ in range(20000):
    a = random.choice([rnd_prod, rnd_tf48, rnd_any])()
    b = -a + random.choice([-1, 0, 1, 3, -3])
    ae = random.randint(-40, 40); be = ae
    one_full(a, ae, b, be)
for v in edge_values()[:60]:
    for de in (0, 1, 21, 22, 23, 63):
        be = 30
        ae = be + de
        if -98 <= ae <= 62:
            one_full(v, ae, v // 3, be)
print(f"A5 full serial==barrel (de<=63): {n} cases")

# =========================== A6: весь диапазон de ===========================
n = m = 0
for _ in range(30000):
    a, b = rnd_prod(), rnd_prod()
    ae = random.randint(-20, 62)
    be = ae - random.randint(0, 160)
    be = max(-98, be)
    ri = add_intent(a, ae, b, be)
    rb = add_barrel(a, ae, b, be)
    check("A6", ri == rb, f"de={ae-be} intent={ri:x} barrel={rb:x}"); n += 1
    if add_serial(a, ae, b, be) != rb:
        m += 1
print(f"A6 barrel==intent (de 0..160): {n} cases; serial(BUG-040) differs in {m}")

print("=" * 60)
if fails == 0:
    print("ALL PROOFS PASSED")
else:
    print(f"PROOFS FAILED: {fails}")
