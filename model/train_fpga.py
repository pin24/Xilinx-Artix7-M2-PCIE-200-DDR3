#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""train_fpga.py — обучение VITS-модели с прогоном pointwise-свёрток через FPGA.

Идея (контур "обучение на плате"):
  * master-веса и градиенты остаются fp32 на хосте;
  * тяжёлые операторы — ВСЕ pointwise 1x1 свёртки (это matmul по последней оси,
    длина <=1024) — считаются на движке TdotCore через FpgaBackend.run_dot
    (TFloat48: 8-бит экспонента + 40-бит троичная мантисса);
  * depthwise-свертки, LayerNorm, irfft/OLA вокодера, stft в потере — host (fp32).

Почему только pointwise: run_dot раскрывает dot по последней оси; у свёртки 1x1
это сокращение по каналам (<=1024), идеально ложится. Depthwise (kernel по времени)
и норм-слои движком не ускоряются и остаются на хосте.

Ограничение производительности: run_dot даёт ОДИН скаляр на ряд, поэтому matmul
делается циклом по (batch*time) — быстро только для малых размеров; это не
замена GPU-обучению по скорости, а демонстрация FPGA-пути обучения.

Запуск (эмуляция без железа):
  python model\\train_fpga.py --mode cpu --steps 30 --batch 2 --d 64 --vd 32 --t-len 24
Запуск на плате:
  python model\\train_fpga.py --mode fpga --epochs 1 --batch 4 --d 96 --vd 64
"""
import os, sys, json, time, argparse
import multiprocessing as mp
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader

_THIS = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_THIS)
sys.path.insert(0, _THIS)
sys.path.insert(0, os.path.join(_ROOT, "pytorch_layer"))
from data import TTSPair, collate
from vits import Vits, vits_loss
from fpga_backend import FpgaBackend


def _pad_rows(a, n):
    """Добрать последнюю ось нулями до n (не меняет dot)."""
    w = n - a.shape[-1]
    if w <= 0:
        return a
    p = np.zeros(a.shape[:-1] + (w,), dtype=np.float32)
    return np.concatenate([a, p], axis=-1)


class FpgaDot(torch.autograd.Function):
    """matmul x(W? -> нет) — точка-произведение вектора с весовой матрицей по последней оси.

    НЕ то же, что x@W^T в общем виде; здесь y[..., j] = dot(x[..., :], W[j, :]).
    Это ровно pointwise-свёртка (и сокращение идёт по каналам, длина <=1024).
    forward идёт через run_dot (FPGA/эмуляция), backward — fp32 host-matmul.
    """

    @staticmethod
    def forward(ctx, x, weight, backend):
        # x: (..., C), weight: (J, C) -> out: (..., J)
        xb = x.detach().float().cpu().numpy()
        wb = weight.detach().float().cpu().numpy()          # (J, C)
        flat = xb.reshape(-1, xb.shape[-1])                 # (P, C)
        J, C = wb.shape
        k = backend.n                                       # надёжная длина dot (32)
        out = np.zeros((flat.shape[0], J), dtype=np.float32)
        for p in range(flat.shape[0]):
            acc = np.zeros(J, dtype=np.float32)
            # дробим ось каналов на чанки по k и суммируем (как mul_chunked/matmul_w)
            for co in range(0, C, k):
                L = min(k, C - co)
                Wa = wb[:, co:co + L]
                xp = flat[p:p + 1, co:co + L]
                if L < k:
                    Wa = _pad_rows(Wa, k)                   # (J, k)
                    xp = _pad_rows(xp, k)                   # (1, k)
                xp = np.repeat(xp, J, axis=0)               # (J, k)
                acc += backend.run_dot(Wa, xp)
            out[p] = acc
        ctx.save_for_backward(x.detach(), weight)
        return torch.from_numpy(out).to(x.device).to(x.dtype).reshape(x.shape[:-1] + (J,))

    @staticmethod
    def backward(ctx, g):
        x, weight = ctx.saved_tensors
        # y[..., j] = sum_c x[..., c] * W[j, c]
        dw = torch.einsum('...j,...c->jc', g, x.float())
        dx = torch.einsum('...j,jc->...c', g, weight.float())
        return dx.to(x.dtype), dw.to(x.dtype), None


class FpgaPointwise(nn.Module):
    """Бессместительная pointwise-свёртка (1x1) через FpgaDot.

    y[c, t] = sum_i x[i, t] * W[c, i]. Смещения не используем (в модели их и нет).
    Бэкенд кешируется: один FpgaBackend на (mode, n) на весь процесс — чтобы не
    открывать плату на каждый слой и не гонять авто-детект NUM_MAC повторно.
    """

    _BACKEND_CACHE = {}

    def __init__(self, cin, cout, backend_mode="cpu", num_mac=None):
        super().__init__()
        self.weight = nn.Parameter(torch.randn(cout, cin) * (cin ** -0.5))
        # надёжная длина dot на плате: 32 (проверено ring_check). Длинные векторы
        # дробим в FpgaDot.forward на чанки по 32 и суммируем (как mul_chunked).
        n = 32
        key = (backend_mode, n, num_mac)
        if key not in self._BACKEND_CACHE:
            self._BACKEND_CACHE[key] = FpgaBackend(mode=backend_mode, n=n, num_mac=num_mac)
        self.backend = self._BACKEND_CACHE[key]

    def forward(self, x):
        # x: (B, Cin, T) -> (B, Cout, T)
        B, Ci, T = x.shape
        w = self.weight.to(x.dtype)
        y = FpgaDot.apply(x.transpose(1, 2).reshape(-1, Ci), w, self.backend)
        return y.reshape(B, T, -1).transpose(1, 2)


def _probe_num_mac_child(q):
    """В отдельном процессе: открыть плату и определить num_mac.

    Изоляция через процесс нужна, потому что probe_firmware()/read32() могут
    висеть на 100% CPU, если плата не отвечает, — родитель прервёт по таймауту.
    """
    try:
        fb = FpgaBackend(mode="fpga", n=8, num_mac=None)
        q.put(("ok", int(fb.num_mac)))
    except Exception as e:
        q.put(("err", str(e)))


def _safe_detect_num_mac(timeout=8.0):
    """Наличие платы + авто-детект NUM_MAC с ограничением по времени.

    Возвращает int num_mac; бросает RuntimeError('not found') если платы нет,
    или RuntimeError('timeout') если определение зависло.
    """
    q = mp.Queue()
    p = mp.Process(target=_probe_num_mac_child, args=(q,), daemon=True)
    p.start()
    try:
        status, val = q.get(timeout=timeout)
    except Exception:
        p.terminate(); p.join(timeout=2)
        raise RuntimeError(f"таймаут авто-детекта NUM_MAC ({timeout}с): плата не отвечает")
    p.join(timeout=2)
    if status == "ok" and val:
        return int(val)
    raise RuntimeError(f"FPGA не найдена: {val}")


def to_fpga_model(model, backend_mode="cpu", num_mac=None):
    """Заменить все pointwise (kernel=1, groups=1) свёртки модели на FpgaPointwise."""
    for name, child in list(model.named_children()):
        if isinstance(child, nn.Conv1d) and child.kernel_size[0] == 1 and child.groups == 1:
            fp = FpgaPointwise(child.in_channels, child.out_channels, backend_mode, num_mac)
            fp.weight.data = child.weight.data[:, :, 0].to(fp.weight.dtype)
            setattr(model, name, fp)
        else:
            to_fpga_model(child, backend_mode, num_mac)
    return model


def export_infer_ckpt(fpga_ckpt, out_path):
    """Собрать обычный чекпойнт (nn.Conv1d), пригодный для infer.py/train.py.

    FpgaPointwise хранит вес 2D (Cout, Cin); тут разворачиваем обратно в 3D
    (Cout, Cin, 1) и сохраняем как обычный Vits-чекпойнт.
    """
    ck = torch.load(fpga_ckpt, map_location="cpu")
    cfg = ck.get("vits_config", {})
    plain = Vits(vocab=cfg.get("vocab", 178), d=cfg.get("d", 64), n_mels=80,
                 vd=cfg.get("vd", 32), ken_layers=cfg.get("ken_layers", 2),
                 voc_layers=cfg.get("voc_layers", 2), voc_hop=cfg.get("hop", 256))
    fp_sd = ck["model"]
    sd = plain.state_dict()
    for k in sd:
        if k in fp_sd:
            v = fp_sd[k]
            if sd[k].ndim == 3 and v.ndim == 2:          # точкаConv1d -> (Cout,Cin,1)
                v = v.unsqueeze(-1)
            sd[k] = v
    plain.load_state_dict(sd)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    torch.save({"model": plain.state_dict(), "vocab": cfg.get("vocab", 178),
                "vits_config": dict(cfg)}, out_path)
    print("экспорт fpga->infer-чекпойнт:", out_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["cpu", "fpga"], default="cpu",
                    help="cpu = эмуляция TFloat48; fpga = реальная плата")
    ap.add_argument("--epochs", type=int, default=1)
    ap.add_argument("--batch", type=int, default=2)
    ap.add_argument("--steps", type=int, default=60, help="ограничить шаги (для пробы)")
    ap.add_argument("--d", type=int, default=64)
    ap.add_argument("--vd", type=int, default=32)
    ap.add_argument("--ken-layers", type=int, default=2)
    ap.add_argument("--voc-layers", type=int, default=2)
    ap.add_argument("--t-len", type=int, default=0,
                    help="обрезать длину мел/текста для пробы (0 = полные)")
    ap.add_argument("--lr", type=float, default=2e-4)
    ap.add_argument("--w-dur", type=float, default=0.3)
    ap.add_argument("--ckpt", default="model/checkpoints/vits_fpga.pt")
    ap.add_argument("--num-mac", type=int, default=None,
                    help="опциональный оверрайд NUM_MAC. Если не задан — плата определяется "
                         "автоматически (с безопасным таймаутом) при старте.")
    ap.add_argument("--pretrained", default=None,
                    help="путь к обычному чекпойнту train.py; инициализировать pointwise-веса "
                         "из него (архитектура d/vd/слои берётся из этого чекпойнта)")
    ap.add_argument("--export", default=None,
                    help="конвертировать --ckpt (fpga, 2D pointwise) в чекпойнт, совместимый "
                         "с infer.py/train.py, и сохранить сюда; обучение при этом не идёт")
    a = ap.parse_args()

    ds = TTSPair(os.path.join(_ROOT, "model/data/manifest.json"), split="train", load_wav=True)

    # --- экспорт fpga-чекпойнта в infer-совместимый (без обучения) ---
    if a.export:
        export_infer_ckpt(a.ckpt, a.export)
        return

    # --- архитектура: при --pretrained берём из чекпойнта train.py ---
    pretrained_sd = None
    arch = dict(d=a.d, vd=a.vd, ken_layers=a.ken_layers, voc_layers=a.voc_layers)
    if a.pretrained:
        pck = torch.load(a.pretrained, map_location="cpu")
        cfg = pck.get("vits_config", {})
        arch = dict(d=cfg.get("d", a.d), vd=cfg.get("vd", a.vd),
                    ken_layers=cfg.get("ken_layers", a.ken_layers),
                    voc_layers=cfg.get("voc_layers", a.voc_layers))
        pretrained_sd = pck["model"]
        print(f"pretrained: {a.pretrained} -> d={arch['d']}, vd={arch['vd']}, "
              f"ken={arch['ken_layers']}, voc={arch['voc_layers']}")

    base = Vits(vocab=ds.vocab_size, d=arch["d"], n_mels=80, vd=arch["vd"],
                ken_layers=arch["ken_layers"], voc_layers=arch["voc_layers"])
    if pretrained_sd is not None:
        base.load_state_dict(pretrained_sd)

    # --- 1) и 2) наличие платы + авто-детект NUM_MAC (безопасно по времени) ---
    if a.mode == "fpga":
        try:
            num_mac = a.num_mac if a.num_mac else _safe_detect_num_mac()
            print(f"fpga: плата доступна, num_mac = {num_mac}")
        except Exception as e:
            sys.exit(f"FPGA НЕДОСТУПЕН: {e}\n"
                     "Проверь плату/драйвер или запусти эмуляцию: --mode cpu")
    else:
        num_mac = None                                  # cpu-эмуляция: дефолт абстракции
    model = to_fpga_model(base, backend_mode=a.mode, num_mac=num_mac)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=1e-2)
    os.makedirs(os.path.dirname(a.ckpt), exist_ok=True)
    print(f"train_fpga: mode={a.mode}, d={arch['d']}, vd={arch['vd']}, batch={a.batch}, "
          f"pretrained={'да' if pretrained_sd is not None else 'нет'}")

    dl = iter(DataLoader(ds, batch_size=a.batch, collate_fn=collate, num_workers=0))
    step = 0
    for ep in range(1, a.epochs + 1):
        t0 = time.monotonic(); tot = 0; nb = 0
        while step < a.steps:
            try:
                b = next(dl)
            except StopIteration:
                dl = iter(DataLoader(ds, batch_size=a.batch, collate_fn=collate, num_workers=0))
                b = next(dl)
            ids = b["ids"]; txt_len = b["txt_len"]; mel = b["mel"]; mel_len = b["mel_len"]
            wav = b["wav"]; wav_len = b["wav_len"]
            if a.t_len and mel.shape[2] > a.t_len:      # проба на коротких отрывках
                mel = mel[:, :, :a.t_len]; mel_len = mel_len.clamp(max=a.t_len)
                clip = int(wav.shape[1] * a.t_len / mel.shape[2])
                wav = wav[:, :clip]; wav_len = wav_len.clamp(max=clip)
            out = model(ids, txt_len, mel=mel, mel_len=mel_len)
            loss = vits_loss(out, mel, txt_len, mel_len, kl_w=0.0, w_dur=a.w_dur,
                             w_voc=1.0, wav=wav, wav_len=wav_len,
                             hop=model.voc_hop, nfft=model.gen.nfft)
            opt.zero_grad(); loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            step += 1; tot += loss.item(); nb += 1
            if step % 5 == 0 or step == a.steps:
                print(f"  step {step}/{a.steps}  loss={loss.item():.4f}")
        print(f"ep {ep}: loss {tot/max(nb,1):.4f} ({time.monotonic()-t0:.1f}s)")
        torch.save({"model": model.state_dict(), "vits_config": {"vocab": ds.vocab_size, "d": a.d,
                    "vd": a.vd, "ken_layers": a.ken_layers, "voc_layers": a.voc_layers,
                    "hop": model.voc_hop, "gamma": 277.0, "fpga_mode": a.mode},
                    "epoch": ep, "step": step, "optimizer": opt.state_dict()}, a.ckpt)
    print("готово; чекпойнт:", a.ckpt)


if __name__ == "__main__":
    main()