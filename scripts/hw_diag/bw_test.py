import sys, time
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
from test_dma_win import XdmaWinDma

# Пропускная способность h2c и c2h на фиксированной прошивке
ITERS = 128
SIZE = 512 * 1024
ADDR = 0x00200000
dev = XdmaWinDma(base=r"\\.\XDMA0dma")
data = bytes(((i * 7) & 0xFF) for i in range(SIZE))
total = SIZE * ITERS

def bw(label, fn):
    t0 = time.monotonic()
    for _ in range(ITERS):
        fn()
    dt = time.monotonic() - t0
    print("%s: %d x %d B = %.2f MB, %.2f s -> %.2f MB/s" % (label, ITERS, SIZE, total/1e6, dt, total/dt/1e6), flush=True)

bw("h2c write", lambda: dev.write_dma(ADDR, data))
bw("c2h read ", lambda: dev.read_dma(ADDR, SIZE))
dev.close()
print("BW_DONE")