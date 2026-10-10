"""P1b feasibility: base-3 carry-save (CSA) adder tree + DSP48 mapping assessment.

Ключевая идея Пети: дерево сложений в DSP48, redundant base-3, 4-тритовые
группы = base-81, 3:2 компрессоры, нормализация один раз в конце.

Модель показывает:
- base-3 3:2 CSA: sum(3 trits) in [-3..3] -> digit(sum mod 3, balanced) +
  carry(floor(sum/3)) in {-1,0,1}. Это таблица на 1 трит-колонку = LUT, НЕ
  DSP48-datapath (DSP48 бинарный).
- base-81 группа = 7-бит signed binary; DSP48 сложит две группы как binary,
  но base-81 carry = sum//81 не нативен (нужно деление) -> не маппится в DSP
  без дополнительного LUT-дешифтора.
Вывод: base-3 CSA естественно LUT; DSP48 даёт modest win, high risk.
"""
import sys

def trit_add3(a, b, c):
    s = a + b + c          # -3..3
    # balanced digit d in {-1,0,1}, carry q = round-to-floor(s/3)
    # s = 3*q + d, d in {-1,0,1}
    q = (s + 1) // 3       # floor division to balanced
    d = s - 3 * q
    return d, q

def csa_column(a, b, c):
    # 3:2 in one trit column; carry goes to next higher column
    d, q = trit_add3(a, b, c)
    return d, q

def tree_csa(num_leaves):
    # count 3:2 compressors per level (base-3 CSA reduces 3->2)
    # level reduces count by factor ~1.5; standard CSA tree:
    levels = 0
    n = num_leaves
    total_comp = 0
    while n > 2:
        # each 3:2 reduces 3 operands to 2; group in triples
        comp = n // 3
        n = n - 2 * comp + (n % 3)
        total_comp += comp
        levels += 1
    return levels, total_comp

def base81_group(mantissa_trits):
    # 40 trits -> 10 groups of 4 trits = base-81
    groups = []
    g = 0
    for t in mantissa_trits:
        g = g * 3 + t
    # split into 4-trit base-81 groups
    v = 0
    for t in mantissa_trits:
        v = v * 3 + t  # full base-3 value
    # base-81 digits
    out = []
    x = v
    for _ in range(10):
        r = x % 81
        x //= 81
        # balanced base-81 digit in [-40..40]
        if r > 40: r -= 81; x += 1
        out.append(r)
    return out

def dsp48_group_add(ga, gb):
    # DSP48 binary adder adds two base-81 group binaries
    s = ga + gb            # binary sum, range -80..80
    # base-81 carry extraction needs s // 81 (non-native in DSP datapath)
    carry = s // 81
    digit = s - 81 * carry
    return digit, carry

if __name__ == "__main__":
    for nm in (16, 32):
        levels, comp = tree_csa(nm)
        print(f"NUM_MAC={nm}: CSA levels={levels}, 3:2 compressors/column={comp} "
              f"(x {20} trit-columns = {comp*20} LUT-таблиц)")
    # 3-trit add table size
    print("trit_add3: 27 (a,b,c) combos -> LUT; base-3 carry in {-1,0,1}")
    # base-81 group add: binary sum fits 7 bits, carry via //81 (division)
    print("DSP48 base-81 add: binary sum OK, carry extraction s//81 = non-native (LUT)")
