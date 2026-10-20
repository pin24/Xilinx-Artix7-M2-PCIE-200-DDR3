#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nn_audio_train_cpu.py — обучение MLP 2->16->1 на CPU (линейные слои = numpy/BLAS).

Использование:
    python data/nn_audio_train_cpu.py [--epochs 400] [--batch 128] [--lr 0.05] [--pairs 40000]
"""
import os, sys, time, argparse
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nn_audio_common as AC
from nn_audio_common import (HIDDEN, init_weights, make_training_batch,
                             make_analytic_batch, save_model_npz, load_dataset)

def train(xs, ys, W1, b1, W2, b2, epochs, batch, lr):
    n = xs.shape[0]
    for ep in range(epochs):
        perm = np.random.default_rng(ep).permutation(n)
        tot = 0.0; cnt = 0
        for s in range(0, n, batch):
            idx = perm[s:s + batch]
            Xb = xs[idx]; Yb = ys[idx]
            Z1 = np.maximum(0.0, Xb @ W1 + b1)          # (B,H) relu
            A = Z1 @ W2 + b2                             # (B,1) линейный
            err = A - Yb
            loss = np.mean(err ** 2)
            g2 = err                                     # (B,1)
            dW2 = Z1.T @ g2 / batch                      # (H,1)
            db2 = g2.mean(axis=0)                        # (1,)
            g1 = (g2 @ W2.T) * (Z1 > 0)                  # (B,H)
            dW1 = Xb.T @ g1 / batch                      # (2,H)
            db1 = g1.mean(axis=0)                        # (H,)
            W2 -= lr * dW2; b2 -= lr * db2
            W1 -= lr * dW1; b1 -= lr * db1
            tot += loss * batch; cnt += batch
        if ep % 25 == 0 or ep == epochs - 1:
            print(f"  epoch {ep+1:4d}: loss={tot/cnt:.6f}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hidden", type=int, default=AC.HIDDEN, help="ширина скрытого слоя (16/32/64; >16 = чанки по 16 MAC)")
    ap.add_argument("--epochs", type=int, default=400)
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--lr", type=float, default=0.05)
    ap.add_argument("--pairs", type=int, default=40000)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--use-dataset", action="store_true")
    ap.add_argument("--out", default="audio_model_cpu.npz")
    args = ap.parse_args()
    AC.HIDDEN = args.hidden   # ширина скрытого слоя (64 = чанки по 16 MAC)
    HIDDEN = args.hidden                    # синхроним локальную копию (обход capture-at-import)

    items = load_dataset() if args.use_dataset else []
    xs, ys = (make_training_batch(items, args.pairs, args.seed) if items
              else make_analytic_batch(args.pairs, args.seed))
    W1, b1, W2, b2 = init_weights(args.seed)
    print(f"Обучение MLP ({HIDDEN} скрытых) на CPU, {len(xs)} пар...")
    tt = time.time()
    train(xs, ys, W1, b1, W2, b2, args.epochs, args.batch, args.lr)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), args.out)
    save_model_npz(out, W1, b1, W2, b2, meta={"backend": "cpu", "epochs": args.epochs, "hidden": HIDDEN})
    print(f"Модель сохранена: {out}  (обучение {time.time()-tt:.1f}с)")

if __name__ == "__main__":
    main()