#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""vits.py — лёгкая VITS-style модель text->mel->waveform БЕЗ BERT.

Компромисс «высокое качество + низкие накладные» (см. ресёрч): одна модель от
текста до waveform; вход — только char-токены (свои эмбеддинги, без BERT).
Состав (VITS2-флейвор, упрощённо но реально):
  SymbolEmb -> TextEncoder(FFT) -> [monotonic attention vs mel] -> Decoder(mel)
    + HiFi-подобный Generator -> waveform (adversarial опционально).
"""
import math
import torch
import torch.nn as nn
import torch.nn.functional as F


class ResidualConvBlock(nn.Module):
    def __init__(self, c, k=3, dilat=1):
        super().__init__()
        p = dilat * (k - 1) // 2
        self.c1 = nn.Conv1d(c, c, k, padding=p, dilation=dilat)
        self.c2 = nn.Conv1d(c, c, k, padding=p, dilation=dilat)
        self.n1 = nn.GroupNorm(1, c); self.n2 = nn.GroupNorm(1, c)

    def forward(self, x):
        r = F.gelu(self.n1(self.c1(x)))
        r = self.n2(self.c2(r))
        return F.gelu(x + r)


class FFTBlock(nn.Module):
    def __init__(self, d, nh=2):
        super().__init__()
        self.n1 = nn.LayerNorm(d)
        self.a = nn.MultiheadAttention(d, nh, batch_first=True)
        self.n2 = nn.LayerNorm(d)
        self.ff = nn.Sequential(nn.Linear(d, 4 * d), nn.GELU(), nn.Linear(4 * d, d))

    def forward(self, x, mask=None):
        n = self.n1(x)
        x = x + self.a(n, n, n, key_padding_mask=mask)[0]
        return x + self.ff(self.n2(x))


class TextEncoder(nn.Module):
    def __init__(self, vocab, d=192, layers=6, nh=2):
        super().__init__()
        self.emb = nn.Embedding(vocab, d, padding_idx=0)
        self.proj = nn.Conv1d(d, d, 1)
        self.fft = nn.ModuleList([FFTBlock(d, nh) for _ in range(layers)])

    def forward(self, ids, txt_len):
        x = self.emb(ids).transpose(1, 2)                # (B,d,L)
        x = self.proj(x).transpose(1, 2)                 # (B,L,d)
        m = torch.arange(ids.size(1), device=ids.device)[None, :] >= txt_len[:, None]
        for blk in self.fft:
            x = blk(x, mask=m)
        return x.transpose(1, 2)                         # (B,d,L)


class PosteriorEncoder(nn.Module):
    def __init__(self, in_ch=80, d=192):
        super().__init__()
        self.enc = nn.Sequential(ResidualConvBlock(in_ch, 3, 1),
                                 ResidualConvBlock(in_ch, 3, 2),
                                 ResidualConvBlock(in_ch, 3, 4))
        self.mu = nn.Conv1d(in_ch, d, 1)
        self.logv = nn.Conv1d(in_ch, d, 1)

    def forward(self, mel):
        z = self.enc(mel)
        return self.mu(z), self.logv(z)                  # (B,d,T)


class DurationPredictor(nn.Module):
    def __init__(self, d=192):
        super().__init__()
        self.p = nn.Sequential(ResidualConvBlock(d, 3, 1), ResidualConvBlock(d, 3, 1),
                               nn.Conv1d(d, 1, 1))

    def forward(self, x):
        return torch.exp(self.p(x))                      # (B,1,L)


class Decoder(nn.Module):
    def __init__(self, d=192, out_ch=80):
        super().__init__()
        self.blocks = nn.Sequential(ResidualConvBlock(d, 3, 1), ResidualConvBlock(d, 3, 1),
                                    ResidualConvBlock(d, 3, 1))
        self.out = nn.Conv1d(d, out_ch, 1)

    def forward(self, z):
        return self.out(self.blocks(z))


class HiFiResBlock(nn.Module):
    def __init__(self, c, k):
        super().__init__()
        self.l1 = nn.Conv1d(c, c, k, padding=(k - 1) * 1 // 2, dilation=1)
        self.l2 = nn.Conv1d(c, c, k, padding=(k - 1) * 2 // 2, dilation=2)
        self.l3 = nn.Conv1d(c, c, k, padding=(k - 1) * 4 // 2, dilation=4)

    def forward(self, x):
        r = F.leaky_relu(self.l1(x), 0.1)
        r = F.leaky_relu(self.l2(r), 0.1)
        r = F.leaky_relu(self.l3(r), 0.1)
        return r + x


class Generator(nn.Module):
    """HiFi-GAN-подобный генератор mel->waveform (upsample, итог x256)."""
    def __init__(self, in_ch=80, hidden=96):
        super().__init__()
        ups = [(8, 4), (5, 4), (4, 2), (4, 2)]           # общий x256
        self.pre = nn.Conv1d(in_ch, hidden, 7, padding=3)
        self.ups = nn.ModuleList(); self.r1 = nn.ModuleList(); self.r2 = nn.ModuleList()
        cur = hidden
        for u in range(len(ups)):
            outc = min(cur * 2, 512)
            self.ups.append(nn.ConvTranspose1d(cur, outc, ups[u][0], stride=ups[u][1],
                                               padding=(ups[u][0] - ups[u][1]) // 2))
            self.r1.append(HiFiResBlock(outc, 3)); self.r2.append(HiFiResBlock(outc, 7))
            cur = outc
        self.out = nn.Conv1d(cur, 1, 7, padding=3)
        self.upsamplerate = 256

    def forward(self, mel):
        x = self.pre(mel)
        for u, r1, r2 in zip(self.ups, self.r1, self.r2):
            x = F.leaky_relu(u(x), 0.1)
            x = F.leaky_relu(r1(x), 0.1)
            x = F.leaky_relu(r2(x), 0.1)
        return torch.tanh(self.out(x)).squeeze(1)        # (B, N_wav)


class Discriminator(nn.Module):
    def __init__(self, in_ch=1):
        super().__init__()
        self.convs = nn.ModuleList([
            nn.Conv1d(in_ch, 64, 7, stride=2, padding=3),
            nn.Conv1d(64, 128, 7, stride=2, padding=3),
            nn.Conv1d(128, 256, 5, stride=2, padding=2),
            nn.Conv1d(256, 1, 3, stride=1, padding=1)])

    def forward(self, x):
        h = x
        feat = []
        for c in self.convs:
            h = F.leaky_relu(c(h), 0.1)
            feat.append(h)
        return h.mean([1, 2]), feat


class Vits(nn.Module):
    def __init__(self, vocab=178, d=192, n_mels=80):
        super().__init__()
        self.enc = TextEncoder(vocab, d)
        self.pe = PosteriorEncoder(n_mels, d)
        self.dp = DurationPredictor(d)
        self.dec = Decoder(d, n_mels)
        self.gen = Generator(n_mels)
        self.disc = Discriminator()
        self.align_proj = nn.Linear(n_mels, d)   # мел(80)->d для выравнивания

    def forward(self, ids, txt_len, mel=None, mel_len=None, eps=1.0):
        he = self.enc(ids, txt_len)                      # (B,d,L)
        if mel is not None:
            mu, logv = self.pe(mel)                      # (B,d,T)
            z = mu + torch.randn_like(mu) * torch.exp(logv * 0.5) * eps
            mel_pred = self.dec(z)                       # реконстр. из posterior (мел-длины)
            align = self._align(he, mel, txt_len, mel_len)   # (B,L,T)
            hz = he @ align                              # текст->мел-точечно (B,d,T)
            mel_from_text = self.dec(hz)
            dur = align.sum(-1)
            return {"mel": mel_pred, "mel_text": mel_from_text, "mu": mu, "logv": logv,
                    "align": align, "dur": dur, "z": z}
        else:
            dur = self.dp(he).squeeze(1)                 # (B,L)
            dur = torch.max(dur, torch.ones_like(dur))
            B, L = dur.shape
            Tmax = int(ids.shape[1] * 20)
            idx = torch.zeros(B, Tmax, dtype=torch.long, device=ids.device)
            for i in range(B):
                tl = int(txt_len[i].item())
                c = torch.cumsum(dur[i, :tl], 0)
                if tl > 0:
                    tt = torch.arange(Tmax, device=ids.device)
                    idx[i, :tl * 20] = torch.searchsorted(c, tt[:tl * 20], right=True).clamp(max=tl - 1)
            idx = idx.clamp(max=L - 1)
            z_up = torch.gather(he, 2, idx.unsqueeze(1).expand(B, he.size(1), -1))
            mel_pred = self.dec(z_up)
            return {"mel": mel_pred, "dur": dur}

    def _align(self, he, mel, txt_len, mel_len):
        h = he.transpose(1, 2)                           # (B,L,d)
        meln = self.align_proj(mel.transpose(1, 2))      # (B,T,d)
        meln = meln / (meln.norm(dim=2, keepdim=True) + 1e-6)
        A = torch.bmm(h, meln.transpose(1, 2)) / (h.norm(dim=2, keepdim=True) + 1e-6)   # (B,L,T)
        mask_t = torch.arange(A.size(2), device=A.device)[None, :] >= mel_len[:, None]
        mask_l = torch.arange(A.size(1), device=A.device)[None, :] >= txt_len[:, None]
        A = A.masked_fill(mask_t.unsqueeze(1), -1e9).masked_fill(mask_l.unsqueeze(2), -1e9)
        return torch.softmax(A, dim=1)


def vits_loss(out, mel, txt_len, mel_len, text_w=0.5, kl_w=0.0):
    m = torch.arange(mel.shape[2], device=mel.device)[None, :] < mel_len[:, None]
    mask = ~m.unsqueeze(1)
    d2 = (out["mel"] - mel).pow(2).masked_fill(mask, 0)
    loss = d2.sum() / (m.sum().clamp(min=1) * mel.shape[1])
    if out.get("mel_text") is not None:
        d2t = (out["mel_text"] - mel).pow(2).masked_fill(mask, 0)
        loss = loss + text_w * d2t.sum() / (m.sum().clamp(min=1) * mel.shape[1])
    if kl_w > 0 and out.get("mu") is not None and out.get("logv") is not None:
        loss = loss + kl_w * (-0.5 * (1 + out["logv"] - out["mu"].pow(2) - out["logv"].exp()).sum()) / mel.shape[0]
    return loss


def main():
    torch.manual_seed(0)
    import json
    man = json.load(open("model/data/manifest.json", encoding="utf-8"))
    V = len(man["tokenizer"]["symbols"])
    model = Vits(V, d=96, n_mels=80)
    ids = torch.randint(2, V, (2, 40)); txt_len = torch.tensor([40, 30])
    mel = torch.randn(2, 80, 200)
    out = model(ids, txt_len, mel=mel, mel_len=torch.tensor([200, 150]))
    loss = vits_loss(out, mel, txt_len, torch.tensor([200, 150]))
    loss.backward()
    # inference-путь
    out2 = model(ids[:1], torch.tensor([40]))
    print("forward+backward OK; mel_pred", tuple(out["mel"].shape),
          "loss", round(loss.item(), 4), "| infer mel", tuple(out2["mel"].shape))


if __name__ == "__main__":
    main()