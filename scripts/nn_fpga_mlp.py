#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nn_fpga_mlp.py — двухслойный перцептрон 16->16->1, forward через ПАКЕТНЫЙ
планировщик tdot (TdotScheduler.dot_batch) для максимальной утилизации платы.

Вместо одного dot-вызова на PCIe-транзакцию (медленно) forward считает
ПАКЕТАМИ по 256 задач на плате за один обмен с хостом. Это даёт большое
ускорение на больших пакетных вычислениях.

Запуск:
  python scripts/nn_fpga_mlp.py --backend fpga --max-seconds 60 --dot-print 5
  python scripts/nn_fpga_mlp.py --backend cpu  --max-seconds 20 --dot-print 5
"""
import argparse, os, sys, time
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pytorch_layer"))

def sigmoid(z):
    return 1.0 / (1.0 + np.exp(-np.clip(z, -30, 30)))
def relu(x):
    return np.maximum(0.0, x)

def bits_of_row(vals, to_bits48, TFloat):
    return [to_bits48(TFloat.from_float(float(v))) for v in vals]

def synthetic_data(n_samples=2000, n_features=16, seed=11, noise=0.6):
    rng = np.random.default_rng(seed)
    c0 = rng.normal(-1.0, 0.6, (n_samples // 2, n_features))
    c1 = rng.normal(+1.0, 0.6, (n_samples // 2, n_features))
    X = np.vstack([c0, c1]).astype(np.float32)
    y = np.array([0]*(n_samples//2) + [1]*(n_samples//2), dtype=np.float32)
    return X, y

def forward_sched(sb, X, W1, b1, W2, b2, hidden, n_features, batch):
    """Все слои через планировщик; возвращает (out, H)."""
    from fpga_backend import FpgaBackend
    from block.tfloat48 import TFloat
    def to48(vals):
        return [FpgaBackend._to_bits48(TFloat.from_float(float(v))) for v in vals]
    def to_float(bits):
        return float(FpgaBackend._bits_to_float(bits))
    N = X.shape[0]
    H = np.zeros((N, hidden), dtype=np.float32)

    # слой 1: H[i,j] = relu( dot(W1[j], X[i]) + b1[j] )
    W1b = [to48(W1[j]) for j in range(hidden)]
    pend = []                       # список (data_bits, weights_bits, i, j)
    def flush():
        nonlocal pend
        rr = sb.dot_batch([(d, w) for (d, w, _, _) in pend])
        for (d, w, i, j), bits in zip(pend, rr):
            H[i, j] = relu(to_float(bits) + b1[j])
        pend = []
    for i in range(N):
        xb = to48(X[i])
        for j in range(hidden):
            pend.append((xb, W1b[j], i, j))
            if len(pend) >= batch:
                flush()
    if pend:
        flush()

    # слой 2: out[i] = sigmoid( dot(W2, H[i]) + b2 )
    W2b = to48(W2[0])
    out = np.zeros(N, dtype=np.float32)
    k = 0
    while k < N:
        chunk = min(batch, N - k)
        pairs = [(to48(H[i]), W2b) for i in range(k, k + chunk)]
        rr = sb.dot_batch(pairs)
        for jj, bits in enumerate(rr):
            out[k + jj] = sigmoid(to_float(bits) + float(b2))
        k += chunk
    return out, H

def make_sched(mode, num_mac):
    from xdma_driver import TdotScheduler
    if sys.platform.startswith("win"):
        from xdma_driver import XdmaWinUpstream
        dev = XdmaWinUpstream(base=r"\\.\XDMA0dma")
    else:
        from xdma_driver import XdmaLinux
        dev = XdmaLinux()
    return dev, TdotScheduler(dev, num_mac=num_mac)

def train(sched_or_none, use_fpga, X, y, hidden, n_features, lr, time_budget, print_every, batch):
    tr_X, te_X, tr_y, te_y = X[:1500], X[1500:], y[:1500], y[1500:]
    W1 = np.random.default_rng(0).normal(0, 0.3, (hidden, n_features)).astype(np.float32)
    b1 = np.zeros(hidden, dtype=np.float32)
    W2 = np.random.default_rng(1).normal(0, 0.3, (1, hidden)).astype(np.float32)
    b2 = np.array([0.0], dtype=np.float32)
    t0 = time.time()
    next_print = print_every
    epoch = 0
    while True:
        epoch += 1
        if use_fpga:
            out, H = forward_sched(sched_or_none, tr_X, W1, b1, W2, b2, hidden, n_features, batch)
        else:
            hh = relu(tr_X @ W1.T + b1)
            out = sigmoid(hh @ W2.T + b2)
            H = hh
        err = (out.ravel() - tr_y).reshape(-1, 1)
        dW2 = err.T @ H / tr_X.shape[0]
        db2 = np.mean(err, axis=0)
        dh = err * W2
        dh = dh * (H > 0)
        dW1 = dh.T @ tr_X / tr_X.shape[0]
        db1 = np.mean(dh, axis=0)
        W1 -= lr * dW1
        b1 -= lr * db1
        W2 -= lr * dW2
        b2 -= lr * db2
        elapsed = time.time() - t0
        if elapsed >= next_print or epoch % 30 == 0:
            if use_fpga:
                te_out, _ = forward_sched(sched_or_none, te_X, W1, b1, W2, b2, hidden, n_features, batch)
            else:
                te_out = sigmoid(relu(te_X @ W1.T + b1) @ W2.T + b2)
            acc = ((te_out > 0.5) == (te_y > 0.5)).mean()
            print(f"  t={elapsed:6.1f}s epoch={epoch:3d}  test_acc={acc:.4f}  "
                  f"tr_loss~{np.mean((out.ravel()-tr_y)**2):.4f}", flush=True)
            next_print += print_every
        if elapsed >= time_budget:
            break
    if use_fpga:
        te_out, _ = forward_sched(sched_or_none, te_X, W1, b1, W2, b2, hidden, n_features, batch)
    else:
        te_out = sigmoid(relu(te_X @ W1.T + b1) @ W2.T + b2)
    tr_acc = ((out.ravel() > 0.5) == (tr_y > 0.5)).mean()
    te_acc = ((te_out > 0.5) == (te_y > 0.5)).mean()
    print(f"ФИНАЛ t={time.time()-t0:.1f}s epochs={epoch} tr_acc={tr_acc:.3f} te_acc={te_acc:.3f}")
    return W1, b1, W2, b2

def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", choices=["fpga", "cpu"], default="fpga")
    ap.add_argument("--features", type=int, default=16)
    ap.add_argument("--num-mac", type=int, default=16)
    ap.add_argument("--hidden", type=int, default=16)
    ap.add_argument("--samples", type=int, default=2000)
    ap.add_argument("--lr", type=float, default=0.5)
    ap.add_argument("--max-seconds", type=float, default=60.0)
    ap.add_argument("--dot-print", type=float, default=5.0)
    ap.add_argument("--batch", type=int, default=128,
                    help="задач в одном пакете планировщика (строго < depth=256, иначе кольцо обворачивается)")
    ap.add_argument("--model", default="nn_mlp_batch.npz")
    args = ap.parse_args(argv)

    X, y = synthetic_data(n_samples=args.samples, n_features=args.features)
    use_fpga = args.backend == "fpga"
    sched = None
    if use_fpga:
        dev, sched = make_sched(args.backend, args.num_mac)
    print(f"backend={args.backend} features={args.features} hidden={args.hidden} "
          f"samples={args.samples} batch={args.batch} (max {args.max_seconds}с)")
    t0 = time.time()
    W1, b1, W2, b2 = train(sched, use_fpga, X, y, args.hidden, args.features,
                           args.lr, args.max_seconds, args.dot_print, args.batch)
    print(f"обучение завершено за {time.time()-t0:.1f}с")
    if use_fpga:
        np.savez(args.model, W1=W1, b1=b1, W2=W2, b2=b2, features=args.features,
                 hidden=args.hidden, num_mac=args.num_mac)
        print(f"модель сохранена: {args.model}")
    return 0

if __name__ == "__main__":
    sys.exit(main())