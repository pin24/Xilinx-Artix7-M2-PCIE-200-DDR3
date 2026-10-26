#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""train.py — обучение VITS-модели (без BERT) на вашем датасете.

Запуск: python model\\train.py [--epochs N] [--batch B] [--steps N] [--ckpt path]
        [--resume] — дозагрузка весов/оптимизатора/эпохи/шага из --ckpt.
Использует model/data/manifest.json (data_prep.py) и model/vits.py.
По умолчанию обучение на GPU; на CPU только проба (--steps N).
"""
import os, sys, json, time, argparse
import torch
from torch.utils.data import DataLoader
from tqdm import tqdm
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
    ap.add_argument("--d", type=int, default=192)        # ширина энкодера
    ap.add_argument("--vd", type=int, default=128)       # ширина вокодера
    ap.add_argument("--ken-layers", type=int, default=4)
    ap.add_argument("--voc-layers", type=int, default=6)
    ap.add_argument("--w-dur", type=float, default=0.1)
    ap.add_argument("--w-voc", type=float, default=1.0)
    ap.add_argument("--kl-w", type=float, default=0.0)
    ap.add_argument("--num-workers", type=int, default=2)
    ap.add_argument("--resume", action="store_true",
                    help="дозагрузить веса/оптимизатор/эпоху/шаг из --ckpt и продолжить")
    ap.add_argument("--amp", action="store_true",
                    help="mixed precision bf16: тяжёлые вычисления в bf16, master-веса в fp32")
    ap.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    ap.add_argument("--save-every", type=int, default=1000)
    a = ap.parse_args()

    ds = TTSPair("model/data/manifest.json", split="train", load_wav=True)

    # --- дозагрузка ---
    ck = None
    start_epoch = 1; step = 0; gamma = None
    if a.resume:
        if not os.path.exists(a.ckpt):
            sys.exit(f"ошибка: --resume, но чекпойнт не найден: {a.ckpt}")
        ck = torch.load(a.ckpt, map_location=a.device if a.device != "cpu" else "cpu")
        ccfg = ck.get("vits_config", {})
        gamma = ccfg.get("gamma")
        start_epoch = (ck.get("epoch", 0) or 0) + 1
        step = ck.get("step", 0)
        print(f"resume: ckpt={a.ckpt} epoch={ck.get('epoch',0)} step={step} gamma={gamma}")

    # архитектура: при дозагрузке берём из чекпойнта (иначе веса не лягут)
    arch = dict(d=a.d, vd=a.vd, ken_layers=a.ken_layers, voc_layers=a.voc_layers)
    if ck is not None:
        arch = dict(d=ccfg.get("d", a.d), vd=ccfg.get("vd", a.vd),
                    ken_layers=ccfg.get("ken_layers", a.ken_layers),
                    voc_layers=ccfg.get("voc_layers", a.voc_layers))

    model = Vits(vocab=ds.vocab_size, n_mels=80, **arch).to(a.device)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=1e-2)
    if ck is not None:
        try:
            model.load_state_dict(ck["model"])
        except Exception as e:
            sys.exit("ошибка resume: чекпойнт несовместим с текущей архитектурой "
                     "(вероятно, он от СТАРОЙ модели). Начни обучение заново без --resume. "
                     f"Причина: {e}")
        if "optimizer" in ck:
            try:
                opt.load_state_dict(ck["optimizer"])
            except Exception as e:
                print("предупреждение: состояние оптимизатора не восстановлено:", e)

    gamma = gamma if gamma else _measure_gamma(ds)
    dl = DataLoader(ds, batch_size=a.batch, shuffle=True, collate_fn=collate,
                    num_workers=a.num_workers)
    os.makedirs(os.path.dirname(a.ckpt), exist_ok=True)
    print(f"train: {len(ds)} пар, batch {a.batch}, d={arch['d']}, vd={arch['vd']}, "
          f"gamma={gamma:.1f}, amp={bool(a.amp)}, device={a.device}")
    if start_epoch > a.epochs:
        print("уже обучено все эпохи; увеличь --epochs выше", ck.get("epoch", 0))
        return
    for ep in range(start_epoch, a.epochs + 1):
        t0 = time.monotonic(); tot = 0; nb = 0
        pbar = tqdm(dl, desc=f"ep {ep}/{a.epochs}", unit="batch", dynamic_ncols=True)
        for b in pbar:
            ids = b["ids"].to(a.device); txt_len = b["txt_len"].to(a.device)
            mel = b["mel"].to(a.device); mel_len = b["mel_len"].to(a.device)
            wav = b.get("wav").to(a.device) if "wav" in b else None
            wav_len = b.get("wav_len").to(a.device) if "wav" in b else None
            if a.amp and a.device.startswith("cuda"):
                with torch.autocast(device_type="cuda", dtype=torch.bfloat16):
                    out = model(ids, txt_len, mel=mel, mel_len=mel_len)
                    loss = vits_loss(out, mel, txt_len, mel_len, kl_w=a.kl_w,
                                     w_dur=a.w_dur, w_voc=a.w_voc, wav=wav, wav_len=wav_len,
                                     hop=model.voc_hop, nfft=model.gen.nfft)
            else:
                out = model(ids, txt_len, mel=mel, mel_len=mel_len)
                loss = vits_loss(out, mel, txt_len, mel_len, kl_w=a.kl_w,
                                 w_dur=a.w_dur, w_voc=a.w_voc, wav=wav, wav_len=wav_len,
                                 hop=model.voc_hop, nfft=model.gen.nfft)
            opt.zero_grad(); loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            tot += loss.item(); nb += 1; step += 1
            pbar.set_postfix(loss=f"{loss.item():.4f}", step=step, refresh=False)
            if a.steps and step >= a.steps:
                pbar.set_postfix(loss=f"{loss.item():.4f}", step=step)
                pbar.close(); break
            if step % a.save_every == 0:
                _save(a.ckpt, model, opt, ds, a, gamma, ep, step, arch)
        pbar.close()
        print(f"ep {ep}: loss {tot/max(nb,1):.4f} ({time.monotonic()-t0:.1f}s)")
        _save(a.ckpt, model, opt, ds, a, gamma, ep, step, arch)
        if a.steps and step >= a.steps:
            print("стоп (лимит шагов пробы)"); break
    print("готово; чекпойнт:", a.ckpt)


def _measure_gamma(ds, n=300):
    """Средняя длина wav на 1 кадр mel по подвыборке датасета."""
    import numpy as np, soundfile as sf, random
    vals = []
    rng = random.Random(0)
    for it in rng.sample(ds.items, min(n, len(ds.items))):
        try:
            x, _ = sf.read(it["wav"], dtype="float32")
            m = np.load(it["mel"])
            if m.shape[1] > 0 and x.shape[0] > 0:
                vals.append(x.shape[0] / m.shape[1])
        except Exception:
            continue
    return float(np.median(vals)) if vals else 277.0


def _save(ckpt_path, model, opt, ds, a, gamma, epoch, step, arch):
    torch.save({"model": model.state_dict(), "vocab": ds.vocab_size, "epoch": epoch,
                "step": step, "hop": model.voc_hop, "optimizer": opt.state_dict(),
                "vits_config": {"vocab": ds.vocab_size, "n_mels": 80, "gamma": gamma,
                                "d": arch["d"], "vd": arch["vd"],
                                "ken_layers": arch["ken_layers"],
                                "voc_layers": arch["voc_layers"],
                                "hop": model.voc_hop}}, ckpt_path)


if __name__ == "__main__":
    main()