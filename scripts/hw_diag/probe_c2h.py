import sys, os, signal, time, threading
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3")
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
from test_dma_win import XdmaWinDma

dev = XdmaWinDma(base=r"\\.\XDMA0dma")
MBOX_OFF = 0x00120000
result = {}
def probe_c2h():
    try:
        raw = dev.read_dma(MBOX_OFF, 8)   # c2h read of one DDR word at offset
        result["val"] = raw.hex()
        result["ok"] = True
    except Exception as e:
        result["ok"] = False; result["err"] = repr(e)
t = threading.Thread(target=probe_c2h, daemon=True)
t.start()
t.join(15.0)
if t.is_alive():
    print("C2H HANG: read_dma(0x%08X,8) did not return in 15s -> XDMA data-path wedged" % MBOX_OFF)
    dev.close()
    os._exit(1)
print("C2H OK:", result)
dev.close()