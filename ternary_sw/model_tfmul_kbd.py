#!/usr/bin/env python3
# model_tfmul_kbd.py — ПОСТРОЧНАЯ Python-модель исправленного tfmul_kbd.sv (ВЕРСИЯ 2, BUG-039).
# Зеркалит RTL: mul_10x10 (столбцовая редукция, carry 4 бита), s-коррекция среднего
# члена, слияние 21 колонку, финальная сборка 41 колонка (перенос за 40-м игнорируется),
# prod = 40 тритов. Проверка против прямого целочисленного умножения.
from __future__ import annotations
import random
import sys

HALF = 10
PP_WIDTH = 21          # 2*HALF + 1
SUM_WIDTH = 41         # 2*20 + 1
P10 = 3 ** 10

# ---------- триты: {-1,0,+1}; упаковка: +1=01, -1=10, 0=00 ----------

def tval(c: int) -> int:
    return 1 if c == 0b01 else (-1 if c == 0b10 else 0)


def tcode(v: int) -> int:
    return {1: 0b01, -1: 0b10, 0: 0b00}[v]


def pack(trits) -> int:
    b = 0
    for i, t in enumerate(trits):
        b |= tcode(t) << (2 * i)
    return b


def unpack(bits: int, n: int):
    return [tval((bits >> (2 * i)) & 0b11) for i in range(n)]


def tv_int(trits) -> int:
    v = 0
    for t in reversed(trits):
        v = v * 3 + t
    return v


def exp_val(x4: int) -> int:  # x4 — 4 трита в упаковке
    v = 0
    for i in range(3, -1, -1):
        v = v * 3 + tval((x4 >> (2 * i)) & 0b11)
    return v


def bdiv3(s: int):
    """сбалансированное деление на 3: q = s/3, r = s-3q, r в {-1,0,1} (как в SV: / с усечением + поправка)"""
    q = abs(s) // 3
    q = q if s >= 0 else -q          # SV '/' усекает к нулю
    r = s - 3 * q
    if r > 1:
        q, r = q + 1, r - 3
    elif r < -1:
        q, r = q - 1, r + 3
    return q, r


# ---------- mul_10x10: построчно как в SV (с carry_val 4 бита — BUG-039 фикс) ----------

def mul_10x10(x: int, y: int) -> int:
    x_trit = unpack(x, HALF)
    y_trit = unpack(y, HALF)
    pp = []
    for i in range(HALF):
        row = [0] * PP_WIDTH
        for j in range(HALF):
            if i + j < PP_WIDTH:
                if x_trit[i] == 1:
                    row[i + j] = y_trit[j]
                elif x_trit[i] == -1:
                    row[i + j] = {1: -1, -1: 1, 0: 0}[y_trit[j]]
        pp.append(row)
    sum_col = [0] * PP_WIDTH
    carry_val = 0                       # logic signed [3:0]
    for j in range(PP_WIDTH):
        col_sum = carry_val
        for i in range(HALF):
            col_sum += pp[i][j]
        q, r = bdiv3(col_sum)
        sum_col[j] = r                  # в модели храним ТРИТ (pack сам закодирует; в SV — tcode в шину)
        carry_val = q                   # q[3:0] — q в [-5..5], помещается в 4 бита
    result_w = sum_col + [carry_val]    # триты 0..20 + трит 21
    return pack(result_w)


# ---------- средний член: mul_10x10 + s-коррекция (BUG-039) ----------

def balanced_add_cols(vecs, n_cols):
    """колонковое сбалансированное сложение упакованных векторов -> n_cols тритов (упаковка).
    Чтение трита за пределами вектора даёт 0 (как расширение нулями в SV-модели)."""
    out = [0] * n_cols
    carry = 0
    for i in range(n_cols):
        s = carry
        for v in vecs:
            s += tval((v >> (2 * i)) & 0b11)
        q, r = bdiv3(s)
        out[i] = r                      # трит (pack сам закодирует)
        carry = q
    assert carry == 0, f"перенос за пределы {n_cols} тритов: {carry}"
    return pack(out)


def middle_term(a_sum11: int, b_sum11: int) -> int:
    """a_sum11/b_sum11 — полные суммы (11 тритов, упаковка). Возвращает 21 трит (упаковка)."""
    s_a = tval((a_sum11 >> (2 * HALF)) & 0b11)
    s_b = tval((b_sum11 >> (2 * HALF)) & 0b11)
    a_mod = a_sum11 & ((1 << (2 * HALF)) - 1)
    b_mod = b_sum11 & ((1 << (2 * HALF)) - 1)

    mul_sum = mul_10x10(a_mod, b_mod)   # a_mod*b_mod, триты 0..20 (+ трит 21 = 0)

    # corr1 = s_a*b_mod + s_b*a_mod — 11 тритов (знаковые мультиплексоры + колонковое сложение)
    corr1 = balanced_add_cols([s_a * 0 + b_mod if s_a == 1 else (neg_pack(b_mod) if s_a == -1 else 0),
                               a_mod if s_b == 1 else (neg_pack(a_mod) if s_b == -1 else 0)], HALF + 1)

    # слияние: mul_sum_mid = mul_sum + corr1*3^HALF + (s_a*s_b)*3^(2*HALF), 21 колонка — как в SV
    sb2 = s_a * s_b
    mul_sum_mid = [0] * PP_WIDTH
    c2 = 0
    for t in range(PP_WIDTH):
        tot2 = c2 + tval((mul_sum >> (2 * t)) & 0b11)
        if t >= HALF:
            tot2 += tval((corr1 >> (2 * (t - HALF))) & 0b11)
        if t == 2 * HALF:
            tot2 += sb2
        q2, r2 = bdiv3(tot2)
        mul_sum_mid[t] = r2             # трит (pack сам закодирует)
        c2 = q2
    assert c2 == 0, f"перенос слияния за 21 трит: {c2}"
    return pack(mul_sum_mid)


def neg_pack(v: int) -> int:
    """инверсия всех тритов упакованного вектора (22 трита с запасом)"""
    return pack([-tval((v >> (2 * i)) & 0b11) for i in range(22)])


# ---------- полный tfmul_kbd (комбинационная часть + выходной регистр) ----------

def tfmul_kbd(a: int, b: int):
    """a/b — 48 бит {E(8), M(40)}. Возврат (prod40_упаковка, e, neg) — как выходы RTL."""
    a_mant = a & ((1 << 40) - 1)
    b_mant = b & ((1 << 40) - 1)
    a_exp = (a >> 40) & 0xFF
    b_exp = (b >> 40) & 0xFF

    # a_sum_local: колонковое сложение a_lo + a_hi -> 11 тритов (как в SV)
    def sum_halves(mant: int) -> int:
        lo = [tval((mant >> (2 * i)) & 0b11) for i in range(HALF)]
        hi = [tval((mant >> (2 * (i + HALF))) & 0b11) for i in range(HALF)]
        out = []
        carry = 0
        for i in range(HALF):
            total = lo[i] + hi[i] + carry
            q, r = bdiv3(total)
            out.append(r)
            carry = q
        out.append(carry)
        return pack(out)

    a_sum11 = sum_halves(a_mant)
    b_sum11 = sum_halves(b_mant)

    mul_lo_lo = mul_10x10(a_mant & ((1 << 20) - 1), b_mant & ((1 << 20) - 1))
    mul_hi_hi = mul_10x10((a_mant >> 20) & ((1 << 20) - 1), (b_mant >> 20) & ((1 << 20) - 1))
    mul_sum_mid = middle_term(a_sum11, b_sum11)

    # финальная сборка: 41 колонка, перенос за колонкой 40 игнорируется (как в SV)
    final = [0] * SUM_WIDTH
    carry = 0
    for j in range(SUM_WIDTH):
        col = carry
        if j < PP_WIDTH:
            col += tval((mul_lo_lo >> (2 * j)) & 0b11)
        if j >= 2 * HALF and j - 2 * HALF < PP_WIDTH:
            col += tval((mul_hi_hi >> (2 * (j - 2 * HALF))) & 0b11)
        if j >= HALF and j - HALF < PP_WIDTH:
            col += tval((mul_sum_mid >> (2 * (j - HALF))) & 0b11)
        if j >= HALF and j - HALF < PP_WIDTH:
            col -= tval((mul_hi_hi >> (2 * (j - HALF))) & 0b11)
        if j >= HALF and j - HALF < PP_WIDTH:
            col -= tval((mul_lo_lo >> (2 * (j - HALF))) & 0b11)
        q, r = bdiv3(col)
        final[j] = r
        carry = q
    # carry после 41-й колонки игнорируется (SV); для валидных входов он обязан быть 0
    assert carry == 0, f"перенос за 41 трит: {carry} (a={a:x} b={b:x})"

    prod40 = pack(final[:40])
    trit40 = final[40]
    assert trit40 == 0, f"трит 40 != 0: {trit40}"

    neg = 0
    for t in range(SUM_WIDTH - 1, -1, -1):
        if final[t] != 0:
            neg = 1 if final[t] == -1 else 0
            break
    e = (exp_val(a_exp) + exp_val(b_exp) - 18) & 0xFF
    return prod40, e, neg


# ---------- старая (бажная) версия для контроля фиделити модели ----------

def tfmul_kbd_OLD(a: int, b: int):
    a_mant = a & ((1 << 40) - 1)
    b_mant = b & ((1 << 40) - 1)
    a_exp, b_exp = (a >> 40) & 0xFF, (b >> 40) & 0xFF

    def sum_halves(mant: int) -> int:
        lo = [tval((mant >> (2 * i)) & 0b11) for i in range(HALF)]
        hi = [tval((mant >> (2 * (i + HALF))) & 0b11) for i in range(HALF)]
        out, carry = [], 0
        for i in range(HALF):
            q, r = bdiv3(lo[i] + hi[i] + carry)
            out.append(r)
            carry = q
        out.append(carry)
        return pack(out)

    a_sum11, b_sum11 = sum_halves(a_mant), sum_halves(b_mant)
    mul_lo_lo = mul_10x10(a_mant & ((1 << 20) - 1), b_mant & ((1 << 20) - 1))
    mul_hi_hi = mul_10x10((a_mant >> 20) & ((1 << 20) - 1), (b_mant >> 20) & ((1 << 20) - 1))
    # OLD: усечение сумм до 10 тритов, БЕЗ коррекции
    mul_sum_mid = mul_10x10(a_sum11 & ((1 << 20) - 1), b_sum11 & ((1 << 20) - 1))

    final = [0] * SUM_WIDTH
    carry = 0
    for j in range(SUM_WIDTH):
        col = carry
        if j < PP_WIDTH:
            col += tval((mul_lo_lo >> (2 * j)) & 0b11)
        if j >= 2 * HALF and j - 2 * HALF < PP_WIDTH:
            col += tval((mul_hi_hi >> (2 * (j - 2 * HALF))) & 0b11)
        if j >= HALF and j - HALF < PP_WIDTH:
            col += tval((mul_sum_mid >> (2 * (j - HALF))) & 0b11)
        if j >= HALF and j - HALF < PP_WIDTH:
            col -= tval((mul_hi_hi >> (2 * (j - HALF))) & 0b11)
        if j >= HALF and j - HALF < PP_WIDTH:
            col -= tval((mul_lo_lo >> (2 * (j - HALF))) & 0b11)
        q, r = bdiv3(col)
        final[j] = r
        carry = q
    prod40 = pack(final[:40])
    neg = 0
    for t in range(SUM_WIDTH - 1, -1, -1):
        if final[t] != 0:
            neg = 1 if final[t] == -1 else 0
            break
    e = (exp_val((a >> 40) & 0xFF) + exp_val((b >> 40) & 0xFF) - 18) & 0xFF
    return prod40, e, neg


# ---------- тесты ----------

def mant_from_trits(trits20) -> int:
    return pack(trits20 + [0]) & ((1 << 40) - 1) if False else pack(trits20)


def check(a48: int, b48: int, tag: str, errors: list):
    prod, e, neg = tfmul_kbd(a48, b48)
    am = tv_int(unpack(a48 & ((1 << 40) - 1), 20))
    bm = tv_int(unpack(b48 & ((1 << 40) - 1), 20))
    exact = am * bm
    got = tv_int(unpack(prod, 40))
    if got != exact:
        errors.append(f"[{tag}] prod: a={am} b={bm} exact={exact} got={got} diff={got - exact}")
    e_exp = (exp_val((a48 >> 40) & 0xFF) + exp_val((b48 >> 40) & 0xFF) - 18) & 0xFF
    if e != e_exp:
        errors.append(f"[{tag}] e: got {e}, expected {e_exp}")
    if neg != (1 if exact < 0 else 0):
        errors.append(f"[{tag}] neg: got {neg}, exact={exact}")


def main():
    errors: list = []

    # --- направленные: все комбинации переносов s_a, s_b (крайние половины) ---
    max10 = [1] * 10          # +29524
    min10 = [-1] * 10         # -29524
    cases = []
    for ah in (max10, min10):
        for al in (max10, min10):
            for bh in (max10, min10):
                for bl in (max10, min10):
                    cases.append((ah + al, bh + bl))
    cases.append(([0] * 20, [0] * 20))                       # 0 * 0
    cases.append(([1] + [0] * 19, [1] + [0] * 19))           # 1 * 1
    cases.append(([1] + [0] * 19, [-1] + [0] * 19))          # 1 * (-1)
    cases.append(([1] * 20, [-1] * 20))                      # max * min
    cases.append(([-1] * 20, [-1] * 20))                     # min * min
    cases.append(([1, 0, -1] * 6 + [1, 0], [0, 1] * 10))     # произвольные
    cases.append(([1] * 10 + [-1] * 10, [-1] * 10 + [1] * 10))
    cases.append(([1, 0, -1, 1, 0, 0, -1, 1, 1, -1, 0, 0, 1, -1, 1, 0, -1, 1, 0, 1],
                  [0, -1, 1, 1, 1, 0, -1, 0, 0, 1, -1, -1, 1, 0, 0, 1, 1, -1, 0, -1]))

    for i, (am, bm) in enumerate(cases):
        for ea, eb in ((0, 0), (0b01, 0b10), (0b10101010, 0b01010101)):  # 4-тритные экспоненты
            a48 = mant_from_trits(am) | ((ea & 0xFF) << 40)
            b48 = mant_from_trits(bm) | ((eb & 0xFF) << 40)
            check(a48, b48, f"directed#{i}/e{ea},{eb}", errors)

    # --- random ---
    random.seed(20260906)
    N = 100000
    for _ in range(N):
        am = [random.choice((-1, 0, 1)) for _ in range(20)]
        bm = [random.choice((-1, 0, 1)) for _ in range(20)]
        ea = random.getrandbits(8)
        eb = random.getrandbits(8)
        check(mant_from_trits(am) | (ea << 40), mant_from_trits(bm) | (eb << 40), "random", errors)
        if len(errors) > 10:
            break

    # --- фиделити: OLD-версия обязана давать ошибки на тех же векторах ---
    random.seed(7)
    old_bad = 0
    for _ in range(20000):
        am = [random.choice((-1, 0, 1)) for _ in range(20)]
        bm = [random.choice((-1, 0, 1)) for _ in range(20)]
        a48, b48 = mant_from_trits(am), mant_from_trits(bm)
        prod, _, _ = tfmul_kbd_OLD(a48, b48)
        exact = tv_int(am) * tv_int(bm)
        if tv_int(unpack(prod, 40)) != exact:
            old_bad += 1
    print(f"модель-контроль: OLD (бажная) версия неверна на {100 * old_bad / 20000:.1f}% векторов (ожидаемо >40%)")

    print(f"NEW версия: направленные {len(cases) * 3} кейсов + random 100000, ошибок: {len(errors)}")
    for e in errors[:10]:
        print("  ", e)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
