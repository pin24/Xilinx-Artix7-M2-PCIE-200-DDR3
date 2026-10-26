import sys, struct, threading, os, time
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3")
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
from test_dma_win import XdmaWinDma

dev = XdmaWinDma(base=r"\\.\XDMA0dma")
OFF = 0x00010000   # свободный DDR offset
res={}
def worker(fn):
    try: res["ok"]=fn()
    except Exception as e: res["ok"]=("ERR:"+repr(e)[:60])

# 1) AXI-Lite (регистры) — известно что жив
def t_reg():
    raw=dev.read(0x40023000+0x68,4); return ("REG_MAGIC="+raw.hex()) if raw else "no"
# 2) H2C write 64B
def t_h2c():
    dev.write_dma(OFF, bytes(range(64))); return "h2c_wr_ok"
# 3) C2H read 64B (после write — если write сработал, read вернёт данные)
def t_c2h():
    raw=dev.read_dma(OFF,64); return "c2h_rd_ok "+raw[:8].hex()

for name,fn in [("reg",t_reg),("h2c_wr",t_h2c),("c2h_rd",t_c2h)]:
    res={}
    t=threading.Thread(target=worker,args=(fn,),daemon=True); t.start(); t.join(12.0)
    if t.is_alive():
        print("%-6s -> HANG (12s)" % name)
    else:
        print("%-6s -> %s" % (name, res.get("ok")))
dev.close()