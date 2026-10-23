#!/usr/bin/env python3
"""test_dprog_batch_board.py — проверка батчевого GEMM device_prog на плате.

Юнит: n_in=2, n_out=2, pass=1, src=data, n_batch=2, tag. Данные = 2 строки по 2
фичи; веса = 2 строки (общие на батчи). Ожидаем out[b,j] = sum_k data[b,k]*W[j,k]
и сверяем с host-моделью (TFloat48 кодировка device_isa). Запускать на плате.
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

B, N_IN, N_OUT = 2, 2, 2
DATA_OFF, W_OFF, RES_OFF, MBOX_OFF = 0x00B00000, 0x00B09000, 0x00A20000, 0x00120000
TABLE_OFF = 0x00130000

def tf(v): return _tf_to_bits48(TFloat.from_float(float(v)))
def dec48(v): return TFloat(v & ((1 << 40) - 1), (v >> 40) & 0xFF, False).to_float()
def pack(vals): return b"".join(struct.pack("<Q", tf(v) & 0xFFFFFFFFFFFF) for v in vals)

data = np.array([[0.5, -0.25], [1.0, 0.5]], dtype=np.float32)
W    = np.array([[1.0, 2.0], [-0.5, 8.0]], dtype=np.float32)   # N_OUT x N_IN

# ожидаемое: out[b,j] = sum_k data[b,k]*W[j,k]
expected = data @ W.T   # (B, N_OUT)
print("expected =", expected, flush=True)

# unit: n_batch в uw[3][63:56]
w0 = (DDR3_BASE + W_OFF) & 0xFFFFFFFFFFFFFFFF
w1 = (DDR3_BASE + RES_OFF) & 0xFFFFFFFFFFFFFFFF
w2 = ((N_IN & 0xFFFF) << 48) | 0
w3 = (N_OUT & 0xFFFF) | (1 << 16) | (0x33 << 40) | (B << 56)
table = struct.pack("<QQQQ", w0, w1, w2, w3)

dev = XdmaWinDma(base=r"\\.\XDMA0dma")
dev.write_dma(DATA_OFF, pack(data.ravel()))
dev.write_dma(W_OFF, pack(W.ravel()))
dev.write_dma(TABLE_OFF, table)

runner = DeviceProgRunner(dev, num_mac=4, reg_base=REG_BASE)
runner._reg_w(runner.DP_DATA_BASE,  (DDR3_BASE + DATA_OFF) & 0xFFFFFFFF)
runner._reg_w(runner.DP_TABLE_BASE, (DDR3_BASE + TABLE_OFF) & 0xFFFFFFFF)
runner._reg_w(runner.DP_MBOX_BASE,  (DDR3_BASE + MBOX_OFF) & 0xFFFFFFFF)
runner._reg_w(runner.DP_CTRL, (1 << 16) | 1)
mb = CompletionMailbox(dev, base_addr=MBOX_OFF)
lsw = mb.read_status(timeout_ms=5000, expected=0)
st = lsw & 0xFF
print("mailbox status =", st, flush=True)
if st != 0:
    print("RESULT: FAIL (abort)", runner.diagnose(), flush=True); dev.close(); sys.exit(1)
raw = dev.read_dma(RES_OFF, B * N_OUT * 8)
got = np.array([dec48(struct.unpack("<Q", raw[j*8:j*8+8])[0] & 0xFFFFFFFFFFFF) for j in range(B*N_OUT)], dtype=np.float32).reshape(B, N_OUT)
print("got      =", got, flush=True)
err = np.abs(got - expected).max()
print("max|err| =", err, flush=True)
dev.close()
print("RESULT:", "PASS" if err < 1e-3 else "FAIL", flush=True)
sys.exit(0 if err < 1e-3 else 1)