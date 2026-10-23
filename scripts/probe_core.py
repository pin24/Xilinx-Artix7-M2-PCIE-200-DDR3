"""probe_core.py — быстрая проверка платы: MAGIC/CORE_PARAMS/SCHED/DP.

Не хардкодит конфигурацию: печатает реальные NUM_MAC/ADDERS и PASS по MAGIC.
Опционально можно задать ожидания: --expect-num-mac 32 --expect-adders 4.
"""
import argparse
import sys

sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
from test_dma_win import XdmaWinDma
from xdma_driver import REG_BASE, TdotCore

ap = argparse.ArgumentParser()
ap.add_argument("--expect-num-mac", type=int, default=None)
ap.add_argument("--expect-adders", type=int, default=None)
args = ap.parse_args()

dev = XdmaWinDma(base=r"\\.\XDMA0dma")
core = TdotCore(dev, num_mac=32)

def show(name, off):
    v = core._reg_r(off)
    print(f"{name:16s} @0x{off:02X} = 0x{v:08X} ({v})")
    return v

print("=== tdot probe ===")
magic = show("MAGIC", 0x68)
show("CORE_PARAMS", 0x64)
show("SCHED_CTRL", 0x40)
show("SCHED_RPTR", 0x44)
show("SCHED_WPTR", 0x48)
show("DP_CTRL",   0xE4)

ok = (magic == 0x54444F54)
print("MAGIC_OK (0x54444F54)" if ok else "MAGIC_MISMATCH")
params = core._reg_r(0x64)
nm = params & 0xFF
ad = (params >> 8) & 0xFF
print(f"decoded: NUM_MAC={nm} ADDERS={ad} (CORE_PARAMS=0x{params:08X})")

if args.expect_num_mac is not None:
    if nm != args.expect_num_mac:
        ok = False
        print("NUM_MAC MISMATCH (expected %d)" % args.expect_num_mac)
    else:
        print("NUM_MAC OK (%d)" % nm)
if args.expect_adders is not None:
    if ad != args.expect_adders:
        ok = False
        print("ADDERS MISMATCH (expected %d)" % args.expect_adders)
    else:
        print("ADDERS OK (%d)" % ad)

dev.close()
print("PROBE_RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)