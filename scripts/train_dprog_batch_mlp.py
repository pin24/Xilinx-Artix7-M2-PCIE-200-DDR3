#!/usr/bin/env python3
"""train_dprog_batch_mlp.py — обучение MLP (аудио) с БАТЧЕВЫМ GEMM через device_prog.

Схема: каждый слой — один device_prog-юнит с n_batch = размер мини-батча.
За один прогон программы (2 юнита) устройство считает ВЕСЬ forward батча:
  unit0: n_in=F, n_out=H, n_batch=B, src=data -> H (B строк пре-активаций)
  unit1: n_in=H, n_out=O, n_batch=B, src=prev -> OUT (B×O)
Хост: активация (sigmoid/линейный), градиент, обновление весов, запись W в DDR3,
повтор GO. В отличие от per-sample цикла (62 мс/сэмпл) — один прогон на батч.

Запуск: python scripts\\train_dprog_batch_mlp.py [--epochs N] [--batch B] [--samples N]
"""
import os, struct, sys, time
import numpy as np
REPO = r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3"
for p in (REPO, os.path.join(REPO, "pytorch_layer"), os.path.join(REPO, "data"),
          os.path.join(REPO, "ternary_sw")):
    if p not in sys.path:
        sys.path.insert(0, p)
from device_isa import _tf_to_bits48
from block.tfloat48 import TFloat
from xdma_driver import DeviceProgRunner, CompletionMailbox, REG_BASE, DDR3_BASE
from test_dma_win import XdmaWinDma
from nn_audio_common import make_analytic_batch, load_dataset, make_training_batch

F, H, O = 2, 16, 1
DATA_OFF, W1_OFF, W2_OFF = 0x00B00000, 0x00B10000, 0x00B20000
H_OFF, OUT_OFF, MBOX_OFF, TABLE_OFF = 0x00A20000, 0x00A30000, 0x00120000, 0x00130000

def tf(v): return _tf_to_bits48(TFloat.from_float(float(v)))
def dec48(v): return TFloat(v & ((1 << 40) - 1), (v >> 40) & 0xFF, False).to_float()
def pack(vals): return b"".join(struct.pack("<Q", tf(v) & 0xFFFFFFFFFFFF) for v in vals)

def build_table(B):
    u0 = struct.pack("<QQQQ",
                     (DDR3_BASE + W1_OFF) & 0xFFFFFFFFFFFFFFFF,
                     (DDR3_BASE + H_OFF) & 0xFFFFFFFFFFFFFFFF,
                     ((F & 0xFFFF) << 48) | 0,
                     (H & 0xFFFF) | (1 << 16) | (0x11 << 40) | (B << 56))
    u1 = struct.pack("<QQQQ",
                     (DDR3_BASE + W2_OFF) & 0xFFFFFFFFFFFFFFFF,
                     (DDR3_BASE + OUT_OFF) & 0xFFFFFFFFFFFFFFFF,
                     ((H & 0xFFFF) << 48) | 0,
                     (O & 0xFFFF) | (1 << 16) | (0x04 << 32) | (0x22 << 40) | (B << 56))
    return u0 + u1

def sigmoid(x): return 1.0 / (1.0 + np.exp(-np.clip(x, -50, 50)))

def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--samples", type=int, default=256)
    ap.add_argument("--lr", type=float, default=0.5)
    ap.add_argument("--use-dataset", action="store_true", default=True,
                    help="обучать на реальном датасете data\\audio_dataset_500_3s (по умолч.)")
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()

    if a.use_dataset:
        items = load_dataset(max_files=2000)
        X, y = make_training_batch(items, a.samples, a.seed)
        src = f"датасет (%d файлов)" % len(items)
    else:
        X, y = make_analytic_batch(a.samples, seed=a.seed)
        src = "аналитика"
    X = np.asarray(X, np.float32).reshape(-1, F)
    y = np.asarray(y, np.float32).reshape(-1, 1)
    rng = np.random.default_rng(a.seed)
    print(f"Источник данных: {src}; samples={X.shape[0]}")
    W1 = rng.normal(0, 0.5, (H, F)).astype(np.float32)
    W2 = rng.normal(0, 0.5, (O, H)).astype(np.float32)

    dev = XdmaWinDma(base=r"\\.\XDMA0dma")
    runner = DeviceProgRunner(dev, num_mac=32, reg_base=REG_BASE)
    dev.write_dma(W1_OFF, pack(W1.ravel()))
    dev.write_dma(W2_OFF, pack(W2.ravel()))

    B = a.batch
    dev.write_dma(TABLE_OFF, build_table(B))
    n_batches = (len(X) + B - 1) // B
    print(f"batched device_prog MLP: F={F} H={H} O={O} samples={len(X)} batch={B} n_batches={n_batches}")

    t0 = time.monotonic()
    for ep in range(1, a.epochs + 1):
        tot = 0.0
        for i in range(n_batches):
            xs = X[i*B:(i+1)*B]; ys = y[i*B:(i+1)*B]
            curB = xs.shape[0]
            dev.write_dma(DATA_OFF, pack(xs.ravel()))
            # если последний батч короче — таблица жёстко на B; дополним до B нулями
            if curB < B:
                dev.write_dma(DATA_OFF + curB*F*8, pack(np.zeros((B-curB, F), np.float32).ravel()))
                dev.write_dma(TABLE_OFF, build_table(B))  # пересборка не нужна
            runner._reg_w(runner.DP_DATA_BASE,  (DDR3_BASE + DATA_OFF) & 0xFFFFFFFF)
            runner._reg_w(runner.DP_TABLE_BASE, (DDR3_BASE + TABLE_OFF) & 0xFFFFFFFF)
            runner._reg_w(runner.DP_MBOX_BASE,  (DDR3_BASE + MBOX_OFF) & 0xFFFFFFFF)
            runner._reg_w(runner.DP_CTRL, (2 << 16) | 1)   # n_units=2, GO
            # FIX-реки́йс (Вася, 2026-10-23): после GO дать программе улечься —
            # дождаться, пока active спадает (данные mailbox дописались в FIFO/MIG),
            # иначе c2h-чтение mailbox может застрять за «хвостом» записи.
            for _ in range(500):
                if not runner.state()["active"]:
                    break
                time.sleep(0.001)
            # FIX-барьер WBDR (2026-10-23): провести одно завершённое чтение другой
            # DDR-ячейки до целевого, чтобы дренировать async-FIFO конвертера и
            # разорвать потенциальную write->read гонку на общем MIG-пути.
            try:
                dev.read_dma((DATA_OFF + 0x10) & 0xFFFFFFFF, 8)
            except Exception:
                pass
            mb = CompletionMailbox(dev, base_addr=MBOX_OFF)
            lsw = mb.read_status(timeout_ms=5000, expected=0)
            if (lsw & 0xFF) != 0:
                print("  abort LSW=%#x" % lsw, runner.diagnose()); dev.close(); return 1
            # читаем H (B*H) и OUT (B*O)
            hraw = np.frombuffer(dev.read_dma(H_OFF, B*H*8), dtype="<u8")[:curB*H]
            oraw = dev.read_dma(OUT_OFF, B*O*8)[:curB*O*8]
            h_pre = np.array([dec48(v & 0xFFFFFFFFFFFF) for v in hraw], np.float32).reshape(curB, H)
            o = np.array([dec48(struct.unpack("<Q", oraw[o*8:o*8+8])[0] & 0xFFFFFFFFFFFF) for o in range(curB*O)], np.float32).reshape(curB, O)
            a_out = sigmoid(h_pre)          # скрытые активации
            pred = o[:, 0]                  # линейный выход
            err = pred - ys[:, 0]
            dev.write_dma(OUT_OFF, b"\x00" * (B*O*8))   # очистка out (необязательно)
            right = (err[:, None] * W2[0]) * (a_out * (1.0 - a_out))   # (curB,H)
            W2[0] -= a.lr * (err @ a_out) / curB
            W1 -= a.lr * (right.T @ xs) / curB
            dev.write_dma(W1_OFF, pack(W1.ravel()))
            dev.write_dma(W2_OFF, pack(W2.ravel()))
            tot += float(np.mean(err**2))
        print(f"  ep {ep}: MSE={tot/n_batches:.6f}", flush=True)
    dt = time.monotonic() - t0
    # инференс через тот же батчевый прогон (eval) - по батчам, как в обучении
    pred_all = np.zeros(len(X), np.float32)
    for i in range(n_batches):
        xs = X[i*B:(i+1)*B]; curB = xs.shape[0]
        dev.write_dma(DATA_OFF, pack(xs.ravel()))
        if curB < B:
            dev.write_dma(DATA_OFF + curB*F*8, pack(np.zeros((B-curB, F), np.float32).ravel()))
        runner._reg_w(runner.DP_DATA_BASE, (DDR3_BASE+DATA_OFF)&0xFFFFFFFF)
        runner._reg_w(runner.DP_CTRL, (2 << 16) | 1)
        for _ in range(500):
            if not runner.state()["active"]: break
            time.sleep(0.001)
        try: dev.read_dma((DATA_OFF + 0x10) & 0xFFFFFFFF, 8)
        except Exception: pass
        mb = CompletionMailbox(dev, base_addr=MBOX_OFF); lsw = mb.read_status(timeout_ms=5000, expected=0)
        oraw = dev.read_dma(OUT_OFF, B*O*8)[:curB*O*8]
        pred_all[i*B:i*B+curB] = [dec48(struct.unpack("<Q", oraw[o*8:o*8+8])[0] & 0xFFFFFFFFFFFF) for o in range(curB*O)]
    rmse = float(np.sqrt(np.mean((pred_all - y.ravel())**2)))
    print(f"train {a.epochs} ep, {len(X)} samples, {dt:.1f} s ({dt/len(X)*1e3:.2f} ms/sample/epoch); infer RMSE={rmse:.5f}")
    dev.close(); return 0

if __name__ == "__main__":
    sys.exit(main())