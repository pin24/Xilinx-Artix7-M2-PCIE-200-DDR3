#!/usr/bin/env python3
"""
ternary_kbd_ref.py — Python-эталон для tfmul_kbd (Karatsuba + Booth + Dadda)

Сверяет троичное умножение 20×20 → 40 тритов:
  1. Прямое умножение (эталон)
  2. Karatsuba разбиение 20→10+10
  3. Сравнение результатов

Используется для:
  - верификации tfmul_kbd.sv (RTL)
  - понимания алгоритма
  - генерации тест-векторов для симуляции
"""
from __future__ import annotations
import random
import struct
from typing import Tuple, List

# ============================================================================
# Троичные операции (balanced ternary: -1, 0, +1)
# ============================================================================

# Кодирование тритов: +1->01, 0->00, -1->10 (2 бита на трит)
TRIT_CODES = {'+1': 0b01, '0': 0b00, '-1': 0b10}
CODE_TO_TRIT = {0b01: 1, 0b00: 0, 0b10: -1}


def int_to_trits(value: int, n_trits: int) -> List[int]:
    """Целое → список тритов (младший первым, balanced ternary)."""
    if value == 0:
        return [0] * n_trits
    trits = []
    v = value
    # Используем balanced: residues ∈ {-1, 0, +1}
    while v != 0:
        r = v % 3
        if r > 1:  # r == 2 → -1 с переносом +1
            r = -1
            v = (v - r) // 3
        else:
            v = (v - r) // 3
        trits.append(r)
    # Дополняем до n_trits
    while len(trits) < n_trits:
        trits.append(0)
    return trits[:n_trits]


def trits_to_int(trits: List[int]) -> int:
    """Список тритов (младший первым) → целое."""
    result = 0
    power = 1
    for t in trits:
        result += t * power
        power *= 3
    return result


def pack_trits(trits: List[int]) -> int:
    """Список тритов → упакованное 2-битное представление (младший первым)."""
    bits = 0
    for i, t in enumerate(trits):
        if t == 1:
            code = 0b01
        elif t == -1:
            code = 0b10
        else:
            code = 0b00
        bits |= code << (2 * i)
    return bits


def unpack_trits(bits: int, n_trits: int) -> List[int]:
    """Упакованное 2-битное представление → список тритов."""
    trits = []
    for i in range(n_trits):
        code = (bits >> (2 * i)) & 0b11
        if code == 0b01:
            trits.append(1)
        elif code == 0b10:
            trits.append(-1)
        else:
            trits.append(0)
    return trits


# ============================================================================
# Прямое умножение (эталон)
# ============================================================================

def mul_direct(a_trits: List[int], b_trits: List[int]) -> List[int]:
    """Прямое умножение двух списков тритов. Возвращает список длиной len(a)+len(b).

    Алгоритм:
      A × B = Σ_i Σ_j a_i × b_j × 3^(i+j)
      Каждый трит-произведение a_i × b_j ∈ {-1, 0, +1}
      Суммируем коэффициенты по столбцам, потом нормализуем (carry propagation).
    """
    n_a, n_b = len(a_trits), len(b_trits)
    n_res = n_a + n_b

    # Коэффициенты по столбцам
    coeffs = [0] * n_res
    for i, a in enumerate(a_trits):
        for j, b in enumerate(b_trits):
            coeffs[i + j] += a * b

    # Carry propagation (balanced ternary)
    result = [0] * n_res
    carry = 0
    for k in range(n_res):
        s = coeffs[k] + carry
        # Balanced division by 3: q = s / 3, r = s - 3*q, r ∈ {-1, 0, +1}
        q = s // 3
        r = s - 3 * q
        if r > 1:
            q += 1
            r -= 3
        elif r < -1:
            q -= 1
            r += 3
        result[k] = r
        carry = q
    # Если carry != 0, добавляем в старший разряд
    if carry != 0 and n_res < n_res + 1:
        result.append(carry)

    return result


# ============================================================================
# Karatsuba умножение (разбиение N → N/2 + N/2)
# ============================================================================

def mul_karatsuba(a_trits: List[int], b_trits: List[int]) -> List[int]:
    """Karatsuba: A·B = A_hi·B_hi·3^N + (A_hi+A_lo)(B_hi+B_lo) - A_hi·B_hi - A_lo·B_lo)·3^(N/2) + A_lo·B_lo.

    Рекурсивно до базового случая (N ≤ 4 — прямое умножение).
    """
    n = len(a_trits)
    assert n == len(b_trits)

    # Базовый случай: если n ≤ 4, прямое умножение
    if n <= 4:
        return mul_direct(a_trits, b_trits)

    # Разбиваем на половины
    half = n // 2
    a_lo = a_trits[:half]
    a_hi = a_trits[half:]
    b_lo = b_trits[:half]
    b_hi = b_trits[half:]

    # Три умножения (рекурсивно)
    z0 = mul_karatsuba(a_lo, b_lo)              # A_lo·B_lo
    z2 = mul_karatsuba(a_hi, b_hi)              # A_hi·B_hi
    # a_sum = a_hi + a_lo (может быть на 1 трит длиннее)
    a_sum = add_trits(a_lo, a_hi)
    b_sum = add_trits(b_lo, b_hi)
    # Уравниваем длины (a_sum и b_sum могут быть half+1)
    max_len = max(len(a_sum), len(b_sum))
    while len(a_sum) < max_len:
        a_sum.append(0)
    while len(b_sum) < max_len:
        b_sum.append(0)
    z1_full = mul_karatsuba(a_sum, b_sum)       # (A_hi+A_lo)(B_hi+B_lo)
    # z1 = z1_full - z2 - z0
    z1 = sub_trits(sub_trits(z1_full, z2), z0)

    # Сборка: z2 << (2*half) + z1 << half + z0
    result_width = 2 * n
    result = [0] * (result_width + 2)  # запас на overflow

    # Сложение с правильными сдвигами
    add_inplace(result, z0, 0)
    add_inplace(result, z1, half)
    add_inplace(result, z2, 2 * half)

    # Удаляем ведущие нули
    while len(result) > 1 and result[-1] == 0:
        result.pop()

    return result


def add_trits(a: List[int], b: List[int]) -> List[int]:
    """Сложение двух списков тритов с carry propagation."""
    max_len = max(len(a), len(b))
    result = [0] * (max_len + 1)
    carry = 0
    for i in range(max_len):
        av = a[i] if i < len(a) else 0
        bv = b[i] if i < len(b) else 0
        s = av + bv + carry
        q = s // 3
        r = s - 3 * q
        if r > 1:
            q += 1
            r -= 3
        elif r < -1:
            q -= 1
            r += 3
        result[i] = r
        carry = q
    result[max_len] = carry
    while len(result) > 1 and result[-1] == 0:
        result.pop()
    return result


def sub_trits(a: List[int], b: List[int]) -> List[int]:
    """Вычитание b из a (a - b) с carry propagation."""
    # Эквивалентно сложению a + (-b), где -b = инверсия тритов b
    neg_b = [-t for t in b]
    return add_trits(a, neg_b)


def add_inplace(result: List[int], addend: List[int], shift: int):
    """Добавляет addend в result со сдвигом shift (на месте, с carry)."""
    carry = 0
    for i, t in enumerate(addend):
        pos = i + shift
        if pos >= len(result):
            result.extend([0] * (pos - len(result) + 1))
        s = result[pos] + t + carry
        q = s // 3
        r = s - 3 * q
        if r > 1:
            q += 1
            r -= 3
        elif r < -1:
            q -= 1
            r += 3
        result[pos] = r
        carry = q
    # Прокручиваем оставшийся carry
    pos = len(addend) + shift
    while carry != 0:
        if pos >= len(result):
            result.append(0)
        s = result[pos] + carry
        q = s // 3
        r = s - 3 * q
        if r > 1:
            q += 1
            r -= 3
        elif r < -1:
            q -= 1
            r += 3
        result[pos] = r
        carry = q
        pos += 1


# ============================================================================
# Тестирование
# ============================================================================

def test_mul_kbd():
    """Сравнение mul_direct vs mul_karatsuba на 100 случайных тестах."""
    random.seed(42)
    n_trits = 20
    n_tests = 100
    passed = 0
    failed = 0

    for test_idx in range(n_tests):
        # Генерируем случайные 20-тритные числа
        a_val = random.randint(-(3**n_trits)//2, (3**n_trits)//2 - 1)
        b_val = random.randint(-(3**n_trits)//2, (3**n_trits)//2 - 1)

        a_trits = int_to_trits(a_val, n_trits)
        b_trits = int_to_trits(b_val, n_trits)

        # Эталон: прямое умножение
        expected = mul_direct(a_trits, b_trits)
        expected_int = trits_to_int(expected)

        # Karatsuba
        actual = mul_karatsuba(a_trits, b_trits)
        actual_int = trits_to_int(actual)

        # Ожидаемый результат как целое
        true_result = a_val * b_val

        if expected_int != true_result:
            print(f"FAIL test {test_idx}: direct mul wrong")
            print(f"  a={a_val} ({a_val == trits_to_int(a_trits)})")
            print(f"  b={b_val} ({b_val == trits_to_int(b_trits)})")
            print(f"  direct={expected_int}, expected={true_result}")
            failed += 1
        elif actual_int != true_result:
            print(f"FAIL test {test_idx}: Karatsuba wrong")
            print(f"  a={a_val}, b={b_val}")
            print(f"  karatsuba={actual_int}, expected={true_result}")
            print(f"  diff={actual_int - true_result}")
            failed += 1
        else:
            passed += 1

    print(f"\n{'='*60}")
    print(f"RESULT: {passed}/{n_tests} passed, {failed} failed")
    print(f"{'='*60}")
    return failed == 0


def test_simple():
    """Простые тесты для отладки."""
    # 1×1 = 1
    assert trits_to_int(mul_direct([1], [1])) == 1
    # 1×(-1) = -1
    assert trits_to_int(mul_direct([1], [-1])) == -1
    # 2×3 = 6 → 2 = [−1, 1] (−1 + 1·3 = 2), 3 = [0, 1] (0 + 1·3 = 3), 6 = [0, −1, 1] (0 + (−1)·3 + 1·9 = 6)
    two = int_to_trits(2, 4)
    three = int_to_trits(3, 4)
    six = mul_direct(two, three)
    assert trits_to_int(six) == 6, f"got {trits_to_int(six)}"
    # Karatsuba
    six_k = mul_karatsuba(two, three)
    assert trits_to_int(six_k) == 6, f"Karatsuba got {trits_to_int(six_k)}"
    print("✅ Simple tests passed")


def test_format():
    """Тест упаковки/распаковки тритов."""
    # 5 = [−1, −1, 1] (−1 − 3 + 9 = 5)
    five_trits = int_to_trits(5, 4)
    assert five_trits == [-1, -1, 1, 0], f"got {five_trits}"
    bits = pack_trits(five_trits)
    unpacked = unpack_trits(bits, 4)
    assert unpacked == five_trits
    print("✅ Format tests passed")


if __name__ == "__main__":
    print("=== Simple tests ===")
    test_simple()
    print("\n=== Format tests ===")
    test_format()
    print("\n=== mul_kbd random tests ===")
    ok = test_mul_kbd()
    if ok:
        print("\n🎉 All tests PASSED — Karatsuba algorithm correct!")
    else:
        print("\n❌ Some tests FAILED — see log above")
        exit(1)
