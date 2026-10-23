#!/usr/bin/env python3
"""debug_dprog_chain.py — отладка chained-batch (2 юнита src=data + src=prev).

Изолируем: batch=1, маленький известный W1/W2, сверяем пре-активации H и OUT
с host-моделью (прямое умножение в python). Затем batch>1.
"""
import os, struct, sys
import numpy as np
REPO = r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3"
for p in (REPO, os.path.join(REPO, "pytorch_layer"), os.path.join(REPO, "data"),
          os.path.join(REPO, "ternary_sw")):
    if p not in sys.path:
        sys.path.insert(0, p)
from device_isa import _tf_to_bits48
from block.tfloat48 import TFloat
from xdma_driver import DeviceProgRunner, CompletionMailbox, REG_BASE, DDR3_BASE
from test_dma_win import XdmaWinDma

F, H, O = 2, 4, 1
B = int(sys.argv[1]) if len(sys.argv) > 1 else 2
DATA_OFF, W1_OFF, W2_OFF = 0x00B00000, 0x00B10000, 0x00B20000
H_OFF, OUT_OFF = 0x00A20000, 0x00A30000
MBOX_OFF, TABLE_OFF = 0x00120000, 0x00130000

def tf(v): return _tf_to_bits48(TFloat.from_float(float(v)))
def dec48(v): return TFloat(v & ((1<<40)-1), (v>>40)&0xFF, False).to_float()
def pack(vals): return b"".join(struct.pack("<Q", tf(v) & 0xFFFFFFFFFFFF) for v in vals)

data = np.array([[0.5*((i+1)%3)*0.25, -0.25*(i%2)+0.1] for i in range(B)], np.float32)  # B x F
W1 = np.array([[1.0, 0.5], [-0.5, 2.0], [0.25, -1.0], [1.5, 0.75]], np.float32)  # H x F
W2 = np.array([[0.5, 1.0, -0.5, 2.0]], np.float32)                                # O x H

h_gold = data @ W1.T                    # (B,H)
o_gold = h_gold @ W2.T                  # (B,O)
print("B=%d" % B, flush=True)
print("H gold =", h_gold, flush=True)
print("O gold =", o_gold, flush=True)

def unit(w_off, out_off, n_in, n_out, flags, tag, nb):
    return struct.pack("<QQQQ",
                       (DDR3_BASE+w_off)&0xFFFFFFFFFFFFFFFF,
                       (DDR3_BASE+out_off)&0xFFFFFFFFFFFFFFFF,
                       ((n_in & 0xFFFF)<<48) | 0,
                       (n_out&0xFFFF) | (1<<16) | (flags<<32) | (tag<<40) | (nb<<56))

table = unit(W1_OFF, H_OFF, F, H, 0, 0x11, B) + unit(W2_OFF, OUT_OFF, H, O, 0x04, 0x22, B)

dev = XdmaWinDma(base=r"\\.\XDMA0dma")
dev.write_dma(DATA_OFF, pack(data.ravel()))
dev.write_dma(W1_OFF, pack(W1.ravel()))
dev.write_dma(W2_OFF, pack(W2.ravel()))
dev.write_dma(TABLE_OFF, table)

runner = DeviceProgRunner(dev, num_mac=32, reg_base=REG_BASE)
runner._reg_w(runner.DP_DATA_BASE,  (DDR3_BASE+DATA_OFF)&0xFFFFFFFF)
runner._reg_w(runner.DP_TABLE_BASE, (DDR3_BASE+TABLE_OFF)&0xFFFFFFFF)
runner._reg_w(runner.DP_MBOX_BASE,  (DDR3_BASE+MBOX_OFF)&0xFFFFFFFF)
runner._reg_w(runner.DP_CTRL, (2<<16)|1)
mb = CompletionMailbox(dev, base_addr=MBOX_OFF)
lsw = mb.read_status(timeout_ms=5000, expected=0)
print("mailbox LSW=0x%X status=%d" % (lsw, lsw&0xFF), flush=True)

h_raw = np.frombuffer(dev.read_dma(H_OFF, B*H*8), dtype="<u8")
out_raw = dev.read_dma(OUT_OFF, B*O*8)
h_dev = np.array([dec48(v&0xFFFFFFFFFFFF) for v in h_raw], np.float32).reshape(B, H)
o_dev = np.array([dec48(struct.unpack("<Q", out_raw[o*8:o*8+8])[0]&0xFFFFFFFFFFFF) for o in range(B*O)], np.float32).reshape(B, O)
print("H dev  =", h_dev, flush=True)
print("O dev  =", o_dev, flush=True)
print("H err  =", np.abs(h_dev-h_gold).max(), flush=True)
print("O err  =", np.abs(o_dev-o_gold).max(), flush=True)
dev.close()