# -*- coding: utf-8 -*-
"""Блочный прототип mul/add мантисс (5 байт = 20 тритов) для TFloat48.

Проверка блочного алгоритма против эталона arith48 (целые мантиссы).
Представление: мантисса как list из 40 тритов (младший первым), упакованная
в байты по 4 трита (tbyte_ops).
"""
import sys, struct, random
sys.path.insert(0, r'C:\A7_M2\EXAMPLES\XDMA_DDR3\rtl\block')
sys.path.insert(0, r'C:\A7_M2\EXAMPLES\XDMA_DDR3\ternary_sw')
import model_tbyte as TB
from block.tfloat48 import TFloat, M_TRITS, E_TRITS, M_NORM_MIN, M_NORM_MAX
from block import arith48
from block.trits import unpack, pack

M3 = M_NORM_MIN          # 3^18
M3_MAX = M_NORM_MAX      # 3^19


def trits_to_int(t):   # list тритов (младший первым) -> int
    v = 0
    for i, tv in enumerate(t):
        v += tv * (3 ** i)
    return v


def int_to_trits(n, width):   # int -> list тритов (младший первым), balanced
    out = [0] * width
    v = n
    for i in range(width):
        r = v % 3
        v //= 3
        if r == 2:
            r = -1
            v += 1
        out[i] = r
    return out


def trits_shift_down(t):
    """Сдвиг тритов вниз на 1: X_hi = floor-сдвиг без коррекции."""
    return t[1:] + [0]


def floor_div3_trits(t):
    """floor(x/3) для тритового x: сдвиг вниз + (-1 если младший трит == -1)."""
    hi = trits_shift_down(t)
    if t[0] == -1:
        hi = add_int_to_trits(hi, -1)
    return hi


def add_int_to_trits(t, val):
    """Добавить маленькое целое (val in {-1,0,1}) к тритовому числу (с переносом)."""
    out = list(t)
    i = 0
    while val != 0 and i < len(out):
        s = out[i] + val
        if s > 1:
            out[i] = s - 3
            val = 1
        elif s < -1:
            out[i] = s + 3
            val = -1
        else:
            out[i] = s
            val = 0
        i += 1
    return out


def mul3_trits(t):
    """x*3 = сдвиг тритов вверх (младший трит = 0)."""
    return [0] + t


def norm_mantissa(prod_t, e, width=M_TRITS):
    """Нормализация: value = M * 3^(e-18), M in [3^18, 3^19).
    Блочно: floor_div3 пока |M|>=3^19, *3 пока |M|<3^18."""
    av = list(prod_t)
    # усечь до разумной ширины (40 тритов произведение)
    while len(av) > 0 and av[-1] == 0:
        av.pop()
    while len(av) == 0:
        av = [0]
    # пока |av| >= 3^19
    for _ in range(40):
        val = trits_to_int(av)
        if val >= M3_MAX or val <= -M3_MAX:
            av = floor_div3_trits(av)
            e += 1
        else:
            break
    # пока 0 < |av| < 3^18 (и e > -40)
    for _ in range(40):
        val = trits_to_int(av)
        if abs(val) < M3 and val != 0 and e > -40:
            av = mul3_trits(av)
            e -= 1
        else:
            break
    return av, e


def mul_mantissa_blocks(ma_t, mb_t):
    """Ma*Mb (блочно: 5x5 tbyte_mul + сложение со сдвигом по 4 трита)."""
    # ma_t, mb_t: 20 тритов (младший первым). Байты: по 4 трита.
    n = 20
    prod = [0] * 40
    for ia in range(5):
        for ib in range(5):
            ba = pack_t(list(ma_t[4*ia:4*ia+4]))
            bb = pack_t(list(mb_t[4*ib:4*ib+4]))
            p = TB.mul_bytes(ba, bb)   # 8 тритов (16 бит)
            pt = [TB.code_to_trit((p >> (2*j)) & 3) for j in range(8)]
            shift = 4 * (ia + ib)
            # сложить pt (8 тритов) со сдвигом shift в prod (40 тритов)
            acc = list(prod)
            # поразрядное сложение acc[shift+0..7] += pt
            carry = 0
            for j in range(8):
                idx = shift + j
                if idx >= 40:
                    break
                s = acc[idx] + pt[j] + carry
                if s > 1:
                    carry = 1
                    acc[idx] = s - 3
                elif s < -1:
                    carry = -1
                    acc[idx] = s + 3
                else:
                    carry = 0
                    acc[idx] = s
            # перенос дальше
            idx = shift + 8
            while carry != 0 and idx < 40:
                s = acc[idx] + carry
                if s > 1:
                    acc[idx] = s - 3
                    carry = 1
                elif s < -1:
                    acc[idx] = s + 3
                    carry = -1
                else:
                    acc[idx] = s
                    carry = 0
                idx += 1
            prod = acc
    return prod


def pack_t(t):   # 4 трита (младший первым) -> байт
    v = 0
    for i, tv in enumerate(t):
        v |= TB.trit_to_code(tv) << (2 * i)
    return v


def add_mantissa_blocks(ma_t, mb_t, shift):
    """ma + floor-round(mb / 3^shift)  (выравнивание add). 24 трита результата."""
    # сдвиг mb вниз на shift (round-half-up как _shift_right_int)
    if shift <= 0:
        mb_s = list(mb_t)
    else:
        # round-half-up деление на 3^shift
        m = trits_to_int(mb_t)
        q = abs(m) // (3 ** shift)
        r = abs(m) % (3 ** shift)
        if r * 2 >= 3 ** shift:
            q += 1
        q = q if m >= 0 else -q
        mb_s = int_to_trits(q, 28)
    # сложение поразрядно (24 трита)
    n = 24
    res = [0] * n
    carry = 0
    for i in range(n):
        a = ma_t[i] if i < len(ma_t) else 0
        b = mb_s[i] if i < len(mb_s) else 0
        s = a + b + carry
        if s > 1:
            carry = 1
            res[i] = s - 3
        elif s < -1:
            carry = -1
            res[i] = s + 3
        else:
            carry = 0
            res[i] = s
    return res


def f32(x): return struct.unpack('f', struct.pack('f', x))[0]


def check_mul(n=2000):
    random.seed(21)
    bad = 0
    for _ in range(n):
        a = f32(random.uniform(-10, 10))
        b = f32(random.uniform(-10, 10))
        if a == 0 or b == 0:
            continue
        ta, tb = TFloat.from_float(a), TFloat.from_float(b)
        ref = arith48.mul(ta, tb)
        # блочно
        ma_t = list(reversed(unpack(ta.m_int, M_TRITS)))
        mb_t = list(reversed(unpack(tb.m_int, M_TRITS)))
        prod = mul_mantissa_blocks(ma_t, mb_t)
        e = arith48._e_raw(ta) + arith48._e_raw(tb) - (M_TRITS - 2)
        mnorm, e2 = norm_mantissa(prod, e)
        # знак
        sign = 1
        mn = [x for x in mnorm]
        mval = trits_to_int(mn)
        if mval < 0:
            mval = -mval
        # сравнить с ref
        ref_m = arith48._trits_value(unpack(ref.m_int, M_TRITS))
        ref_e = arith48._e_raw(ref)
        if abs(mval - abs(ref_m)) > 1 or e2 != ref_e:
            bad += 1
            if bad <= 8:
                print(f"MUL {a} {b}: got m={mval} e={e2} ref m={abs(ref_m)} e={ref_e}")
    print("mul block bad:", bad, "/", n)


def check_add(n=2000):
    random.seed(22)
    bad = 0
    for _ in range(n):
        a = f32(random.uniform(-10, 10))
        b = f32(random.uniform(-10, 10))
        if a == 0 or b == 0:
            continue
        ta, tb = TFloat.from_float(a), TFloat.from_float(b)
        ref = arith48.add(ta, tb)
        ea, eb = arith48._e_raw(ta), arith48._e_raw(tb)
        ma_t = list(reversed(unpack(ta.m_int, M_TRITS)))
        mb_t = list(reversed(unpack(tb.m_int, M_TRITS)))
        if ea > eb:
            e = ea
            msum = add_mantissa_blocks(ma_t, mb_t, ea - eb)
        elif eb > ea:
            e = eb
            msum = add_mantissa_blocks(mb_t, ma_t, eb - ea)
        else:
            e = ea
            msum = add_mantissa_blocks(ma_t, mb_t, 0)
        mnorm, e2 = norm_mantissa(msum, e)
        mval = abs(trits_to_int(mnorm))
        ref_m = abs(arith48._trits_value(unpack(ref.m_int, M_TRITS)))
        ref_e = arith48._e_raw(ref)
        if abs(mval - ref_m) > 1 or e2 != ref_e:
            bad += 1
            if bad <= 8:
                print(f"ADD {a} {b}: got m={mval} e={e2} ref m={ref_m} e={ref_e}")
    print("add block bad:", bad, "/", n)


if __name__ == "__main__":
    # floor_div3 проверка
    bad = 0
    for x in range(-1000, 1001):
        t = int_to_trits(x, 20)
        fd = floor_div3_trits(t)
        if trits_to_int(fd) != x // 3:
            bad += 1
            if bad < 5:
                print("FD3", x, trits_to_int(fd), x // 3)
    print("floor_div3 bad:", bad)
    check_mul()
    check_add()
