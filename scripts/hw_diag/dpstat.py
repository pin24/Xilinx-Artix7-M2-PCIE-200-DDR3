import sys
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
from xdma_driver import REG_BASE
from test_dma_win import XdmaWinDma
d=XdmaWinDma(base=r"\\.\XDMA0dma")
def rr(o): return int.from_bytes(d.read(REG_BASE+o,4),"little")
print("DP_STAT(0xF4)=0x%08X" % rr(0xF4))
print("RD_TO(0xF8)=%d  WR_TO(0xFC)=%d" % (rr(0xF8), rr(0xFC)))
d.close()
