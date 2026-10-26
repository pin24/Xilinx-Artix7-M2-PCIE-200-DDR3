import sys, time
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
from test_dma_win import XdmaWinDma
d=XdmaWinDma(base=r"\\.\XDMA0dma")
def rd(off,n):
    try:
        t=time.monotonic(); b=d.read_dma(off,n); return "OK %dB in %.1fms"%(len(b),(time.monotonic()-t)*1e3)
    except Exception as e: return "FAIL %r" % e
print("read 0x00100000 (data):", rd(0x00100000,64))
print("read 0x00000000 (descr):", rd(0x00000000,64))
print("write+read test:", end=" ")
try:
    d.write_dma(0x00200000, b"\x11"*64); print(rd(0x00200000,64))
except Exception as e: print("write FAIL", e)
d.close()
