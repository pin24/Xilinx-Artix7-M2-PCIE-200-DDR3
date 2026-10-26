import sys, struct
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
from test_dma_win import XdmaWinDma
d = XdmaWinDma(base=r"\\.\XDMA0dma")
v = struct.unpack("<I", d.read(0x40023000 + 0x64, 4))[0]
print("CORE_PARAMS(0x64) = 0x%08X" % v)
print("  [7:0]  NUM_MAC = %d" % (v & 0xFF))
print("  [15:8] ADDERS = %d" % ((v >> 8) & 0xFF))
# альтернативный разбор (если порядок перепутан в скриптах)
print("  обратный разбор: ADDERS=%d NUM_MAC=%d" % (v & 0xFF, (v >> 8) & 0xFF))
magic = struct.unpack("<I", d.read(0x40023000 + 0x68, 4))[0]
print("MAGIC = 0x%08X" % magic)
d.close()