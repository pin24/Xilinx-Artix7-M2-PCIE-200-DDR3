#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bench_dma_serial.py — честный СЕРИЙНЫЙ DMA-бенчмарк (write/read отдельно, один поток).

Методология (агент-ревью):
- write и read измеряются ОТДЕЛЬНЫМИ циклами (не смешиваются);
- размеры 1/2/4/8 MiB; прогревочные прогоны (WARMUP); N повторов;
- 4KB-выровненные непересекающиеся оффсеты в DDR3 (нет bank-артефактов);
- best = max(скорость), avg = median (устойчиво к выбросам ОС);
- без потоков/async (один активный dmaTransaction на движок).

Запуск:  python scripts\\bench_dma_serial.py [--rounds N] [--sizes 1,2,4,8] [--direction both]
"""
import argparse, statistics, sys, time
sys.path.insert(0, "pytorch_layer")

def align_up(x, a):
    return (x + (a - 1)) & ~(a - 1)

def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=None)
    ap.add_argument("--rounds", type=int, default=16)
    ap.add_argument("--sizes", default="1,2,4,8", help="размеры MiB через запятую")
    ap.add_argument("--direction", choices=["write", "read", "both"], default="both")
    args = ap.parse_args(argv)

    if sys.platform.startswith("win"):
        from xdma_driver import XdmaWinUpstream as Dev
        base = args.base or r"\\.\XDMA0dma"
    else:
        from xdma_driver import XdmaLinux as Dev
        base = args.base or "/dev/xdma0"
    dev = Dev(base=base)

    sizes = [int(s) << 20 for s in args.sizes.split(",") if s]
    dirs = ["write", "read"] if args.direction == "both" else [args.direction]

    # прогрев драйвера/страниц
    small = bytes(64 * 1024)
    dev.write_dma(0x01000000, small); dev.read_dma(0x01000000, len(small))

    print(f"=== Серийный DMA-бенчмарк (base={base}, rounds={args.rounds}) ===")
    print(f"{'направ':>7} {'блокMiB':>8} | {'best MB/s':>10} | {'avg MB/s':>10} | {'std MB/s':>9}")
    results = []
    region = 0x01000000
    for direction in dirs:
        region = align_up(region, 4096)
        for size in sizes:
            off = align_up(region, 4096)
            payload = bytes(i & 255 for i in range(size))
            for _ in range(3):  # WARMUP
                if direction == "write":
                    dev.write_dma(off, payload)
                else:
                    dev.read_dma(off, size)
            times = []
            for r in range(args.rounds):
                if direction == "read":
                    payload2 = bytearray(payload)  # инвалидация хоста перед чтением
                    dev.read_dma(off, size)
                    payload = bytes(payload2)
                t0 = time.perf_counter()
                if direction == "write":
                    dev.write_dma(off, payload)
                    dt = time.perf_counter() - t0
                else:
                    dev.read_dma(off, size)
                    dt = time.perf_counter() - t0
                if dt > 0:
                    times.append(size / dt / 1e6)
            best = max(times)
            avg = statistics.median(times)
            stdv = statistics.pstdev(times) if len(times) > 1 else 0.0
            results.append((direction, size, best, avg, stdv))
            print(f"{direction:>7} {size>>20:>7} MiB | {best:10.1f} | {avg:10.1f} | {stdv:9.1f}")
            region = align_up(region + size, 4096)
    write_best = max((r[2] for r in results if r[0] == "write"), default=0)
    read_best = max((r[2] for r in results if r[0] == "read"), default=0)
    print(f"\nИтог: write best ~{write_best:.0f} MB/s, read best ~{read_best:.0f} MB/s "
          f"(потолок серийного пути этого стека)")
    return 0

if __name__ == "__main__":
    sys.exit(main())