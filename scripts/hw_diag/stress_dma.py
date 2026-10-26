import sys, time
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
from test_dma_win import XdmaWinDma

N = 60
SIZE = 512 * 1024
ADDR = 0x00200000
dev = XdmaWinDma(base=r"\\.\XDMA0dma")
data = bytes(((i * 7) & 0xFF) for i in range(SIZE))
fails = 0
t0 = time.monotonic()
for i in range(1, N + 1):
    try:
        dev.write_dma(ADDR, data)
        rb = dev.read_dma(ADDR, SIZE)
        ok = (rb == data)
        print("iter %3d: 512KiB round-trip match=%s" % (i, ok), flush=True)
        if not ok:
            fails += 1
    except Exception as e:
        fails += 1
        print("iter %3d: FAIL %r" % (i, e), flush=True)
        break
dt = time.monotonic() - t0
print("STRESS_DONE iters=%d fails=%d time=%.1fs" % (i, fails, dt))
dev.close()
sys.exit(1 if fails else 0)