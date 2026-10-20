#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nn_audio_infer_fpga.py — генерация аудио, где РОЛЬ FPGA = вспомогательный умножитель.

Модель живёт в Python; линейные преобразования каждого сэмпла считает FPGA (tdot).
Полная 5-с генерация = 80000 сэмплов x 2 слоя x (по числу нейронов dot-вызовов) через
PCIe — медленно (минуты). Для замера скорости ограничьте --limit.

Использование:
    python data/nn_audio_infer_fpga.py --freq 440
    python data/nn_audio_infer_fpga.py --freq 440 --limit 200 --bench
"""
import os, sys, time, argparse
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pytorch_layer"))
import nn_audio_common as AC
from nn_audio_common import (load_model_npz, save_wav, N_SAMPLES, SR, DURATION,
                             HIDDEN, matmul_w, forward_batch)

def make_fpga_backend():
    from fpga_backend import FpgaBackend
    from xdma_driver import XdmaWinUpstream, TdotCore
    dev = XdmaWinUpstream(base=r"\\.\XDMA0dma")
    TdotCore(dev, num_mac=16).set_sched(False)   # legacy-GO path active
    return FpgaBackend(mode="fpga", n=16, device=dev, num_mac=16)   # n=16: chank dot

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hidden", type=int, default=AC.HIDDEN, help="ширина скрытого слоя (16/32/64; >16 = чанки по 16 MAC)")
    ap.add_argument("--freq", type=float, default=440.0)
    ap.add_argument("--model", default="audio_model_fpga.npz")
    ap.add_argument("--out", default=None)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--bench", action="store_true")
    args = ap.parse_args()
    AC.HIDDEN = args.hidden   # ширина скрытого слоя (64 = чанки по 16 MAC)
    HIDDEN = args.hidden                    # синхроним локальную копию (обход capture-at-import)

    model = os.path.join(os.path.dirname(os.path.abspath(__file__)), args.model)
    W1, b1, W2, b2 = load_model_npz(model)
    # SANITY: ширина модели определяется ФОРМОЙ W1 в npz, а не --hidden/метаданными
    # json (известный разнобой: audio_model_h64.npz.json помечен hidden=16 при
    # W1=(2,64)). Вычисление идёт по фактическим shapes (mul_chunked режет по 16),
    # --hidden влияет только на дефолт обучения; предупреждаем при расхождении.
    w1_hidden = int(np.asarray(W1).shape[1])
    if w1_hidden != int(args.hidden):
        print(f"  WARN: W1.shape[1]={w1_hidden} != --hidden={args.hidden}; "
              f"вычисление идёт по форме модели ({w1_hidden})")
    fb = make_fpga_backend()
    n = args.limit if args.limit > 0 else N_SAMPLES
    print(f"Модель: {model} | генерация через FPGA-умножитель, {n} сэмплов, частота {args.freq:.1f} Гц")

    from nn_audio_common import norm_freq, phase_frac
    X = np.stack([np.full(n, norm_freq(float(args.freq))),
                  phase_frac(float(args.freq), np.arange(n))], axis=1).astype(np.float32)
    # по умножителю идём по батчам (память/скорость): здесь батч в 1 сэмпл (ускоритель batch=1)
    t0 = time.time()
    outs = np.zeros((n, 1), dtype=np.float32)
    for i in range(n):
        outs[i] = forward_batch(X[i:i+1], W1, b1, W2, b2, backend="fpga", fb=fb)
    dt = time.time() - t0
    if args.bench or args.limit > 0:
        print(f"time={dt:.1f}с  {dt/n*1000:.2f} мс/сэмпл  {n/dt:.1f} сэмпл/с")
    sfull = outs.ravel()
    if args.limit > 0:
        sfull = np.concatenate([outs.ravel(), np.zeros(N_SAMPLES - n, dtype=np.float32)])
        print(f"  (только первые {n} сэмплов на FPGA; остальные не заполнены)")
    out = args.out or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   f"gen_{int(args.freq)}hz_fpga.wav")
    save_wav(out, sfull)
    print(f"WAV сохранён: {out}")

if __name__ == "__main__":
    main()