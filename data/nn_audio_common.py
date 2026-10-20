#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nn_audio_common.py — общие компоненты для задачи «число (частота) -> звук».

Роль FPGA = ВСПОМОГАТЕЛЬНЫЙ УМНОЖИТЕЛЬ: модель живёт в Python (numpy/torch),
а тяжёлые линейные преобразования (matmul / dot-произведения) могут выполняться
на FPGA-акселераторе (tdot) через matmul_w(..., backend='fpga').

Задача: по частоте сгенерировать синусоидальный WAV (5 с, 16 кГц, int16).
Модель — MLP 2->H->1, вход [норм.частота, фаза=f*t/SR mod 1], выход = сэмпл.
"""
import os, glob
import numpy as np

SR = 16000
DURATION = 5.0
N_SAMPLES = int(SR * DURATION)          # 80000
F_MIN, F_MAX = 60.0, 8000.0
HIDDEN = 16
DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "audio_dataset_500_3s")


def norm_freq(f):
    return np.clip((f - F_MIN) / (F_MAX - F_MIN), 0.0, 1.0)

def phase_frac(f, t):
    return ((np.asarray(f, dtype=np.float64) * np.asarray(t, dtype=np.float64) / SR) % 1.0)

def make_feature(f, t):
    return np.array([norm_freq(float(f)), phase_frac(float(f), t)], dtype=np.float32)


def load_dataset(dir=DATA_DIR, max_files=2000):
    import scipy.io.wavfile as wavio
    items = []
    for path in sorted(glob.glob(os.path.join(dir, "*.wav"))):
        sr, data = wavio.read(path)
        base = os.path.basename(path)
        try:
            freq = int(base.split("_")[1].replace("hz", ""))
        except Exception:
            freq = 0
        items.append((freq, np.asarray(data, dtype=np.float32)))
        if max_files and len(items) >= max_files:
            break
    return items

def make_training_batch(items, n_pair, seed=0):
    rng = np.random.default_rng(seed)
    nf = len(items)
    xs = np.zeros((n_pair, 2), dtype=np.float32); ys = np.zeros((n_pair, 1), dtype=np.float32)
    for i in range(n_pair):
        f, samples = items[rng.integers(nf)]
        slen = len(samples)
        if slen == 0:
            continue
        t = int(rng.integers(0, slen))
        xs[i] = make_feature(float(f), t)
        ys[i, 0] = samples[t] / 32767.0
    return xs, ys

def make_analytic_batch(n_pair, seed=0):
    rng = np.random.default_rng(seed)
    xs = np.zeros((n_pair, 2), dtype=np.float32); ys = np.zeros((n_pair, 1), dtype=np.float32)
    for i in range(n_pair):
        f = float(rng.uniform(F_MIN, F_MAX))
        t = float(rng.integers(0, N_SAMPLES))
        xs[i] = make_feature(f, t)
        ys[i, 0] = np.sin(2 * np.pi * f * t / SR)
    return xs, ys


# ---------------------------------------------------------------------------
# Матричный умножитель (роль FPGA = вспомогательный умножитель)
# ---------------------------------------------------------------------------
def _pad16(v):
    v = np.asarray(v, dtype=np.float32).ravel()
    return np.concatenate([v, np.zeros(16 - v.shape[0], dtype=np.float32)])

def mul_chunked(x, w, fb):
    """dot(x,w) длины L>16, разбитый на проходы по 16 («64 = 4x16»)."""
    x = np.asarray(x, dtype=np.float32).ravel()
    w = np.asarray(w, dtype=np.float32).ravel()
    L = x.shape[0]
    acc = 0.0
    for s in range(0, L, 16):
        ax = _pad16(x[s:s + 16])
        aw = _pad16(w[s:s + 16])
        acc += float(np.asarray(
            fb.run_dot(np.array([ax], dtype=np.float32),
                       np.array([aw], dtype=np.float32))[0]).ravel()[0])
    return acc

def matmul_w(X, W, backend, fb=None):
    """X:(B,in) @ W:(in,out) -> (B,out). backend='cpu' (numpy) или 'fpga' (tdot).

    При backend='fpga' каждый выходной нейрон — dot на акселераторе. Если длина
    входного вектора > 16 (напр. 64), dot дробится на проходы по 16 и суммируется —
    это позволяет эмулировать широкие слои на 16-MAC части.""" 
    X = np.asarray(X, dtype=np.float32); W = np.asarray(W, dtype=np.float32)
    B, fin = X.shape
    fout = W.shape[1]
    if backend == "cpu":
        return X @ W
    assert fb is not None, "fpga требует fb"
    n = int(fb.n)
    out = np.zeros((B, fout), dtype=np.float32)
    # Батч через fpga: по каждой выходной нейроне — один вызов на ВСЕ строки
    # (B задач в кольце). По оси in идём чанками по n (long-dot в RTL суммаризует,
    # здесь дробится для нулевой маски).
    # FIX-CONV 2026-10-20: X конвертируется в TFloat48 ОДИН раз на чанк (общая
    # для всех нейронов), а не fout раз — главный оставшийся host-поток убран.
    x_chunks = []
    for co in range(0, fin, n):
        L = min(n, fin - co)
        xb = np.zeros((B, n), dtype=np.float32)
        xb[:, :L] = X[:, co:co + L]
        x_chunks.append(fb._batch_to_bits(xb))
    for o in range(fout):
        wcol = W[:, o]
        acc = np.zeros(B, dtype=np.float32)
        for ci, co in enumerate(range(0, fin, n)):
            L = min(n, fin - co)
            wb = np.zeros(n, dtype=np.float32)
            wb[:L] = wcol[co:co + L]
            # весовая колонка одинакова для всех строк — конвертируем 1 раз
            w_bits = [fb._to_bits_list(wb)] * B
            acc += fb.run_dot_bits(x_chunks[ci], w_bits)
        out[:, o] = acc
    return out


# ---------------------------------------------------------------------------
# Модель 2 -> HIDDEN(relu) -> 1 (линейный выход); веса в matmul-раскладке
# ---------------------------------------------------------------------------
def init_weights(seed=0):
    rng = np.random.default_rng(seed)
    W1 = rng.normal(0, 0.5, (2, HIDDEN)).astype(np.float32)    # (in=2, out=H)
    b1 = np.zeros(HIDDEN, dtype=np.float32)
    W2 = rng.normal(0, 0.5, (HIDDEN, 1)).astype(np.float32)    # (in=H, out=1)
    b2 = np.zeros(1, dtype=np.float32)
    return W1, b1, W2, b2

def forward_batch(X, W1, b1, W2, b2, backend="cpu", fb=None):
    """X:(B,2) -> (B,1). Линейные преобразования — на умножителе (backend)."""
    Z1 = np.maximum(0.0, matmul_w(X, W1, backend, fb) + b1)
    A = matmul_w(Z1, W2, backend, fb) + b2
    return A

def generate_samples(freq, W1, b1, W2, b2, backend="cpu", fb=None):
    t_idx = np.arange(N_SAMPLES)
    X = np.stack([np.full(N_SAMPLES, norm_freq(float(freq))),
                  phase_frac(float(freq), t_idx)], axis=1).astype(np.float32)
    return forward_batch(X, W1, b1, W2, b2, backend=backend, fb=fb).ravel()


def save_model_npz(path, W1, b1, W2, b2, meta=None):
    import json
    np.savez_compressed(path, W1=W1, b1=b1, W2=W2, b2=b2)
    if meta:
        open(path + ".json", "w").write(json.dumps(meta))

def load_model_npz(path):
    z = np.load(path, allow_pickle=True)
    return z["W1"], z["b1"], z["W2"], z["b2"]

def save_wav(path, samples):
    import scipy.io.wavfile as wavio
    pcm = np.clip(samples, -1.0, 1.0) * 32767.0
    wavio.write(path, SR, pcm.astype(np.int16))