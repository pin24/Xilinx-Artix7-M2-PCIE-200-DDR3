#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""devseq.py — устройственная программа поверх ring tdot (черновик, 2026-10-20).

Роль: файл — БИТ-ТОЧНАЯ функциональная модель устройства, которая задаёт семантику
«данные + программа = результат» для будущего RTL-интерпретатора (device-prog). Хост
шлёт [данные-батч] + [список слоёв с повторами], плата держит веса резидентными и сама
прогоняет программу (вложенные циклы слой x повторы), возвращает результат батча.

Семантика юнита (слой):
    for p in range(pass):            # сколько раз прогнать ЧЕРЕЗ этот слой
        cur = cur @ W + b            # линейный слой (GEMM=dot-per-output-neuron)
        if relu: cur = relu(cur)
    следующий юнит получает cur на вход (цепочка).

Для проверки юнит-семантика сводится к существующему nn_audio_common.forward_batch на
CPU (numpy) и к самосогласованности repeats (forward(fwd(..))) — это и есть то, что RTL
должен воспроизводить поточечно (tf48-округление войдёт на уровне dot в RTL-пути).
"""
from __future__ import annotations
import numpy as np

# односимвольные типы — без зависимостей, numpy-only (как весь проект)
UnitT = dict

def linear_pass(cur, W, b=None, relu=False):
    """Один проход через линейный слой: cur @ W + b, опц. relu."""
    out = cur @ W
    if b is not None:
        out = out + b
    if relu:
        out = np.maximum(0.0, out)
    return out

def run_program(data, program, weights):
    """data: (B, in0) float32. program: список юнитов. weights: {layer: (W,b)}.

    Возвращает (B, out_last). Программа = цепочка юнитов; каждый юнит делает
    pass проходов через СЕБЯ (выход прохода p — вход прохода p+1). Повтор через
    слой осмыслен, когда n_in == n_out (самомаршрут: итерация того же линейного
    отображения); для «прогнать ВЕСЬ вывод N раз» стройте список юнитов с pass=1
    и повторяйте его (data подаётся на вход каждого прохода всей цепочки).
    """
    cur = np.asarray(data, dtype=np.float32)
    for unit in program:
        W, b = weights[unit["layer"]]
        if unit["pass"] > 1 and unit.get("n_in") != unit.get("n_out"):
            raise ValueError(f"repeat(pass>1) требует квадратного слоя, "
                             f"получено {unit.get('n_in')}->{unit.get('n_out')}")
        for _ in range(unit["pass"]):
            cur = linear_pass(cur, W, b if unit.get("b_en", True) else None,
                              unit.get("relu", False))
            # источники: данные или выход предыдущего юнита — здесь всегда цепочка
    return cur

def make_unit(layer, n_in, n_out, passes=1, relu=False, b_en=True, src="chain",
              ddr_base=0x0, w_stride=0):
    """Собрать юнит-описание (каноническая форма).

    ddr_base/w_stride: для будущего RTL-размещения в 256 МБ DDR3 (адрес весов юнита =
    ddr_base + layer*w_stride) — сейчас не влияет на вычисление, но фиксирует формат.
    """
    return {"layer": layer, "n_in": n_in, "n_out": n_out, "pass": passes,
            "relu": relu, "b_en": b_en, "src": src, "ddr_base": ddr_base,
            "w_stride": w_stride}

def _selftest() -> int:
    import os, sys
    _d = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, _d)
    import nn_audio_common as AC

    B, H = 64, 16
    rng = np.random.default_rng(1)
    X = rng.uniform(-1, 1, (B, 2)).astype(np.float32)
    W1 = rng.normal(0, 0.5, (2, H)).astype(np.float32); b1 = np.zeros(H, np.float32)
    W2 = rng.normal(0, 0.5, (H, 1)).astype(np.float32); b2 = np.zeros(1, np.float32)

    # 1) программа [W1(relu), W2] за 1 проход == существующий forward_batch (cpu)
    prog = [make_unit(0, 2, H, 1, relu=True), make_unit(1, H, 1, 1, relu=False)]
    wgts = {0: (W1, b1), 1: (W2, b2)}
    r_dev = run_program(X, prog, wgts)
    r_ref = AC.forward_batch(X, W1, b1, W2, b2, backend="cpu").ravel()
    d1 = np.abs(r_dev.ravel() - r_ref).max()
    assert d1 < 1e-6, f"vs forward_batch: {d1}"

    # 2) повторный проход (pass=3) через КВАДРАТНЫЙ слой W3 16->16 == применить слой 3 раза
    W3 = rng.normal(0, 0.5, (H, H)).astype(np.float32); b3 = np.zeros(H, np.float32)
    X3 = rng.uniform(-1, 1, (B, H)).astype(np.float32)
    prog2 = [make_unit(2, H, H, 3, relu=True)]
    r2 = run_program(X3, prog2, {2: (W3, b3)})
    s = X3
    for _ in range(3):
        s = linear_pass(s, W3, b3, True)
    d2 = np.abs(r2 - s).max()
    assert d2 < 1e-6, f"repeat: {d2}"

    print(f"devseq selftest OK: vs forward_batch diff={d1:.2e}, repeat diff={d2:.2e}")
    return 0

if __name__ == "__main__":
    raise SystemExit(_selftest())