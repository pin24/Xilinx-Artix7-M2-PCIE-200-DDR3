#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""train.py — обучение VITS-модели (без BERT) на вашем датасете.

Запуск: python model\\train.py [--epochs N] [--batch B] [--steps N] [--ckpt path] [--cpu]
Использует model/data/manifest.json (data_prep.py) и model/vits.py.
По умолчанию день на GPU; на CPU только проба (--steps N) — полноценное обучение.
"""
import os, sys, json, time, argparse
import torch
from torch.utils.data import DataLoader
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from data import TTSPair, collate
from vits import Vits, vits_loss

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=10)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--steps", type=int, default=0, help="ограничить число шагов (для пробы на CPU)")
    ap.add_argument("--ckpt", default="model/checkpoints/vits.pt")
    ap.add_argument("--lr", type=float, default=2e-4)
    ap.add_argument("--d", type=int, default=192)
    ap.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    ap.add_argument("--save-every", type=int, default=1000)
    a = ap.parse_args()

    ds = TTSPair("model/data/manifest.json", split="train")
    dl = DataLoader(ds, batch_size=a.batch, shuffle=True, collate_fn=collate, num_workers=0)
    model = Vits(vocab=ds.vocab_size, d=a.d, n_mels=80).to(a.device)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=1e-2)
    os.makedirs(os.path.dirname(a.ckpt), exist_ok=True)
    print(f"train: {len(ds)} пар, batch {a.batch}, d={a.d}, device={a.device}")
    step = 0
    for ep in range(1, a.epochs + 1):
        t0 = time.monotonic(); tot = 0; nb = 0
        for b in dl:
            ids = b["ids"].to(a.device); txt_len = b["txt_len"].to(a.device)
            mel = b["mel"].to(a.device); mel_len = b["mel_len"].to(a.device)
            out = model(ids, txt_len, mel=mel, mel_len=mel_len)
            loss = vits_loss(out, mel, txt_len, mel_len, kl_w=0.0)
            opt.zero_grad(); loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            tot += loss.item(); nb += 1; step += 1
            if a.steps and step >= a.steps:
                break
            if step % a.save_every == 0:
                torch.save({"model": model.state_dict(), "vocab": ds.vocab_size, "d": a.d,
                            "vits_config": {"vocab": ds.vocab_size, "d": a.d, "n_mels": 80}},
                           a.ckpt)
        print(f"ep {ep}: loss {tot/max(nb,1):.4f} ({time.monotonic()-t0:.1f}s)")
        torch.save({"model": model.state_dict(), "vocab": ds.vocab_size, "d": a.d,
                    "vits_config": {"vocab": ds.vocab_size, "d": a.d, "n_mels": 80}}, a.ckpt)
        if a.steps and step >= a.steps:
            print("стоп (лимит шагов пробы)"); break
    print("готово; чекпойнт:", a.ckpt)

if __name__ == "__main__":
    main()