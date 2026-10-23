#!/usr/bin/env python3
"""clear_ddr.py — занулить всё окно DDR3 (256 МБ) на плате и проверить чтением.

Безопасно только при простой плате (движок idle). Регионы (дескрипторы,
completion, mailbox, данные/веса device_prog, result) будут перезаписаны при
следующем использовании. Пишет через защищённый _chk_ddr (в окне).
"""
import sys, time
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
from test_dma_win import XdmaWinDma, DDR_SIZE

CHUNK = 1 << 20
d = XdmaWinDma(base=r"\\.\XDMA0dma")
z = b"\x00" * CHUNK
t0 = time.monotonic()
done = 0
for off in range(0, DDR_SIZE, CHUNK):
    d.write_dma(off, z)
    done += CHUNK
    if done % (32 << 20) == 0:
        print("  cleared %d MB" % (done >> 20), flush=True)
dt = time.monotonic() - t0
print("clear done: %d MB in %.1f s (%.1f MB/s)" % (DDR_SIZE >> 20, dt, DDR_SIZE / dt / 1e6))

# проверка чтением нескольких точек
bad = 0
for off in (0x000000, 0x0010_0000, 0x0011_0000, 0x00B0_0000, 0x00FF_F000, DDR_SIZE - 64):
    if any(d.read_dma(off, 64)):
        bad += 1
        print("  NOT-CLEARED at 0x%X" % off)
print("verify:", "OK (все точки нулевые)" if bad == 0 else "FAIL (%d точек не в нуле)" % bad)
d.close()
sys.exit(0 if bad == 0 else 1)