#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nn_audio_infer_cpu.py — генерация аудио из числа (частоты) на CPU.

Использование:
    python data/nn_audio_infer_cpu.py --freq 440
    python data/nn_audio_infer_cpu.py --freq 1000 --model audio_model_cpu.npz --out out_1000.wav
    python data/nn_audio_infer_cpu.py --freq 440 --bench       # замерить скорость/сэмпл

Генерирует 5-секундный синусоидальный WAV (16 кГц, int16) для заданной частоты.
Для сравнения скорости с FPGA запустите то же самое с --bench.
"""
import os, sys, time, argparse
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nn_audio_common as AC
from nn_audio_common import (load_model_npz, generate_samples, save_wav,
                             N_SAMPLES, SR, DURATION, norm_freq)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hidden", type=int, default=AC.HIDDEN, help="ширина скрытого слоя (16/32/64; >16 = чанки по 16 MAC)")
    ap.add_argument("--freq", type=float, default=440.0)
    ap.add_argument("--model", default="audio_model_cpu.npz")
    ap.add_argument("--out", default=None)
    ap.add_argument("--bench", action="store_true", help="замерить время на сэмпл")
    args = ap.parse_args()
    AC.HIDDEN = args.hidden   # ширина скрытого слоя (64 = чанки по 16 MAC)

    model = os.path.join(os.path.dirname(os.path.abspath(__file__)), args.model)
    W1, b1, W2, b2 = load_model_npz(model)
    print(f"Модель: {model}  |  генерация {DURATION:.0f}с ({N_SAMPLES} сэмплов) на частоте {args.freq:.1f} Гц")

    t0 = time.time()
    s = generate_samples(args.freq, W1, b1, W2, b2, backend="cpu")
    dt = time.time() - t0
    print(f"Сгенерировано {s.shape[0]} сэмплов за {dt*1000:.1f} мс  "
          f"({dt/s.shape[0]*1e6:.1f} us/сэмпл, {s.shape[0]/dt/1e3:.1f} ksps)")

    # пик/оценка частоты: число пересечений нуля
    zc = int(np.sum(np.diff(np.signbit(s)).astype(np.int32))); est = zc / (2 * DURATION)
    print(f"  оценка частоты по пересечениям нуля: ~{est:.1f} Гц (задано {args.freq})")

    out = args.out or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   f"gen_{int(args.freq)}hz_cpu.wav")
    save_wav(out, s)
    print(f"WAV сохранён: {out}")


if __name__ == "__main__":
    main()