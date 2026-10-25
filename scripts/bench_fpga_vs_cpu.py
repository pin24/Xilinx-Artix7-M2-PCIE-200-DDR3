#!/usr/bin/env python3
"""bench_fpga_vs_cpu.py — сравнение FPGA (batched device_prog) vs чистый CPU (numpy).

Две части:
 1) END-TO-END обучение MLP (F->H->O, те же данные/веса) — время на эпоху CPU vs FPGA.
 2) WIDE-DOT THROUGHPUT (--wide N_IN): один широкий dot на FPGA против numpy dot.

Раскладка буферов в DDR определяется --mem (размер рабочей области MLP в байтах,
поддерживает суффиксы K/M, напр. 128K=131072, 1M=1048576). Область ограничена
потолком 85% от DDR3 (256МиБ); при запросе больше — урезание до максимума и сообщение.
Нулевой XDMA-канал: данные пишутся в DDR через DMA H2C, адреса собирает программа,
движок (device_prog) сам читает их по этим адресам.

Запуск:
  python scripts\\bench_fpga_vs_cpu.py [--mem 1M] [--hidden 16] [--epochs 3] [--batch 32]
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

DDR_TOTAL = 0x10000000            # 256 МиБ DDR3 (0x80000000..0x8FFFFFFF)
DDR_MAX85 = int(0.85 * DDR_TOTAL) # 85% потолок рабочей области
REGION_BASE = 0x00A00000          # база MLP-области внутри DDR3
ALIGN = 64

def sigmoid(x): return 1.0 / (1.0 + np.exp(-np.clip(x, -50, 50)))
def _cpunow(): return time.perf_counter_ns() * 1e-9

def parse_mem(s):
    """'128'->128, '128K'->131072, '1M'->1048576, '1G'->... (байт)."""
    s = str(s).strip().upper()
    if s.endswith("G"): mult = 1024**3; s = s[:-1]
    elif s.endswith("M"): mult = 1024**2; s = s[:-1]
    elif s.endswith("K"): mult = 1024; s = s[:-1]
    else: mult = 1
    return int(float(s) * mult)

def clamp_mem(req_bytes):
    """Урезать до 85% DDR, вернуть (bytes, clamped_flag)."""
    req = int(req_bytes)
    if req > DDR_MAX85:
        return DDR_MAX85, True
    return req, False

def layout(F, H, O, B, mem):
    """Разложить MLP-буферы последовательно в области [REGION_BASE, REGION_BASE+mem].
    Возвращает dict офсетов и требуемый размер; кидает RuntimeError если область мала."""
    def al(x): return (x + ALIGN - 1) // ALIGN * ALIGN
    off = REGION_BASE
    d = {}
    d["DATA"]  = off; off += al(B*F*8)
    d["W1"]    = off; off += al(H*F*8)
    d["W2"]    = off; off += al(O*H*8)
    d["H"]     = off; off += al(B*H*8)   # скрытый буфер (обычно самый большой)
    d["OUT"]   = off; off += al(B*O*8)
    d["TABLE"] = off; off += al(2*32)
    d["MBOX"]  = off; off += al(16)
    need = off - REGION_BASE
    if need > mem:
        raise RuntimeError(
            f"область DDR мала: нужно ~{need} Б (F={F} H={H} O={O} B={B}), --mem={mem} Б. "
            f"Увеличь --mem или уменьши H/batch.")
    return d, need

def build_table(off, F, H, O, B):
    u0 = struct.pack("<QQQQ",
                     (DDR3_BASE + off["W1"]) & 0xFFFFFFFFFFFFFFFF,
                     (DDR3_BASE + off["H"]) & 0xFFFFFFFFFFFFFFFF,
                     ((F & 0xFFFF) << 48) | 0,
                     (H & 0xFFFF) | (1 << 16) | (0x11 << 40) | (B << 56))
    u1 = struct.pack("<QQQQ",
                     (DDR3_BASE + off["W2"]) & 0xFFFFFFFFFFFFFFFF,
                     (DDR3_BASE + off["OUT"]) & 0xFFFFFFFFFFFFFFFF,
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

def run_fpga(F, H, O, off, X, y, W1, W2, B, epochs, lr):
    dev = XdmaWinDma(base=r"\\.\XDMA0dma")
    runner = DeviceProgRunner(dev, num_mac=32, reg_base=REG_BASE)
    dev.write_dma(off["TABLE"], build_table(off, F, H, O, B))
    dev.write_dma(off["W1"], tdm.pack(W1.ravel()))
    dev.write_dma(off["W2"], tdm.pack(W2.ravel()))
    n_batches = (len(X) + B - 1) // B
    ep_ms = []; mse = []
    for ep in range(epochs):
        tot = 0.0; t0 = _cpunow()
        for i in range(n_batches):
            xs = X[i*B:(i+1)*B]; ys = y[i*B:(i+1)*B]; cb = xs.shape[0]
            dev.write_dma(off["DATA"], tdm.pack(xs.ravel()))
            if cb < B:
                dev.write_dma(off["DATA"] + cb*F*8, tdm.pack(np.zeros((B-cb, F), np.float32).ravel()))
            runner._reg_w(runner.DP_DATA_BASE,  (DDR3_BASE + off["DATA"]) & 0xFFFFFFFF)
            runner._reg_w(runner.DP_TABLE_BASE, (DDR3_BASE + off["TABLE"]) & 0xFFFFFFFF)
            runner._reg_w(runner.DP_MBOX_BASE,  (DDR3_BASE + off["MBOX"]) & 0xFFFFFFFF)
            runner._reg_w(runner.DP_CTRL, (2 << 16) | 1)
            for _ in range(4000):
                if not runner.state()["active"]: break
                time.sleep(0.0005)
            try: dev.read_dma((off["DATA"] + 0x10) & 0xFFFFFFFF, 8)
            except Exception: pass
            lsw = CompletionMailbox(dev, base_addr=off["MBOX"]).read_status(timeout_ms=15000, expected=0)
            hraw = np.frombuffer(dev.read_dma(off["H"], cb*H*8), dtype="<u8")
            oraw = np.frombuffer(dev.read_dma(off["OUT"], cb*O*8), dtype="<u8")
            h_pre = np.array([tdm.dec48(int(v) & 0xFFFFFFFFFFFF) for v in hraw], np.float32).reshape(cb, H)
            o = np.array([tdm.dec48(int(v) & 0xFFFFFFFFFFFF) for v in oraw], np.float32).reshape(cb, O)
            A = sigmoid(h_pre); err = o[:, 0] - ys[:, 0]
            right = (err[:, None] * W2[0]) * (A * (1.0 - A))
            W2[0] -= lr * (err @ A) / cb
            W1 -= lr * (right.T @ xs) / cb
            dev.write_dma(off["W1"], tdm.pack(W1.ravel()))
            dev.write_dma(off["W2"], tdm.pack(W2.ravel()))
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

def wide_dot_fpga(N, off):
    dev = XdmaWinDma(base=r"\\.\XDMA0dma")
    runner = DeviceProgRunner(dev, num_mac=32, reg_base=REG_BASE)
    a = np.random.default_rng(0).normal(0, 0.5, N).astype(np.float32)
    b = np.random.default_rng(1).normal(0, 0.5, N).astype(np.float32)
    dev.write_dma(off["DATA"], tdm.pack(a))
    dev.write_dma(off["W1"], tdm.pack(b))
    u = struct.pack("<QQQQ",
                    (DDR3_BASE + off["W1"]) & 0xFFFFFFFFFFFFFFFF,
                    (DDR3_BASE + off["H"]) & 0xFFFFFFFFFFFFFFFF,
                    ((N & 0xFFFF) << 48) | 0,
                    (1 & 0xFFFF) | (1 << 16) | (0x33 << 40) | (1 << 56))
    dev.write_dma(off["TABLE"], u)
    runner._reg_w(runner.DP_DATA_BASE,  (DDR3_BASE + off["DATA"]) & 0xFFFFFFFF)
    runner._reg_w(runner.DP_TABLE_BASE, (DDR3_BASE + off["TABLE"]) & 0xFFFFFFFF)
    runner._reg_w(runner.DP_MBOX_BASE,  (DDR3_BASE + off["MBOX"]) & 0xFFFFFFFF)
    t0 = _cpunow()
    runner._reg_w(runner.DP_CTRL, (1 << 16) | 1)
    lsw = CompletionMailbox(dev, base_addr=off["MBOX"]).read_status(timeout_ms=15000, expected=0)
    dt = (_cpunow() - t0)
    dev.close()
    return dt * 1e6, 2 * N / dt / 1e6

def main():
    a = argparse.ArgumentParser()
    a.add_argument("--mem", type=str, default="2M", help="рабочая область DDR для MLP (байт или 128K/1M/2M/64M); потолок 85% DDR")
    a.add_argument("--hidden", type=int, default=16)
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
    req = parse_mem(a.mem)
    mem, clamped = clamp_mem(req)
    if clamped:
        _m = f"УРЕЗАНО до 85% DDR ({DDR_MAX85} Б = {DDR_MAX85/1048576:.2f} МиБ)"
    else:
        _m = f"в пределах 85% DDR ({int(mem/DDR_MAX85*100)}%)"
    print(f"mem: запрошено {req} Б, область {mem} Б ({mem/1048576:.2f} МиБ); {_m}")
    off, need = layout(F, H, O, a.batch, mem)
    print(f"раскладка буферов: DATA={off['DATA']:#x} W1={off['W1']:#x} W2={off['W2']:#x} "
          f"H={off['H']:#x} OUT={off['OUT']:#x} TABLE={off['TABLE']:#x} MBOX={off['MBOX']:#x}; занято ~{need} Б")
    rng = np.random.default_rng(a.seed)
    W1r = rng.normal(0, 0.5, (H, F)).astype(np.float32)
    W2r = rng.normal(0, 0.5, (O, H)).astype(np.float32)
    print(f"источник={src} samples={len(X)} batch={a.batch} epochs={a.epochs} lr={a.lr} (F={F} H={H} O={O})")
    R = {}
    if not a.fpga_only:
        ep, mse, T = run_cpu(X, y, W1r.copy(), W2r.copy(), a.batch, a.epochs, a.lr); R["cpu"] = (ep, mse, T)
    if not a.cpu_only:
        ep, mse, T = run_fpga(F, H, O, off, X, y, W1r.copy(), W2r.copy(), a.batch, a.epochs, a.lr); R["fpga"] = (ep, mse, T)
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
            u, mf = wide_dot_fpga(a.wide, off); print(f"  FPGA dot({a.wide}): {u:.2f} us, {mf:.2f} MFLOPs")
    return 0

if __name__ == "__main__":
    sys.exit(main())