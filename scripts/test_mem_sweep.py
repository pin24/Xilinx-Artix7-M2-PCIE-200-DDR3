#!/usr/bin/env python3
"""test_mem_sweep.py — свип параметра --mem по объёму DDR и батчу для обучения на FPGA.

Для каждой комбинации (данные на вход): область DDR, скрытый слой H, батч B —
запускается короткое FPGA-обучение (1 эпоха) и фиксируется: проходит ли оно,
MSE, время/эпоху, занятая DDR-область. Результаты таблицей + итог максим. нагрузки.

Запуск:
  python scripts\\test_mem_sweep.py [--mem 128K 1M 2M 8M] [--hidden 128 512 1024]
                                   [--batch 16 32 64] [--samples 64] [--epochs 1] [--lr 0.01]
"""
import os, sys, time, argparse, itertools
import numpy as np
REPO = r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3"
sys.path.insert(0, REPO)
sys.path.insert(0, os.path.join(REPO, "scripts"))
import bench_fpga_vs_cpu as bm
import train_dprog_batch_mlp as tdm

def main():
    a = argparse.ArgumentParser()
    a.add_argument("--mem", nargs="*", default=["128K", "1M", "2M", "8M"])
    a.add_argument("--hidden", nargs="*", type=int, default=[128, 512, 1024])
    a.add_argument("--batch", nargs="*", type=int, default=[16, 32, 64])
    a.add_argument("--samples", type=int, default=64)
    a.add_argument("--epochs", type=int, default=1)
    a.add_argument("--lr", type=float, default=0.01)
    a.add_argument("--seed", type=int, default=0)
    a = a.parse_args()
    a.use_dataset = True
    X, y, src = bm.load_data(a)
    a.samples = len(X)
    rows = []
    print(f"свип --mem: samples={len(X)} epochs={a.epochs} lr={a.lr}; источник={src}\n")
    print("%-9s %-6s %-6s %-11s %-8s %-9s %-10s" % ("MEM", "H", "B", "H*B*8(Б)", "статус", "мс/эпоха", "MSE"))
    print("-" * 68)
    for ms in a.mem:
        mem, clamped = bm.clamp_mem(bm.parse_mem(ms))
        for H, B in itertools.product(a.hidden, a.batch):
            try:
                off, need = bm.layout(tdm.F, H, 1, B, mem)
            except RuntimeError as e:
                rows.append((ms, H, B, "-", "нет-области", "-", "-"))
                print("%-9s %-6d %-6d %-11s %-8s %-9s %-10s" % (ms, H, B, "-", "нет-области", "-", "-"))
                continue
            rng = np.random.default_rng(a.seed)
            W1 = rng.normal(0, 0.5, (H, tdm.F)).astype(np.float32)
            W2 = rng.normal(0, 0.5, (1, H)).astype(np.float32)
            t0 = time.monotonic()
            try:
                ep, mse, T = bm.run_fpga(tdm.F, H, 1, off, X, y,
                                         W1, W2, B, a.epochs, a.lr)
                dt = (time.monotonic() - t0)
                rows.append((ms, H, B, need, "OK", f"{np.mean(ep):.0f}", f"{mse[-1]:.3f}"))
                print("%-9s %-6d %-6d %-11d %-8s %-9.0f %-10.3f" %
                      (ms, H, B, need, "OK", np.mean(ep), mse[-1]))
            except Exception as e:
                msg = type(e).__name__
                rows.append((ms, H, B, need, "FAIL", "-", f"{msg[:12]}"))
                print("%-9s %-6d %-6d %-11d %-8s %-9s %-10s" % (ms, H, B, need, "FAIL", "-", msg[:12]))
    # итог: максимальная прошедшая нагрузка
    ok = [r for r in rows if r[4] == "OK"]
    if ok:
        best = max(ok, key=lambda r: r[2] * r[1])   # макс H*B (пар на батч)
        print("\nМАКС. прошедшая нагрузка: MEM=%s H=%d B=%d (H*B=%d пар/эпоха), MSE=%s, мс/эпоха=%s" %
              (best[0], best[1], best[2], best[1]*best[2], best[6], best[5]))
        print(f"Потолок движка на 32/4: H<=MAX_N_TOTAL=MAX_PASSES(32)*NUM_MAC(32)=1024; "
              f"область <=85% DDR = {bm.DDR_MAX85} Б")
    else:
        print("\nНЕ прошла ни одна конфигурация.")
    return 0

if __name__ == "__main__":
    sys.exit(main())