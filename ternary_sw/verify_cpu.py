"""Проверочный скрипт: TFloat40 против float32 на CPU.

Прогоняет конвертацию и операции +,-,*,/ на наборе значений и сверяет
результат с float32. Выводит максимальную относительную ошибку и ULP-ошибку.

Запуск:  python verify_cpu.py
"""
from __future__ import annotations
import sys, os, math
import struct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ternary import tfloat40 as tf
from ternary import arith
from ternary.tfloat40 import TFloat


def to_f32(x: float) -> float:
    return struct.unpack("f", struct.pack("f", x))[0]


def ulp_err32(a: float, b: float) -> float:
    """Ошибка в единицах ULP float32."""
    if a == b:
        return 0.0
    # битовое расстояние между двумя float32
    ia = struct.unpack("i", struct.pack("f", to_f32(a)))[0]
    ib = struct.unpack("i", struct.pack("f", to_f32(b)))[0]
    if (ia < 0) != (ib < 0):
        return float("inf")
    return abs(ia - ib)


def gen_values():
    """Набор представимых значений для тестов."""
    vals = [0.0, 1.0, -1.0, 3.0, -3.0, 0.5, -0.5,
            0.3333333333, 1.5, 2.0, 2.5, 0.1, -0.1, 100.0, -100.0,
            0.001, 1e-5, 1234.5678, -9876.5432]
    # случайные float32
    import random
    random.seed(42)
    for _ in range(200):
        vals.append(to_f32(random.uniform(-1000, 1000)))
    for _ in range(100):
        vals.append(to_f32(random.uniform(-0.001, 0.001)))
    return vals


def check_conversion(vals):
    print("=== Конвертация float32 -> TFloat40 -> float32 ===")
    max_rel = 0.0
    max_ulp = 0.0
    worst = None
    for v in vals:
        t = TFloat.from_float(v)
        if t.is_error():
            continue
        back = t.to_float()
        if v == 0.0:
            rel = 0.0 if back == 0.0 else float("inf")
        else:
            rel = abs(back - v) / max(abs(v), 1e-300)
        u = ulp_err32(v, back)
        if u > max_ulp:
            max_ulp = u
            worst = (v, back, rel, u)
        max_rel = max(max_rel, rel)
    print(f"  max относительная ошибка: {max_rel:.3e}")
    print(f"  max ULP-ошибка:          {max_ulp:.1f} ulp")
    if worst:
        print(f"  худший случай: {worst[0]:.9g} -> {worst[1]:.9g} (rel={worst[2]:.2e}, ulp={worst[3]:.1f})")
    return max_rel, max_ulp


def check_binary_op(name, fn, vals):
    print(f"=== Операция: {name} ===")
    max_ulp = 0.0
    max_rel = 0.0
    worst = None
    n = 0
    for a in vals:
        for b in vals:
            if b == 0.0 and name == "div":
                continue
            ta = TFloat.from_float(a)
            tb = TFloat.from_float(b)
            try:
                tr = fn(ta, tb)
            except Exception:
                continue
            if tr.is_error():
                continue
            # float32-эталон
            fa = to_f32(a)
            fb = to_f32(b)
            if name == "add":
                ref = to_f32(fa + fb)
            elif name == "sub":
                ref = to_f32(fa - fb)
            elif name == "mul":
                ref = to_f32(fa * fb)
            elif name == "div":
                ref = to_f32(fa / fb)
            got = tr.to_float()
            u = ulp_err32(ref, got)
            if ref != 0.0:
                rel = abs(got - ref) / abs(ref)
            else:
                rel = abs(got)
            n += 1
            if u > max_ulp:
                max_ulp = u
                worst = (a, b, ref, got, rel, u)
            max_rel = max(max_rel, rel)
    print(f"  проверено пар: {n}")
    print(f"  max ULP-ошибка:          {max_ulp:.1f} ulp")
    print(f"  max относительная ошибка: {max_rel:.3e}")
    if worst:
        print(f"  худший случай: {worst[0]:.9g} op {worst[1]:.9g} = ref {worst[2]:.9g}, got {worst[3]:.9g} (rel={worst[4]:.2e}, ulp={worst[5]:.1f})")
    return max_rel, max_ulp


def main():
    vals = gen_values()
    print(f"Тестовых значений: {len(vals)}")
    r1, u1 = check_conversion(vals)
    print()
    results = {}
    for name, fn in [("add", arith.add), ("sub", arith.sub),
                     ("mul", arith.mul), ("div", arith.div)]:
        r, u = check_binary_op(name, fn, vals)
        results[name] = (r, u)
        print()
    print("=== ИТОГ ===")
    print(f"  конвертация: rel={r1:.2e}, ulp={u1:.1f}")
    for name, (r, u) in results.items():
        print(f"  {name}: rel={r:.2e}, ulp={u:.1f}")


if __name__ == "__main__":
    main()
