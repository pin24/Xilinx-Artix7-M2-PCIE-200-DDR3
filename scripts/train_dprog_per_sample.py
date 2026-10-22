#!/usr/bin/env python3
"""train_dprog_per_sample.py — per-sample device_prog-тренировка MLP (демо).

Показывает, что обучение можно выполнить программно на устройстве (device_prog):
host отправляет один сэмпл + веса в DDR3 один раз на шаг, device_prog сам исполняет
GEMM слоёв (unit per layer) и возвращает активации через completion-mailbox; host
считает градиент (сигмоид/производную) и перезаписывает веса, потом повторный GO.

Ограничение ISA (важно): юнит device_prog = одно-векторная GEMM
(n_out = ширила слоя, НЕ батч; один входной вектор). Батчевый GEMM в текущем RTL
не выразим — для батча нужна RTL-доработка (батч-цикл / per-unit data-offset).
ReLU/bias/активация выполняются на хосте.

Запуск:  python scripts\\train_dprog_per_sample.py
Riseработает на плате (DEVPROG_EN=1), не на эмуляции.
"""

import os
import struct
import sys
import time

REPO = r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3"
for p in (REPO, os.path.join(REPO, "pytorch_layer"), os.path.join(REPO, "data"),
          os.path.join(REPO, "ternary_sw")):
    if p not in sys.path:
        sys.path.insert(0, p)

import numpy as np
from block.tfloat48 import TFloat
from xdma_driver import DeviceProgRunner, CompletionMailbox, REG_BASE, DDR3_BASE
from test_dma_win import XdmaWinDma
from device_isa import _tf_to_bits48, dot_ref_raw
from nn_audio_common import make_analytic_batch

# ---------------------------------------------------------------------------
# Параметры (модель 2 -> H -> 1, по датасету data/nn_audio_common)
# ---------------------------------------------------------------------------
F = 2          # features (norm_freq, phase_frac)
H = 16         # hidden
O = 1          # output (линейная регрессия аудио-сэмпла)
SAMPLES = 80   # пар из make_analytic_batch
EPOCHS = 40
LR = 0.3
SEED = 3

# Регионы DDR3 (смещения; полный адрес = DDR3_BASE + off)
DATA_OFF  = 0x00B0_0000   # входной сэмпл (features * 8)
W1_OFF    = 0x00B1_0000   # веса слоя 1 (H*F * 8)
W2_OFF    = 0x00B2_0000   # веса слоя 2 (O*H * 8)
H_OFF     = 0x00A2_0000   # pre-activation скрытого слоя (H*8)
OUT_OFF   = 0x00A3_0000   # pre-activation выхода (O*8)
MBOX_OFF  = 0x0012_0000


def tf(v):
    return _tf_to_bits48(TFloat.from_float(float(v)))


def dec48(v):
    """48-битное слово (device_isa/_tf_to_bits48 кодировка) -> float."""
    return TFloat(v & ((1 << 40) - 1), (v >> 40) & 0xFF, False).to_float()


def pack_vec(vals):
    """Массив float -> байты TFloat48 (little-endian по 8 Б на элемент)."""
    return b"".join(struct.pack("<Q", tf(v) & 0xFFFFFFFFFFFF) for v in vals)


def make_unit(w_abs, out_abs, n_in, n_out, flags, tag):
    """32-байтный юнит device_prog в бинарном виде (<QQQQ).

    Формат (по RTL device_prog + исправленной фикстуре):
      W0 = w_addr (abs), W1 = out_addr (abs),
      W2 = {n_in[15:0] в битах[63:48], b_addr[47:0]}, W3 = {n_out|pass|flags|tag}.
    """
    w0 = w_abs & 0xFFFFFFFFFFFFFFFF
    w1 = out_abs & 0xFFFFFFFFFFFFFFFF
    w2 = ((n_in & 0xFFFF) << 48) | 0           # b_addr=0 (bias не применяется на плате)
    w3 = (n_out & 0xFFFF) | (1 << 16) | ((flags & 0xFF) << 32) | ((tag & 0xFFFF) << 40)
    return struct.pack("<QQQQ", w0, w1, w2, w3)


def build_program_table(sample_features, w1, w2):
    """Таблица из 2 юнитов: слой1 (data->H), слой2 (H prev->OUT). Возвращает
    (data_bytes, table_bytes) для одного сэмпла."""
    data_bytes = pack_vec(sample_features)
    # обновляем веса в DDR3 (host пишет, device_prog читает по w_addr)
    dev.write_dma(W1_OFF, pack_vec(w1.ravel()))
    dev.write_dma(W2_OFF, pack_vec(w2.ravel()))

    u0 = make_unit(DDR3_BASE + W1_OFF, DDR3_BASE + H_OFF, F, H, flags=0, tag=0x11)   # src=data
    u1 = make_unit(DDR3_BASE + W2_OFF, DDR3_BASE + OUT_OFF, H, O, flags=0x04, tag=0x22)  # src=prev
    table = u0 + u1
    return data_bytes, table


def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


def main():
    global dev
    dev = XdmaWinDma(base=r"\\.\XDMA0dma")
    runner = DeviceProgRunner(dev, num_mac=32, reg_base=REG_BASE)

    rng = np.random.default_rng(SEED)
    # Реальный датасет: фичи аудио (freq, phase) -> предсказание сэмпла (регрессия).
    X, y = make_analytic_batch(SAMPLES, seed=SEED)
    X = np.asarray(X, dtype=np.float32).reshape(-1, F)
    y = np.asarray(y, dtype=np.float32).reshape(-1, 1)

    W1 = rng.normal(0, 0.5, (H, F)).astype(np.float32)
    b1 = np.zeros(H, dtype=np.float32)
    W2 = rng.normal(0, 0.5, (O, H)).astype(np.float32)
    b2 = np.zeros(O, dtype=np.float32)

    # начальные веса -> DDR3 (device_prog читает по w_addr в каждом прогоне)
    dev.write_dma(W1_OFF, pack_vec(W1.ravel()))
    dev.write_dma(W2_OFF, pack_vec(W2.ravel()))

    # заранее переложим входы в DDR (данные сэмпла будем переписывать при run)
    print(f"per-sample device_prog MLP: F={F} H={H} O={O} samples={SAMPLES} epochs={EPOCHS}")

    t0 = time.monotonic()
    for ep in range(1, EPOCHS + 1):
        tot_loss = 0.0
        for i in range(SAMPLES):
            # вход сэмпла -> data_base (device_prog читает data_base всегда)
            data_abs = DDR3_BASE + DATA_OFF
            dev.write_dma(DATA_OFF, pack_vec(X[i]))

            # собрать таблицу (обновлённые веса уже в DDR) и выполнить программу
            table = (make_unit(data_abs, DDR3_BASE + H_OFF, F, H, flags=0, tag=0x11)
                     + make_unit(DDR3_BASE + W2_OFF, DDR3_BASE + OUT_OFF, H, O, flags=0x04, tag=0x22))
            dev.write_dma(0x0013_0000, table)          # table в DDR3 (table_base)

            runner._reg_w(runner.DP_DATA_BASE,  data_abs & 0xFFFFFFFF)
            runner._reg_w(runner.DP_TABLE_BASE, (DDR3_BASE + 0x0013_0000) & 0xFFFFFFFF)
            runner._reg_w(runner.DP_MBOX_BASE,  (DDR3_BASE + MBOX_OFF) & 0xFFFFFFFF)
            runner._reg_w(runner.DP_CTRL, (2 << 16) | 1)   # n_units=2, GO

            mb = CompletionMailbox(dev, base_addr=MBOX_OFF)
            lsw = mb.read_status(timeout_ms=5000, expected=0)
            if (lsw & 0xFF) != 0:
                print(f"  iter {i}: device_prog error, LSW=0x{lsw:X} ({runner.diagnose()})")
                dev.close()
                return 1

# читаем активации: H (H*8) и OUT (O*8) — раздельно (области не смежные)
            h_pre = np.frombuffer(dev.read_dma(H_OFF, H * 8), dtype="<u8")
            out_raw = dev.read_dma(OUT_OFF, O * 8)
            h_arr = np.array([dec48(v & 0xFFFFFFFFFFFF) for v in h_pre], dtype=np.float32)
            o_arr = np.array([dec48(struct.unpack("<Q", out_raw[o*8:o*8+8])[0] & 0xFFFFFFFFFFFF) for o in range(O)], dtype=np.float32)

            a = sigmoid(h_arr)                    # скрытые активации
            pred = o_arr[0]               # линейный выход (регрессия аудио-сэмпла)
            err = pred - y[i, 0]
            tot_loss += err * err

            # градиенты (host-side — дешёвая часть)
            dW2 = err * a
            dh = (err * W2[0]) * (a * (1.0 - a))
            dW1 = np.outer(dh, X[i])

            W2[0] -= LR * dW2
            W1 -= LR * dW1
            b1 -= LR * 0.0  # bias не обучаем в этом демо (не применяется на плате)
            b2 -= LR * 0.0
            # отразить обновлённые веса в DDR3 (device_prog читает их по w_addr)
            dev.write_dma(W1_OFF, pack_vec(W1.ravel()))
            dev.write_dma(W2_OFF, pack_vec(W2.ravel()))

        if ep % 5 == 0 or ep == 1:
            print(f"  ep {ep:3d}  MSE={tot_loss/SAMPLES:.6f}", flush=True)

    dt = time.monotonic() - t0
    print(f"DONE: {EPOCHS} epochs, {SAMPLES} samples, {dt:.1f} s "
          f"({dt/EPOCHS/SAMPLES*1e3:.1f} ms/sample/epoch)")
    dev.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())