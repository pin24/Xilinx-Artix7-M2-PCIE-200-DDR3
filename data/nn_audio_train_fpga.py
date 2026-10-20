#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nn_audio_train_fpga.py — обучение, где РОЛЬ FPGA = вспомогательный умножитель.

Акселератор tdot умеет только dot (умножение-накопление). Здесь он используется
как математический сопроцессор: вся нейросетевая работа (сеть, backprop) живёт в
Python, а ЛИНЕЙНЫЕ ПРЕОБРАЗОВАНИЯ (matmul) считаются на FPGA.

Т.к. на этом железе нет обратного распространения, обучение построено по схеме
Random Features (ELM): случайный скрытый слой, а его признаки для каждого примера
вычисляются НА FPGA (16 dot на пример через tdot); обучаемый линейный выход
подгоняется под эти FPGA-признаки методом наименьших квадратов на хосте.
Итог: весь multiply-интенсивный труд (скрытое представление) — на FPGA.

Использование:
    python data/nn_audio_train_fpga.py --pairs 300 --out audio_model_fpga.npz
"""
import os, sys, time, argparse
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pytorch_layer"))
from nn_audio_common import HIDDEN, make_analytic_batch, save_model_npz, matmul_w

def make_fpga_backend():
    from fpga_backend import FpgaBackend
    from xdma_driver import XdmaWinUpstream, TdotCore
    dev = XdmaWinUpstream(base=r"\\.\XDMA0dma")
    TdotCore(dev, num_mac=16).set_sched(False)   # legacy-GO path active
    return FpgaBackend(mode="fpga", n=HIDDEN, device=dev, num_mac=16)

def fpga_hidden(x, W1, b1, fb):
    """Скрытый признак одного сэмпла, считаемый НА FPGA (умножитель): relu(W1@x+b1)."""
    return np.maximum(0.0, matmul_w(np.array([x], dtype=np.float32), W1, "fpga", fb) + b1).ravel()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pairs", type=int, default=300)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", default="audio_model_fpga.npz")
    args = ap.parse_args()

    fb = make_fpga_backend()
    xs, ys = make_analytic_batch(args.pairs, args.seed)
    rng = np.random.default_rng(args.seed)
    W1 = rng.normal(0, 1.0, (2, HIDDEN)).astype(np.float32)   # случайный необучаемый скрытый слой
    b1 = rng.normal(0, 1.0, (HIDDEN,)).astype(np.float32)
    m = xs.shape[0]
    H = np.zeros((m, HIDDEN), dtype=np.float32)
    print(f"Вычисление скрытых признаков НА FPGA ({m} примеров x {HIDDEN} нейронов)...")
    t0 = time.time()
    for i in range(m):
        H[i] = fpga_hidden(xs[i], W1, b1, fb)
    print(f"  FPGA-forward готов за {time.time()-t0:.1f}с")
    # обучаемый линейный выход по МНК (хосту} на FPGA-признаках
    Ht = H.T
    W2 = (np.linalg.pinv(Ht @ H + 1e-3 * np.eye(HIDDEN)) @ (Ht @ ys.ravel()))[:, None].astype(np.float32)
    b2 = np.zeros(1, dtype=np.float32)
    err = H @ W2 + b2 - ys
    rmse = np.sqrt(np.mean(err ** 2))
    print(f"RMSE (fpga-признаки): {rmse:.5f}")
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), args.out)
    save_model_npz(out, W1, b1, W2, b2, meta={"backend": "fpga-elm (умножитель)", "pairs": args.pairs, "hidden": HIDDEN})
    print(f"Модель (обучена на FPGA-умножителе) сохранена: {out}")

if __name__ == "__main__":
    main()