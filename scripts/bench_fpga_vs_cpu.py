#!/usr/bin/env python3
"""bench_fpga_vs_cpu.py — сравнение FPGA (batched device_prog) vs чистый CPU (numpy).

Две части:
 1) END-TO-END обучение MLP (F->H->O, те же данные/веса) — время на эпоху CPU vs FPGA.
    F (вход, из данных)=2; O=1; H (скрытый) задаётся --hidden (по умолч. 16).
    Для крошечных сеток CPU выигрывает из-за фиксированной per-batch накладной FPGA.
 2) WIDE-DOT THROUGHPUT (--wide N_IN): один широкий dot на FPGA против numpy dot.

Запуск:
  python scripts\\bench_fpga_vs_cpu.py [--hidden 16] [--epochs 3] [--batch 32]
                                      [--samples 256] [--lr 0.1] [--wide 1024]
                                      [--cpu-only] [--fpga-only] [--seed 0]
"""
import os, struct, sys, time, argparse
import numpy as np
REPO = r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3"
for p in (REPO, os.path.join(REPO, "pytorch_layer"), os.path.join(REPO, "data"),
          os.path.join(REPO, "ternary_sw")):
    if p not in sys.path:
        sys.path.insert(0, p)
from xdma_driver import DeviceProgRunner, CompletionMailbox, REG_BASE, DDR3_BASE
from test_dma_win import XdmaWinDma
from nn_audio_common import make_analytic_batch, load_dataset, make_training_batch
import train_dprog_batch_mlp as tdm

def sigmoid(x): return 1.0 / (1.0 + np.exp(-np.clip(x, -50, 50)))
def _cpunow(): return time.perf_counter_ns() * 1e-9

def build_table(F, H, O, B):
    u0 = struct.pack("<QQQQ",
                     (DDR3_BASE + tdm.W1_OFF) & 0xFFFFFFFFFFFFFFFF,
                     (DDR3_BASE + tdm.H_OFF) & 0xFFFFFFFFFFFFFFFF,
                     ((F & 0xFFFF) << 48) | 0,
                     (H & 0xFFFF) | (1 << 16) | (0x11 << 40) | (B << 56))
    u1 = struct.pack("<QQQQ",
                     (DDR3_BASE + tdm.W2_OFF) & 0xFFFFFFFFFFFFFFFF,
                     (DDR3_BASE + tdm.OUT_OFF) & 0xFFFFFFFFFFFFFFFF,
                     ((H & 0xFFFF) << 48) | 0,
                     (O & 0xFFFF) | (1 << 16) | (0x04 << 32) | (0x22 << 40) | (B << 56))
    return u0 + u1

def load_data(a):
    if a.use_dataset:
        items = load_dataset(max_files=2000)
        X, y = make_training_batch(items, a.samples, a.seed)
        src = f"датасет({len(items)})"
    else:
        X, y = make_analytic_batch(a.samples, seed=a.seed)
        src = "аналитика"
    X = np.asarray(X, np.float32).reshape(-1, tdm.F)
    y = np.asarray(y, np.float32).reshape(-1, 1)
    return X, y, src

def _backward(Xs, ys, W1, W2, lr):
    cb = Xs.shape[0]
    H = Xs @ W1.T
    A = sigmoid(H)
    OUT = A @ W2.T
    err = OUT[:, 0] - ys[:, 0]
    right = (err[:, None] * W2[0]) * (A * (1.0 - A))
    W2[0] -= lr * (err @ A) / cb
    W1 -= lr * (right.T @ Xs) / cb
    return float(np.mean(err**2))

def run_cpu(X, y, W1, W2, B, epochs, lr):
    n_batches = (len(X) + B - 1) // B
    ep_ms = []; mse = []
    for ep in range(epochs):
        tot = 0.0; t0 = _cpunow()
        for i in range(n_batches):
            tot += _backward(X[i*B:(i+1)*B], y[i*B:(i+1)*B], W1, W2, lr)
        ep_ms.append((_cpunow() - t0) * 1e3); mse.append(tot / n_batches)
    return ep_ms, mse, sum(ep_ms) * 1e-3

def run_fpga(F, H, O, X, y, W1, W2, B, epochs, lr):
    # ГУАРД: буфер скрытых результатов B*H*8 должен влезать в регион H_OFF..OUT_OFF (64КБ),
    # иначе результаты портят OUT/DATA (молчаливая порча памяти -> расходящиеся веса).
    _hid = B*H*8
    _maxB = (tdm.OUT_OFF - tdm.H_OFF) // (H*8)
    if _hid > (tdm.OUT_OFF - tdm.H_OFF):
        raise RuntimeError(
            f"H={H} batch={B}: буфер скрытого слоя B*H*8={_hid} Б > региона "
            f"{tdm.OUT_OFF-tdm.H_OFF} (H_OFF..OUT_OFF). Требуется batch<={_maxB}. "
            f"Правило H<={8*1024//B if B else 0} при batch={B}.")
    dev = XdmaWinDma(base=r"\\.\XDMA0dma")
    runner = DeviceProgRunner(dev, num_mac=32, reg_base=REG_BASE)
    dev.write_dma(tdm.TABLE_OFF, build_table(F, H, O, B))
    dev.write_dma(tdm.W1_OFF, tdm.pack(W1.ravel()))
    dev.write_dma(tdm.W2_OFF, tdm.pack(W2.ravel()))
    n_batches = (len(X) + B - 1) // B
    ep_ms = []; mse = []
    for ep in range(epochs):
        tot = 0.0; t0 = _cpunow()
        for i in range(n_batches):
            xs = X[i*B:(i+1)*B]; ys = y[i*B:(i+1)*B]; cb = xs.shape[0]
            dev.write_dma(tdm.DATA_OFF, tdm.pack(xs.ravel()))
            if cb < B:
                dev.write_dma(tdm.DATA_OFF + cb*F*8, tdm.pack(np.zeros((B-cb, F), np.float32).ravel()))
            runner._reg_w(runner.DP_DATA_BASE,  (DDR3_BASE + tdm.DATA_OFF) & 0xFFFFFFFF)
            runner._reg_w(runner.DP_TABLE_BASE, (DDR3_BASE + tdm.TABLE_OFF) & 0xFFFFFFFF)
            runner._reg_w(runner.DP_MBOX_BASE,  (DDR3_BASE + tdm.MBOX_OFF) & 0xFFFFFFFF)
            runner._reg_w(runner.DP_CTRL, (2 << 16) | 1)
            for _ in range(4000):
                if not runner.state()["active"]: break
                time.sleep(0.0005)
            try: dev.read_dma((tdm.DATA_OFF + 0x10) & 0xFFFFFFFF, 8)
            except Exception: pass
            lsw = CompletionMailbox(dev, base_addr=tdm.MBOX_OFF).read_status(timeout_ms=15000, expected=0)
            hraw = np.frombuffer(dev.read_dma(tdm.H_OFF, cb*H*8), dtype="<u8")
            oraw = np.frombuffer(dev.read_dma(tdm.OUT_OFF, cb*O*8), dtype="<u8")
            h_pre = np.array([tdm.dec48(int(v) & 0xFFFFFFFFFFFF) for v in hraw], np.float32).reshape(cb, H)
            o = np.array([tdm.dec48(int(v) & 0xFFFFFFFFFFFF) for v in oraw], np.float32).reshape(cb, O)
            A = sigmoid(h_pre); err = o[:, 0] - ys[:, 0]
            right = (err[:, None] * W2[0]) * (A * (1.0 - A))
            W2[0] -= lr * (err @ A) / cb
            W1 -= lr * (right.T @ xs) / cb
            dev.write_dma(tdm.W1_OFF, tdm.pack(W1.ravel()))
            dev.write_dma(tdm.W2_OFF, tdm.pack(W2.ravel()))
            tot += float(np.mean(err**2))
        ep_ms.append((_cpunow() - t0) * 1e3); mse.append(tot / n_batches)
    dev.close()
    return ep_ms, mse, sum(ep_ms) * 1e-3

def wide_dot_cpu(N, reps=50):
    a = np.random.default_rng(0).normal(0, 0.5, N).astype(np.float32).reshape(1, N)
    b = np.random.default_rng(1).normal(0, 0.5, N).astype(np.float32).reshape(N, 1)
    t0 = _cpunow()
    for _ in range(reps):
        c = a @ b
    dt = (_cpunow() - t0) / reps
    return dt * 1e6, 2 * N / dt / 1e6

def wide_dot_fpga(N):
    dev = XdmaWinDma(base=r"\\.\XDMA0dma")
    runner = DeviceProgRunner(dev, num_mac=32, reg_base=REG_BASE)
    a = np.random.default_rng(0).normal(0, 0.5, N).astype(np.float32)
    b = np.random.default_rng(1).normal(0, 0.5, N).astype(np.float32)
    dev.write_dma(tdm.DATA_OFF, tdm.pack(a))
    dev.write_dma(tdm.W1_OFF, tdm.pack(b))
    u = struct.pack("<QQQQ",
                    (DDR3_BASE + tdm.W1_OFF) & 0xFFFFFFFFFFFFFFFF,
                    (DDR3_BASE + tdm.H_OFF) & 0xFFFFFFFFFFFFFFFF,
                    ((N & 0xFFFF) << 48) | 0,
                    (1 & 0xFFFF) | (1 << 16) | (0x33 << 40) | (1 << 56))
    dev.write_dma(tdm.TABLE_OFF, u)
    runner._reg_w(runner.DP_DATA_BASE,  (DDR3_BASE + tdm.DATA_OFF) & 0xFFFFFFFF)
    runner._reg_w(runner.DP_TABLE_BASE, (DDR3_BASE + tdm.TABLE_OFF) & 0xFFFFFFFF)
    runner._reg_w(runner.DP_MBOX_BASE,  (DDR3_BASE + tdm.MBOX_OFF) & 0xFFFFFFFF)
    t0 = _cpunow()
    runner._reg_w(runner.DP_CTRL, (1 << 16) | 1)
    lsw = CompletionMailbox(dev, base_addr=tdm.MBOX_OFF).read_status(timeout_ms=15000, expected=0)
    dt = (_cpunow() - t0)
    dev.close()
    return dt * 1e6, 2 * N / dt / 1e6

def main():
    a = argparse.ArgumentParser()
    a.add_argument("--hidden", type=int, default=16, help="ширина скрытого слоя H")
    a.add_argument("--epochs", type=int, default=3)
    a.add_argument("--batch", type=int, default=32)
    a.add_argument("--samples", type=int, default=256)
    a.add_argument("--lr", type=float, default=0.1)
    a.add_argument("--seed", type=int, default=0)
    a.add_argument("--use-dataset", action="store_true", default=True)
    a.add_argument("--cpu-only", action="store_true")
    a.add_argument("--fpga-only", action="store_true")
    a.add_argument("--wide", type=int, default=1024, help="N_IN wide-dot bench (0=skip)")
    a = a.parse_args()
    F, O = tdm.F, 1
    H = a.hidden
    X, y, src = load_data(a)
    rng = np.random.default_rng(a.seed)
    W1r = rng.normal(0, 0.5, (H, F)).astype(np.float32)
    W2r = rng.normal(0, 0.5, (O, H)).astype(np.float32)
    print(f"источник={src} samples={len(X)} batch={a.batch} epochs={a.epochs} lr={a.lr} (F={F} H={H} O={O})")
    R = {}
    if not a.fpga_only:
        ep, mse, T = run_cpu(X, y, W1r.copy(), W2r.copy(), a.batch, a.epochs, a.lr); R["cpu"] = (ep, mse, T)
    if not a.cpu_only:
        ep, mse, T = run_fpga(F, H, O, X, y, W1r.copy(), W2r.copy(), a.batch, a.epochs, a.lr); R["fpga"] = (ep, mse, T)
    print("\n=== 1) END-TO-END MLP TRAIN (ms/epoch) ===")
    print("%-4s | %-12s | %-12s | %-11s" % ("ep", "cpu_ms", "fpga_ms", "ratio c/f"))
    for e in range(a.epochs):
        c = R["cpu"][0][e] if "cpu" in R else None
        f = R["fpga"][0][e] if "fpga" in R else None
        r = (f"{c/f:.2f}x" if (c and f) else "-")
        print("%-4d | %-12s | %-12s | %-11s" % (e+1, f"{c:.4f}" if c is not None else "-",
                                                 f"{f:.1f}" if f is not None else "-", r))
    for k in ("cpu", "fpga"):
        if k in R:
            ep, mse, T = R[k]
            print(f"  {k.upper()}: total={T:.4f}s | MSE {mse[0]:.4f}->{mse[-1]:.4f} | avg {np.mean(ep):.4f}ms/ep")
    if "cpu" in R and "fpga" in R:
        print(f"  >>> END-TO-END ratio CPU/FPGA = {R['cpu'][2]/R['fpga'][2]:.4f}x (CPU быстрее для этой маленькой сетки)")
    if a.wide > 0:
        print(f"\n=== 2) WIDE DOT N_IN={a.wide} throughput ===")
        if not a.cpu_only:
            u, mf = wide_dot_cpu(a.wide); print(f"  CPU  dot({a.wide}): {u:.2f} us, {mf:.2f} MFLOPs")
        if not a.fpga_only:
            u, mf = wide_dot_fpga(a.wide); print(f"  FPGA dot({a.wide}): {u:.2f} us, {mf:.2f} MFLOPs")
    return 0

if __name__ == "__main__":
    sys.exit(main())