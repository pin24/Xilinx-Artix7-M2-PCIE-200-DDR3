#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nn_fpga_train.py — простая нейросеть (логистическая регрессия), чей forward
(W·x) выполняется НА ПЛАТЕ A7_M2 через tdot (TFloat48). Обучение — SGD на host,
модель сохраняется в .npz, затем инференс на плате.

Каждое скалярное произведение идёт на плату через FpgaBackend(mode='fpga'),
который вызывает TdotCore.dot в DDR3. Точность — в TFloat48 (приближённая),
поэтому сходимость чуть отличается от float64, но для линейно-делимой задачи ок.

Запуск (из корня проекта):
  python scripts/nn_fpga_train.py --train --infer
"""
import argparse, os, sys, time
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pytorch_layer"))

def sigmoid(z):
    z = np.clip(z, -30, 30)
    return 1.0 / (1.0 + np.exp(-z))

def make_fpga_backend(n_features, num_mac):
    from fpga_backend import FpgaBackend
    if sys.platform.startswith("win"):
        from xdma_driver import XdmaWinUpstream
        dev = XdmaWinUpstream(base=r"\\.\XDMA0dma")
    else:
        from xdma_driver import XdmaLinux
        dev = XdmaLinux()
    return FpgaBackend(mode="fpga", n=n_features, device=dev, num_mac=num_mac)

def synthetic_data(n_samples=200, n_features=8, seed=7, noise=0.5):
    rng = np.random.default_rng(seed)
    c0 = rng.normal(-1.0, 0.6, (n_samples // 2, n_features))
    c1 = rng.normal(+1.0, 0.6, (n_samples // 2, n_features))
    X = np.vstack([c0, c1]).astype(np.float32)
    y = np.array([0] * (n_samples // 2) + [1] * (n_samples // 2), dtype=np.float32)
    return X, y

def forward_fpga(fb, X, W, b):
    """y_hat[i] = sigmoid( dot(W, X[i]) + b ) — dot на плате."""
    out = np.zeros(X.shape[0], dtype=np.float32)
    for i in range(X.shape[0]):
        d = fb.run_dot(X[i:i+1], W.reshape(1, -1))[0] + b
        out[i] = sigmoid(d)
    return out

def train(features, num_mac, epochs, lr):
    fb = make_fpga_backend(features, num_mac)
    X, y = synthetic_data(n_samples=200, n_features=features)
    # split: train/test
    tr, te = X[:140], X[140:]
    ytr, yte = y[:140], y[140:]
    W = np.zeros(features, dtype=np.float32)
    bi = 0.0
    t0 = time.time()
    for ep in range(epochs):
        pred = forward_fpga(fb, tr, W, bi)
        dW = np.zeros(features, dtype=np.float32)
        db = 0.0
        for i in range(tr.shape[0]):
            err = (pred[i] - ytr[i])
            dW += err * tr[i]
            db += err
        W -= lr * dW / tr.shape[0]
        bi -= lr * db / tr.shape[0]
        acc = ((forward_fpga(fb, te, W, bi) > 0.5) == (yte > 0.5)).mean()
        print(f"  epoch {ep+1:2d}: train_acc(stdout-mid)=-, test_acc={acc:.3f}")
    dt = time.time() - t0
    # финальная точность (на плате)
    tr_acc = ((forward_fpga(fb, tr, W, bi) > 0.5) == (ytr > 0.5)).mean()
    te_acc = ((forward_fpga(fb, te, W, bi) > 0.5) == (yte > 0.5)).mean()
    print(f"обучение {dt:.1f}s | W[bias]={bi:.3f} | tr_acc={tr_acc:.3f} te_acc={te_acc:.3f}")
    return fb, W, bi, tr, te, ytr, yte

def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--features", type=int, default=8)
    ap.add_argument("--num-mac", type=int, default=16)
    ap.add_argument("--epochs", type=int, default=10)
    ap.add_argument("--lr", type=float, default=0.5)
    ap.add_argument("--train", action="store_true")
    ap.add_argument("--infer", action="store_true")
    ap.add_argument("--model", default="nn_fpga_model.npz")
    args = ap.parse_args(argv)

    model_path = os.path.join("." , args.model)
    if args.train:
        fb, W, bi, tr, te, ytr, yte = train(args.features, args.num_mac, args.epochs, args.lr)
        np.savez(model_path, W=W, b=bi, features=args.features, num_mac=args.num_mac)
        print(f"модель сохранена: {model_path}")
    if args.infer or not args.train:
        if not os.path.exists(model_path):
            print("модель не найдена — сначала --train")
            return 1
        d = np.load(model_path, allow_pickle=True)
        W, bi = d["W"], float(d["b"])
        fb = make_fpga_backend(int(d["features"]), int(d["num_mac"]))
        X, y = synthetic_data(n_samples=200, n_features=int(d["features"]))
        pred = forward_fpga(fb, X, W, bi)
        acc = ((pred > 0.5) == (y > 0.5)).mean()
        print(f"ИНФЕРЕНС (на плате): accuracy={acc:.3f} на {X.shape[0]} сэмплах")
        print(f"примеры: pred_head={pred[:8]}, y_head={y[:8]}")
    return 0

if __name__ == "__main__":
    sys.exit(main())