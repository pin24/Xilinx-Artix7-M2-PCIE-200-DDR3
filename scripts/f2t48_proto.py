#!/usr/bin/env python3
"""f2t48_proto.py — RESEARCH-модель встроенной конверсии fp32<->tf48 для tdot_axi4.

Показывает, что конверсию TFloat48 (TFloat.from_float / to_float) можно
воспроизвести ЦЕЛОЧИСЛЕННОЙ фиксированной точкой (стиль f32_to_tf40_pipe2)
БИТ-В-БИТ относительно host-эталона. Использовано в дизайн-доке
docs/DESIGN_F2T_PACKED6_2026-10-17.md.

Проверки (все дают mismatch=0):
  1. f2t_double  — буквальная реплика from_float (double-арифметика).
  2. f2t_int     — точная целочисленная реплика (round-half-up true rational).
  3. f2t_fixed   — РТЛ-стиль: фикс.точка Q=64, D-таблица 3^e3*2^Q (LUT 81 запись),
                   M = round-half-up(value_q*3^18 / D). Это целевой RTL-алгоритм.
  4. t2f_int     — точный RNE (round-to-nearest-even) M*3^(e-18) -> float32.

Запуск:  python scripts/f2t48_proto.py
Без RTL/синтеза.
"""
import sys, os, struct, random, math
from fractions import Fraction

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "ternary_sw"))
from block.tfloat48 import TFloat, M_TRITS, E_TRITS, E_BIAS, E_MAX, \
    M_NORM_MIN, M_NORM_MAX, _encode_exp
from block import trits as T

Q = 64                       # дробных бит фикс.точки (как f32_to_tf40_pipe2)
P3_18 = 387420489            # 3^18 (граница норм. мантиссы TF48)


def f32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


def _int_to_trits(m, n):
    """Копия tfloat48._int_to_trits (старший первым, balanced)."""
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


# =====================================================================
# Эталоны (Python) — TFloat.from_float / to_float
# =====================================================================
def ref_from_bits(fv):
    t = TFloat.from_float(fv)
    return ((t.e_int & 0xFF) << 40) | (t.m_int & ((1 << 40) - 1))


def ref_to_float_word(w):
    t = TFloat.from_bits(((w & ((1 << 40) - 1)) << 8) | ((w >> 40) & 0xFF))
    return t.to_float()


# =====================================================================
# 1) Буквальная реплика from_float (double) — подтверждает, что double-путь
#    это и есть host-эталон.
# =====================================================================
def f2t_double(fv):
    bits = struct.unpack("I", struct.pack("f", f32(fv)))[0]
    sign = (bits >> 31) & 1
    e2 = (bits >> 23) & 0xFF
    mant = bits & 0x7FFFFF
    if e2 == 0xFF:
        return ("oflo", None)                 # inf/nan
    if e2 == 0 and mant == 0:
        return (0, 0)                         # ±0
    neg = bool(sign)
    av = abs(f32(fv))
    e = int(math.floor(math.log2(av) / math.log2(3.0)))
    if 3.0 ** (e + 1) <= av:
        e += 1
    elif 3.0 ** e > av:
        e -= 1
    M = int(av * (3.0 ** (M_TRITS - 2)) / (3.0 ** e) + 0.5)
    while M >= M_NORM_MAX:
        M //= 3; e += 1
    while M < M_NORM_MIN and e > -E_BIAS:
        M *= 3; e -= 1
    if e < -E_BIAS:
        return ("uflow", e)
    if e > E_MAX:
        return ("oflo", e)
    mt = [int(t) for t in _int_to_trits(M, M_TRITS)]
    if neg:
        mt = [-t for t in mt]
    return (((T.pack(tuple(_encode_exp(e))) & 0xFF) << 40)
            | (T.pack(tuple(mt)) & ((1 << 40) - 1))), e


# =====================================================================
# 2) Точная целочисленная реплика from_float (true rational, round-half-up)
# =====================================================================
def f2t_int(fv):
    bits = struct.unpack("I", struct.pack("f", f32(fv)))[0]
    sign = (bits >> 31) & 1
    e2 = (bits >> 23) & 0xFF
    mant = bits & 0x7FFFFF
    if e2 == 0xFF:
        return ("oflo", None)
    if e2 == 0 and mant == 0:
        return (0, 0)
    if e2 == 0:
        return ("uflow", -41)                 # любой субнормал уходит в 0
    m24 = (1 << 23) | mant
    pow2 = e2 - 150
    val = (Fraction(m24 << pow2, 1) if pow2 >= 0
           else Fraction(m24, 1 << (-pow2)))  # точное value
    e3 = 0
    p = Fraction(1)
    while e3 < 100 and p * 3 <= val:
        p *= 3; e3 += 1
    while e3 > -100 and p > val:
        p = p / 3; e3 -= 1
    q = val * P3_18 / p                        # value*3^18/3^e3 (в [3^18,3^19))
    rh = q + Fraction(1, 2)
    M = rh.numerator // rh.denominator         # round-half-up
    e = e3
    while M >= M_NORM_MAX:
        M //= 3; e += 1
    while M < M_NORM_MIN and e > -E_BIAS:
        M *= 3; e -= 1
    if e < -E_BIAS:
        return ("uflow", e)
    if e > E_MAX:
        return ("oflo", e)
    mt = [int(t) for t in _int_to_trits(M, M_TRITS)]
    if sign:
        mt = [-t for t in mt]
    return (((T.pack(tuple(_encode_exp(e))) & 0xFF) << 40)
            | (T.pack(tuple(mt)) & ((1 << 40) - 1))), e


# =====================================================================
# 3) РТЛ-стиль: фикс.точка Q=64, D-таблица (LUT), round-half-up.
#    Это и есть целевой алгоритм для f32_to_tf48.sv.
# =====================================================================
dtab = {}
for _k in range(-40, 41):
    if _k >= 0:
        dtab[_k] = (3 ** _k) << Q
    else:
        dtab[_k] = Fraction(1 << Q, 3 ** (-_k))   # 3^_k*2^Q точно


def f2t_fixed(fv):
    bits = struct.unpack("I", struct.pack("f", f32(fv)))[0]
    sign = (bits >> 31) & 1
    e2 = (bits >> 23) & 0xFF
    mant = bits & 0x7FFFFF
    if e2 == 0xFF:
        return (0, 0)                         # inf/nan: host кодирует как 0
    if e2 == 0 and mant == 0:
        return (0, 0)                         # ±0
    if e2 == 0:
        return ("uflow", -41)                 # субнормал -> 0
    m24 = (1 << 23) | mant
    pow2 = e2 - 150
    # value_q = value*2^Q ТОЧНО (без усечения!) — ключ бит-в-бит.
    value_q = (Fraction(m24 << (pow2 + Q), 1) if pow2 + Q >= 0
               else Fraction(m24, 1 << (-(pow2 + Q))))
    # e3 = floor(log3(value)): ищем D[k]=3^k*2^Q <= value_q < D[k+1]
    e3 = 0
    found = False
    for k in range(-40, 40):
        if dtab[k] <= value_q < dtab[k + 1]:
            e3 = k
            found = True
            break
    if not found:
        if value_q < dtab[-40]:
            return ("uflow", -41)
        else:
            e3 = 40
    q = value_q * P3_18 / dtab[e3]
    rh = q + Fraction(1, 2)
    M = rh.numerator // rh.denominator         # round-half-up
    e = e3
    while M >= M_NORM_MAX:
        M //= 3; e += 1
    while M < M_NORM_MIN and e > -E_BIAS:
        M *= 3; e -= 1
    if e < -E_BIAS:
        return ("uflow", e)
    if e > E_MAX:
        return ("oflo", e)
    mt = [int(t) for t in _int_to_trits(M, M_TRITS)]
    if sign:
        mt = [-t for t in mt]
    return (((T.pack(tuple(_encode_exp(e))) & 0xFF) << 40)
            | (T.pack(tuple(mt)) & ((1 << 40) - 1))), e


# =====================================================================
# 4) РТЛ T2F: точный RNE (round-to-nearest-even) M*3^(e-18) -> float32.
# =====================================================================
def t2f_int(w):
    m_bits = (w & ((1 << 40) - 1))
    e_bits = (w >> 40) & 0xFF
    for i in range(20):
        if ((m_bits >> (2 * i)) & 0x3) == 0x3:
            return 0x7FC00000                 # ERR в мантиссе -> NaN
    for i in range(4):
        if ((e_bits >> (2 * i)) & 0x3) == 0x3:
            return 0x7FC00000                 # ERR в экспоненте -> NaN
    mt = T.unpack(m_bits, 20)
    et = T.unpack(e_bits, 4)
    m = 0
    for t in mt:
        m = m * 3 + int(t)
    e = 0
    for t in et:
        e = e * 3 + int(t)
    if m == 0:
        return 0                              # ±0 (файл без знака)
    sign = 1 if m < 0 else 0
    vals = (Fraction(abs(m) * (3 ** (e - 18)), 1) if e >= 18
            else Fraction(abs(m), 3 ** (18 - e)))     # точный |value|
    v = vals
    e2 = 0
    while v >= 2 or v < 1:                     # нормализация к [1,2)
        while v >= 2:
            v /= 2; e2 += 1
        while v < 1:
            v *= 2; e2 -= 1
    m24f = v * (1 << 23)                       # в [2^23, 2^24)
    flo = m24f.numerator // m24f.denominator
    frac = m24f - flo
    if frac > Fraction(1, 2):
        m24 = flo + 1
    elif frac < Fraction(1, 2):
        m24 = flo
    else:
        m24 = flo if (flo % 2 == 0) else flo + 1   # ties-to-even
    if m24 >= (1 << 24):
        m24 >>= 1
        e2 += 1
    e_b = e2 + 127
    if e_b >= 255:
        return (0xFF << 23) | (sign << 31)     # inf
    if e_b <= 0:
        return 0                               # underflow -> 0
    return (sign << 31) | (e_b << 23) | (m24 & 0x7FFFFF)


# =====================================================================
def main():
    random.seed(12345)
    n = 20000
    vals = []
    for _ in range(n):
        e = random.uniform(-120, 120)
        m = random.uniform(0.1, 10.0)
        vals.append(f32(math.copysign(m * (2.0 ** e), random.choice([-1, 1]))))

    def run(name, conv, use_ref_exc=False):
        bad = oflo = uflo = 0
        for v in vals:
            try:
                bref = ref_from_bits(f32(v))
            except Exception:
                bref = "oflo"
            a, _ = conv(f32(v))
            if isinstance(a, str):
                if a == "uflow":
                    uflo += 1
                else:
                    oflo += 1
                continue
            if a != bref:
                bad += 1
                if bad <= 5:
                    print(f"  {name} MISMATCH {f32(v)} ours={a:012x} ref={bref}")
        print(f"{name}: {n}, mismatch={bad}, oflo={oflo}, uflo={uflo}")

    run("F2T double            vs from_float", f2t_double)
    run("F2T exact-int         vs from_float", f2t_int)
    run("F2T fixed(Q=64,LUT)   vs from_float", f2t_fixed)

    t2f_bad = n_t2f = 0
    for v in vals[:8000]:
        a, _ = f2t_fixed(f32(v))
        if isinstance(a, str):
            continue
        n_t2f += 1
        ref_bits = struct.unpack("I", struct.pack("f", ref_to_float_word(a)))[0]
        got_bits = t2f_int(a)
        if got_bits != ref_bits:
            t2f_bad += 1
            if t2f_bad <= 5:
                print(f"  T2F MISMATCH word={a:012x} ref={ref_bits:08x} got={got_bits:08x}")
    print(f"T2F exact-int RNE vs to_float: {n_t2f}, mismatch={t2f_bad}")

    # ---- граничные случаи (детерминированные) ----
    edge = [0.0, -0.0, float("inf"), float("-inf"), float("nan"),
            1.17549435e-38,        # min normal
            -1.17549435e-38,
            3.4028235e38,          # max normal
            -3.4028235e38,
            1.0, -1.0, 0.5, 2.0, 3.0, 9.0, 27.0, 81.0, 243.0,
            1e-20, 1e-19, 1e19, 1.1e19, 3.0e19, 3.6e19, 4e19,
            1e-24, 1e-30, 8e-21, 8e-20, 9e-20,
            3.0**-39, 3.0**-40, 3.0**-41, 3.0**40, 3.0**41, 3.0**42]
    E = {float("inf"), float("-inf")}
    e_bad = 0
    for v in edge:
        vf = f32(v)
        # host-ожидание через _to_bits48(from_float(.)): inf/nan -> 0,
        # overflow -> бросает TFloatError.
        try:
            bref = ref_from_bits(vf)
        except Exception:
            bref = "oflo"
        if vf != vf or vf in E:
            bref = 0                        # inf/nan: host кодирует как 0
        a, _ = f2t_fixed(vf)
        a0 = a                          # уже слово ('uflow'/'oflo' - строки)
        if a0 == "uflow" or a0 == 0:
            a0 = 0
        if bref in (None, "oflo"):
            bref = "oflo"
        if a0 == 0 and bref == 0:
            continue
        if a0 != bref:
            e_bad += 1
            print(f"  EDGE MISMATCH {vf} f2t_fixed={a0} ref={bref}")
    print(f"EDGE (boundary/zero/inf/nan/subnormal): mismatch={e_bad}")


if __name__ == "__main__":
    main()