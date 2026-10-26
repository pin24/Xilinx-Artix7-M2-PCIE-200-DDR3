#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""infer.py — текст->аудио через обученную VITS-модель (без BERT) встроенным генератором.

Запуск: python model\\infer.py --text "Мне надо выспаться." [--ckpt model/checkpoints/vits.pt]
        [--out out.wav] [--d 192] [--speed 1.0]
Цепочка: текст -> char-токены -> TextEncoder -> duration -> mel (80) -> Generator -> wav.
"""
import os, sys, json, argparse
import numpy as np
import torch
import torch.nn.functional as F
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vits import Vits
from data import load_tokenizer_from, SPECIAL

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True)
    ap.add_argument("--ckpt", default="model/checkpoints/vits.pt")
    ap.add_argument("--out", default="model/samples/out.wav")
    ap.add_argument("--d", type=int, default=192)
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--gamma", type=float, default=277.0,
                    help="кадровое соотношение датасета: семплов wav на 1 кадр mel")
    ap.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    a = ap.parse_args()

    man = json.load(open("model/data/manifest.json", encoding="utf-8"))
    stoi, V = load_tokenizer_from(man["tokenizer"])
    ck = torch.load(a.ckpt, map_location=a.device if a.device != "cpu" else "cpu")
    cfg = ck.get("vits_config", {"vocab": V, "d": a.d, "n_mels": 80,
                                 "vd": 128, "ken_layers": 4, "voc_layers": 6, "hop": 256,
                                 "gamma": a.gamma})
    gamma = cfg.get("gamma", a.gamma)
    model = Vits(cfg["vocab"], d=cfg.get("d", a.d), n_mels=80,
                 vd=cfg.get("vd", 128), ken_layers=cfg.get("ken_layers", 4),
                 voc_layers=cfg.get("voc_layers", 6),
                 voc_hop=cfg.get("hop", 256)).to(a.device)
    model.load_state_dict(ck["model"]); model.eval()

    ids = [stoi.get(ch, stoi.get("<unk>", 1)) for ch in a.text]
    ids = [stoi.get("<bos>", 2)] + ids + [stoi.get("<eos>", 3)]
    t = torch.tensor([ids], device=a.device)
    tl = torch.tensor([len(ids)], device=a.device)
    with torch.no_grad():
        out = model(t, tl)                       # dict(mel, dur, wav)
        mel = out["mel"]                         # (1,80,T)
        wav = out["wav"][0]                      # (N_gen,) вокодер (кадр=hop)
        # приводим к естественной длительности: кадр mel = gamma семплов wav
        T = int(mel.shape[2] / a.speed)
        L = int(round(T * gamma))
        wav = F.interpolate(wav[None, None], size=L, mode="linear",
                            align_corners=False)[0, 0]
        # короткий fade на краях — убирает щелчок от не-нормированного OLA-хвоста
        fade = min(int(0.015 * 24000), L // 4)
        if fade > 0:
            ramp = torch.linspace(0.0, 1.0, fade, device=wav.device, dtype=wav.dtype)
            wav = wav.clone()
            wav[:fade] *= ramp
            wav[-fade:] *= ramp.flip(0)
    wav = wav.cpu().numpy()
    import soundfile as sf
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    sf.write(a.out, wav, 24000)
    print(f"OK: text='{a.text}' -> mel {tuple(mel.shape)} -> wav {wav.shape} "
          f"(L={L}), sr=24000, saved {a.out}")

if __name__ == "__main__":
    main()