#!/usr/bin/env python3
"""test_dprog_single_dot.py — один 4-элементный dot через device_prog (NUM_MAC=64, ADDERS=1).

data=[0.5,-0.25,1.0,0.5]; weights=[1,2,-0.5,8] -> dot=0.5*1-0.25*2+1*(-0.5)+0.5*8 = 3.5.
Проверяем: плата даёт 3.5? Если да — RTL+device_prog корректны, 0.31 был моей раскладкой теста.
"""
import os, struct, sys
import numpy as np
REPO = r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3"
for p in (REPO, os.path.join(REPO,"pytorch_layer"), os.path.join(REPO,"data"), os.path.join(REPO,"ternary_sw")):
    if p not in sys.path: sys.path.insert(0, p)
from device_isa import _tf_to_bits48
from block.tfloat48 import TFloat
from xdma_driver import DeviceProgRunner, CompletionMailbox, REG_BASE, DDR3_BASE
from test_dma_win import XdmaWinDma

N_IN, N_OUT = 4, 1
DATA_OFF, W_OFF, RES_OFF = 0x00B00000, 0x00B10000, 0x00A20000
MBOX_OFF, TABLE_OFF = 0x00120000, 0x00130000

def tf(v): return _tf_to_bits48(TFloat.from_float(float(v)))
def dec48(v): return TFloat(v & ((1<<40)-1), (v>>40)&0xFF, False).to_float()
def pack(vals): return b"".join(struct.pack("<Q", tf(v) & 0xFFFFFFFFFFFF) for v in vals)

data  = [0.5, -0.25, 1.0, 0.5]
w     = [1.0, 2.0, -0.5, 8.0]
expected = sum(x*y for x,y in zip(data,w))   # = 3.5
print("expected dot =", expected, flush=True)

unit = struct.pack("<QQQQ",
                   (DDR3_BASE+W_OFF)&0xFFFFFFFFFFFFFFFF,
                   (DDR3_BASE+RES_OFF)&0xFFFFFFFFFFFFFFFF,
                   ((N_IN & 0xFFFF)<<48) | 0,
                   (N_OUT&0xFFFF) | (1<<16) | (0x33<<40) | (1<<56))   # n_batch=1

dev = XdmaWinDma(base=r"\\.\XDMA0dma")
dev.write_dma(DATA_OFF, pack(data)); dev.write_dma(W_OFF, pack(w)); dev.write_dma(TABLE_OFF, unit)
run = DeviceProgRunner(dev, num_mac=64, reg_base=REG_BASE)
run._reg_w(run.DP_DATA_BASE,  (DDR3_BASE+DATA_OFF)&0xFFFFFFFF)
run._reg_w(run.DP_TABLE_BASE, (DDR3_BASE+TABLE_OFF)&0xFFFFFFFF)
run._reg_w(run.DP_MBOX_BASE,  (DDR3_BASE+MBOX_OFF)&0xFFFFFFFF)
run._reg_w(run.DP_CTRL, (1<<16)|1)
mb = CompletionMailbox(dev, base_addr=MBOX_OFF)
lsw = mb.read_status(timeout_ms=5000, expected=0)
print("mailbox status=%d" % (lsw&0xFF), flush=True)
out_raw = dev.read_dma(RES_OFF, N_OUT*8)
got = dec48(struct.unpack("<Q", out_raw[:8])[0] & 0xFFFFFFFFFFFF)
print("got dot =", got, flush=True)
print("RESULT:", "PASS" if abs(got-expected)<1e-3 else "FAIL", flush=True)
dev.close()
sys.exit(0 if abs(got-expected)<1e-3 else 1)