import sys, struct, threading, os, time
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3")
sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
from test_dma_win import XdmaWinDma

dev = XdmaWinDma(base=r"\\.\XDMA0dma")
# AXI-Lite путь (жив): GPIO base 0x40020000 (xdma_axi_lite_smc M00)
GPIO = 0x40020000
# Ищем, в каком смещении тёплый channel2 (MIG status). Пробуем несколько кандидатов.
res = {}
def rd(addr):
    try:
        raw = dev.read(addr, 4) if False else None
    except Exception as e:
        pass
    try:
        raw = dev.read(addr, 4)
        return raw.hex() if raw else None
    except Exception as e:
        return "ERR:"+repr(e)[:40]

# Вообще — регистры tdot (M03) читаются чётко. Проверим, что lite-smc жив
for off, name in [(0x40023000,"TDOT_MAGIC"),(0x40020000,"GPIO_CH1_DATA"),(0x40020004,"GPIO_CH1_TRI"),(0x40020008,"GPIO_CH2_DATA"),(0x4002000c,"GPIO_CH2_TRI"),(0x40020018,"GIER"),(0x40020010,"IPISR")]:
    r = rd(off)
    print("%-14s 0x%08x -> %s" % (name, off, r))
dev.close()