import sys, threading, random
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3")
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
from test_dma_win import XdmaWinDma
random.seed(7)
dev = XdmaWinDma(base=r"\\.\XDMA0dma")
N = 256*1024      # 256 KiB передача
OFF = 0x00400000  # свободный DDR offset
data = bytes(random.getrandbits(8) for _ in range(N))
res={}
def do_write():
    dev.write_dma(OFF, data); res["w"]="ok"
def do_read():
    got = dev.read_dma(OFF, N); res["r"]="ok"; res["eq"]=(got==data)
t=threading.Thread(target=do_write,daemon=True); t.start(); t.join(60.0)
if t.is_alive(): print("WRITE HANG 60s"); dev.close(); raise SystemExit(1)
print("h2c write 256KiB: %s (ok=%r)" % (res.get("w"), res.get("w")=="ok"))
t=threading.Thread(target=do_read,daemon=True); t.start(); t.join(60.0)
if t.is_alive(): print("READ HANG"); dev.close(); raise SystemExit(1)
print("c2h read 256KiB: ok, bit-exact match=%r" % res.get("eq"))
dev.close()
print("DDR STRESS: ", "PASS" if res.get("eq") else "FAIL")