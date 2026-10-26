import sys, threading, os
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3")
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
from test_dma_win import XdmaWinDma

mode = sys.argv[1]  # 'h2c' or 'c2h'
OFF = 0x00010000
dev = XdmaWinDma(base=r"\\.\XDMA0dma")
res={}
def worker():
    if mode=="h2c":
        dev.write_dma(OFF, bytes(range(64))); res["ok"]="h2c_ok"
    else:
        raw=dev.read_dma(OFF,64); res["ok"]="c2h_ok "+raw[:8].hex()
t=threading.Thread(target=worker,daemon=True); t.start(); t.join(12.0)
if t.is_alive():
    print("MODE=%s -> HANG (12s)" % mode)
else:
    print("MODE=%s -> %s" % (mode, res.get("ok")))
dev.close()