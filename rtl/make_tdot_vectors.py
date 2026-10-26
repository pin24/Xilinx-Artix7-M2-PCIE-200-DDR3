#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_tdot_vectors.py — формирует vectors.dat / weights.dat для tb_tdot_dot_hang.sv.

Использует ТОЛЬКО реальные float32-значения весов модели (model/checkpoints/vits.pt),
конвертирует их в TFloat48 той же функцией, что хост кормит движок
(FpgaBackend._to_bits48 / TFloat.from_float), и пакует по NUM_MAC слов на вектор.
Никаких синтетических распределений — только фактические данные модели,
заполненные до нужного числа векторов тилированием реальных весов.

Формат файла (для tb_tdot_dot_hang.sv):
  каждая строка = NUM_MAC слов TFloat48, hex, без разделителей/пробелов
  (48*NUM_MAC бит = NUM_MAC*12 hex-символов); старший бит первый [47:0]={e,m}.

Запуск (из корня проекта):
  python rtl\\make_tdot_vectors.py [--vectors 6000]
"""
import os, sys, argparse
import numpy as np
import torch

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pytorch_layer"))
from fpga_backend import FpgaBackend  # noqa: E402

NUM_MAC = 32


def _bits(fa):
    """float32 -> 48-бит TFloat48 (как на хосте)."""
    from block.tfloat48 import TFloat
    return FpgaBackend._to_bits48(TFloat.from_float(float(fa)))


def _pack_row(words48, f):
    f.write("".join(f"{w:012X}" for w in words48) + "\n")   # 12 hex = 48 бит


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vectors", type=int, default=6000, help="желаемое число векторов")
    ap.add_argument("--ckpt", default="model/checkpoints/vits.pt")
    a = ap.parse_args()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    ck_path = os.path.join(root, a.ckpt)
    if not os.path.exists(ck_path):
        sys.exit(f"чекпойнт не найден: {ck_path} — реальные веса обязательны")
    ck = torch.load(ck_path, map_location="cpu")
    sd = ck["model"]
    real = np.concatenate([sd[k].float().detach().numpy().reshape(-1) for k in sd]).astype(np.float32)
    print(f"реальные веса: {real.size} значений "
          f"(min={real.min():.3e} max={real.max():.3e} mean={real.mean():.3e})")
    if real.size < NUM_MAC:
        sys.exit("меньше NUM_MAC реальных значений — невозможно собрать вектор")

    full = np.resize(real, (a.vectors * NUM_MAC,))        # тилирование реальных весов

    # 32-word-packed файлы для tb_tdot_dot_hang.sv + 64-бит word-файлы для tb_tdot_sched_hang.sv
    with open(os.path.join(root, "vectors.dat"), "w") as fd, \
         open(os.path.join(root, "weights.dat"), "w") as fw, \
         open(os.path.join(root, "vec64.dat"), "w") as fd64, \
         open(os.path.join(root, "w64.dat"), "w") as fw64:
        for v in range(a.vectors):
            data = full[v * NUM_MAC:(v + 1) * NUM_MAC]
            # веса — те же реальные данные (dot = сумма квадратов, заведомо ненулевая)
            wts = np.copy(data)
            bd = [_bits(x) for x in data]
            bw = [_bits(x) for x in wts]
            _pack_row(bd, fd)
            _pack_row(bw, fw)
            for w in bd:
                fd64.write(f"{w:016X}\n")                 # 64-бит, младшие 48 бит = TFloat48
            for w in bw:
                fw64.write(f"{w:016X}\n")
    print(f"записал {a.vectors} векторов по {NUM_MAC} слов (только реальные веса): "
          f"vectors.dat/weights.dat (32-word) и vec64.dat/w64.dat (64-bit word)")


if __name__ == "__main__":
    main()