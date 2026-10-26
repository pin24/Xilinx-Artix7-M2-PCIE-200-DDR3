#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""vits.py — лёгкая VITS-style модель text->mel->waveform БЕЗ BERT.

Целевые свойства (FPGA-тренируемость):
  * Все тяжёлые операции — это matmul/dot по последней оси длины <= ~1024
    (линейные, pointwise/depthwise conv, STFT/iSTFT как матричное умножение),
    что маппится на TdotCore (FpgaBackend.run_dot, TFloat48).
  * Никакого GAN: вокодер — ЯВНОЕ предсказание комплексного спектра
    (re+im) с последующим iSTFT (путь Vocos/FreeGAN). Это единственный
    проверенный в литературе способ получить чистую речь без дискриминатора
    (время-доменный генератор без GAN разваливает фазу).
  * Ширина энкодера ~192 (не сжимать до 64 — LightSpeech: -0.23 CMOS при 128),
    но блоки строятся на экономичных depthwise-conv вдоль времени.

Состав:
  SymbolEmb -> TextEncoder(block conv) -> [softmax-align vs mel] ->
  DurationPredictor (обучается на длительностях выравнивания) ->
  Decoder(mel) -> VocosLite(комплексный спектр -> iSTFT) -> waveform.

Потери: mel-recon (posterior) + mel-text (text path) + KL (мал.) +
        duration-supervision + vocoder (L1 waveform + MR-STFT + комплексная/фаза).
"""
import torch
import torch.nn as nn
import torch.nn.functional as F


# ----------------------------------------------------------------------------
# Базовые блоки (весь вычислительный вес — matmul/dot, маппятся на FPGA)
# ----------------------------------------------------------------------------

class ConvWide(nn.Module):
    """Depthwise 1D conv по времени (kernel ~9) + pointwise 1x1 (x4->x4->x1) + residual.

    Depthwise-свёртка по оси времени для фиксированной позиции — это dot по
    соседним отсчётам (малое ядро <= kernel*C), pointwise — чистый matmul.
    """

    def __init__(self, c, k=9, scale=4):
        super().__init__()
        self.dw = nn.Conv1d(c, c, k, padding=k // 2, groups=c)
        self.n = nn.LayerNorm(c)
        self.fc1 = nn.Conv1d(c, c * scale, 1)
        self.fc2 = nn.Conv1d(c * scale, c, 1)

    def forward(self, x):                       # x: (B, C, T)
        r = self.dw(x).transpose(1, 2)          # (B, T, C)
        r = self.n(r).transpose(1, 2)
        r = F.gelu(self.fc1(r))
        r = self.fc2(r)
        return x + r


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


# ----------------------------------------------------------------------------
# Text encoder (без BERT, свой эмбеддинг; width d ~192)
# ----------------------------------------------------------------------------

class TextEncoder(nn.Module):
    def __init__(self, vocab, d=192, layers=4, k=9):
        super().__init__()
        self.emb = nn.Embedding(vocab, d, padding_idx=0)
        self.proj = nn.Conv1d(d, d, 1)
        self.blocks = nn.ModuleList([ConvWide(d, k=k) for _ in range(layers)])

    def forward(self, ids, txt_len):
        x = self.emb(ids).transpose(1, 2)                # (B,d,L)
        x = self.proj(x)
        for blk in self.blocks:
            x = blk(x)
        return x                                         # (B,d,L)


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
    """Предсказывает лог-длительности; обучается против align.sum(-1) (лог-домен)."""

    def __init__(self, d=192):
        super().__init__()
        self.p = nn.Sequential(ResidualConvBlock(d, 3, 1), ResidualConvBlock(d, 3, 1),
                               nn.Conv1d(d, 1, 1))

    def forward(self, x):                                # x:(B,d,L) -> log-dur (B,L)
        return self.p(x).squeeze(1)


class Decoder(nn.Module):
    def __init__(self, d=192, out_ch=80):
        super().__init__()
        self.blocks = nn.Sequential(ResidualConvBlock(d, 3, 1), ResidualConvBlock(d, 3, 1),
                                    ResidualConvBlock(d, 3, 1))
        self.out = nn.Conv1d(d, out_ch, 1)

    def forward(self, z):
        return self.out(self.blocks(z))                  # (B,out_ch,T)


# ----------------------------------------------------------------------------
# VocosLite — ЯВНЫЙ комплексный спектр (re+im) + iSTFT, БЕЗ GAN.
# Всё — матричные умножения (STFT/iSTFT = базисные матрицы), FPGA-маппимо.
# ----------------------------------------------------------------------------

class VocosLite(nn.Module):
    """mel(in_ch x T) -> waveform. Предсказывает комплексный STFT (F=nfft//2+1 bin)
    на каждый кадр, обратно во время через torch.istft (матрица DFT/IDFT —
    в принципе маппится на FPGA как matmul). Каждый кадр мела -> hop отсчётов wav.
    Затем длина приводится резэмплингом к фактическому соотношению датасета.
    """

    def __init__(self, in_ch=80, d=128, layers=6, k=9, nfft=1024, hop=256):
        super().__init__()
        self.nfft = nfft; self.hop = hop
        self.F = nfft // 2 + 1                          # число комплексных бинов
        self.pre = nn.Conv1d(in_ch, d, 1)
        self.convs = nn.ModuleList([ConvWide(d, k=k) for _ in range(layers)])
        self.head = nn.Conv1d(d, 2 * self.F, 1)         # [re; im], 2F каналов
        # синтез-окно и веса для OLA-нормировки (как torch.istft).
        # Диагональная раскладка: кадр (N отсчётов) ложится на сдвиги t*hop+i.
        win = torch.hann_window(nfft)
        diag = torch.eye(nfft)
        ola = (diag * win[:, None]).unsqueeze(1)                    # (N,1,N)
        wsum = (diag * (win ** 2)[:, None]).unsqueeze(1)            # (N,1,N)
        self.register_buffer("win", win)
        self.register_buffer("ola", ola)
        self.register_buffer("wsum", wsum)

    def _istft(self, zc):
        """zc: (B, F, T) complex -> (B, (T-1)*hop + N). irfft — матрица DFT,
        OLA — conv_transpose1d; всё маппимо на FPGA (dot/conv)."""
        B, _, T = zc.shape
        N, H = self.nfft, self.hop
        frames = torch.fft.irfft(zc, n=N, dim=1)             # (B, N, T), уже x·w (анализ-окно)
        # окно применяется ЕЩЁ раз в ola (диагональ win) => итог x·w²,
        # нормим по Σw² — правильная свертка-с-окном, амплитуда сохраняется.
        sig = F.conv_transpose1d(frames, self.ola, stride=H).squeeze(1)   # (B, L)
        ones = torch.ones(B, N, T, device=frames.device, dtype=frames.dtype)
        wsum = F.conv_transpose1d(ones, self.wsum, stride=H).squeeze(1)
        # где окно не покрывает отсчёт — оставляем sig как есть (без деления на 0);
        # эпсилон в знаменателе не даёт DivBackward0 уйти в nan на рёбрах.
        return torch.where(wsum > 1e-5, sig / (wsum + 1e-6), sig)     # (B, L)

    def forward(self, mel):
        """mel: (B, in_ch, T) -> wav: (B, (T-1)*hop + N)"""
        x = self.pre(mel)                                # (B, d, T)
        for blk in self.convs:
            x = blk(x)
        h = self.head(x)                                 # (B, 2F, T)
        h = h.float()                                    # complex/irfft работают во fp32 (не bf16)
        zc = torch.complex(h[:, :self.F], h[:, self.F:]) # (B, F, T)
        return self._istft(zc).float()


# ----------------------------------------------------------------------------
# Общая модель
# ----------------------------------------------------------------------------

class Vits(nn.Module):
    def __init__(self, vocab=190, d=192, n_mels=80, vd=128, ken_layers=4,
                 voc_layers=6, voc_nfft=1024, voc_hop=256):
        super().__init__()
        self.d = d
        self.voc_hop = voc_hop
        self.enc = TextEncoder(vocab, d=d, layers=ken_layers)
        self.pe = PosteriorEncoder(n_mels, d)
        self.dp = DurationPredictor(d)
        self.dec = Decoder(d, n_mels)
        self.gen = VocosLite(n_mels, d=vd, layers=voc_layers, nfft=voc_nfft, hop=voc_hop)
        self.align_proj = nn.Linear(n_mels, d)

    def forward(self, ids, txt_len, mel=None, mel_len=None, eps=1.0):
        he = self.enc(ids, txt_len)                       # (B,d,L)
        if mel is not None:
            mu, logv = self.pe(mel)                       # (B,d,T)
            z = mu + torch.randn_like(mu) * torch.exp(logv * 0.5) * eps
            mel_pred = self.dec(z)
            align = self._align(he, mel, txt_len, mel_len)
            dur = align.sum(-1)                           # (B,L) длительности из align
            log_dur = self.dp(he)
            dur_hard = (dur + 0.5).long()                 # детерминированная (non-diff) развёртка
            z_up, mel_text_len = self._expand(he, dur_hard, txt_len)
            mel_text = self.dec(z_up)                     # декодер на «жёстких» эмбеддингах токенов
            wav_gen = self.gen(mel)                       # вокодер на GT-меле -> wav
            return {"mel": mel_pred, "mel_text": mel_text, "mu": mu, "logv": logv,
                    "align": align, "dur": dur, "log_dur": log_dur, "z": z,
                    "mel_text_len": mel_text_len, "wav": wav_gen}
        else:
            log_dur = self.dp(he)                         # (B,L)
            dur = torch.exp(log_dur.clamp(max=6.0)) - 1.0
            dur = torch.max(dur, torch.ones_like(dur))
            z_up, _ = self._expand(he, dur, txt_len)      # (B,d,sum_dur)
            mel_text = self.dec(z_up)                     # (B,80,sum_dur)
            wav = self.gen(mel_text)                      # (B, (sum_dur-1)*hop + N)
            return {"mel": mel_text, "dur": dur, "wav": wav}

    def _expand(self, he, dur, txt_len):
        """Жёсткая развёртка эмбеддингов текста по длительностям (кадр=1 шаг).

        Общая для тренировки и инференса: расширяем каждый токен на его
        длительность и собираем z_up[frame] = he[token(frame)]. Длина = sum(dur).
        Возвращает (z_up, tots), где tots — факт. длина каждого сэмпла (кадров).
        dur — недифференцируемый источник: градиент к предсказателю длительностей
        идёт через отдельную супервизию duration_loss.
        """
        B, d, L = he.shape
        dur = dur.float()
        tots = torch.zeros(B, dtype=torch.long, device=he.device)
        rows = []; max_tot = 1
        for i in range(B):
            tl = int(txt_len[i].item())
            c = torch.cumsum(dur[i, :tl], 0)
            tot = max(int(c[-1].round()) if tl > 0 else 1, 1)
            tots[i] = tot
            tt = torch.arange(tot, device=he.device)
            rows.append(torch.searchsorted(c, tt, right=True).clamp(max=tl - 1))
            max_tot = max(max_tot, tot)
        idx = torch.zeros(B, max_tot, dtype=torch.long, device=he.device)
        for i in range(B):
            idx[i, :int(tots[i])] = rows[i]
            idx[i, int(tots[i]):] = int(txt_len[i]) - 1   # безвредный батч-пад
        idx = idx.clamp(max=L - 1)
        z_up = torch.gather(he, 2, idx.unsqueeze(1).expand(B, d, -1))
        return z_up, tots

    def _align(self, he, mel, txt_len, mel_len):
        h = he.transpose(1, 2)                            # (B,L,d)
        meln = self.align_proj(mel.transpose(1, 2))       # (B,T,d)
        meln = meln / (meln.norm(dim=2, keepdim=True) + 1e-6)
        A = torch.bmm(h, meln.transpose(1, 2)) / (h.norm(dim=2, keepdim=True) + 1e-6)
        mask_t = torch.arange(A.size(2), device=A.device)[None, :] >= mel_len[:, None]
        mask_l = torch.arange(A.size(1), device=A.device)[None, :] >= txt_len[:, None]
        A = A.masked_fill(mask_t.unsqueeze(1), -1e9).masked_fill(mask_l.unsqueeze(2), -1e9)
        A = torch.softmax(A, dim=1)
        # паддинг-колонки мела (t >= mel_len) дали бы uniform 1/L -> обнуляем,
        # чтобы dur = align.sum(-1) считал только реальные кадры
        A = A * (~mask_t).unsqueeze(1).to(A.dtype)
        return A


# ----------------------------------------------------------------------------
# Потери
# ----------------------------------------------------------------------------

def _resample_to_length(x, L):
    if x.shape[-1] == L:
        return x
    was_1d = x.dim() == 1
    if was_1d:
        x = x.unsqueeze(0)                               # (1, Lx)
    y = F.interpolate(x.unsqueeze(1), size=L, mode="linear", align_corners=False).squeeze(1)
    return y[0] if was_1d else y


def vocoder_loss(wav_pred, wav, wav_len, mel_len, hop=256, nfft=1024,
                 fft_sizes=(512, 1024, 2048)):
    """L1 waveform + multi-resolution STFT (пакетно, но с корректным попарным сравнением).

    Для каждого сэмпла берём ТОЛЬКО реальный сегмент прогноза (по mel_len кадрам,
    без паддинг-мусора), затем и прогноз, и целевой wav ресемплим к общей длине
    L_common = min(длина прогноза, длина цели) на батч — темп совпадает,
    сравнение честное. STFT считается одним батчем на весь L_common.
    Спектральная часть: spectral convergence (норм.) + log-L1 + комплексная L1
    (комплексная L1 анти-wrapping по построению, включает фазу).
    Возвращает (l1_time, spec).
    """
    B = wav_pred.shape[0]
    if B == 0:
        return 0.0, 0.0
    Lgens = (mel_len - 1) * hop + nfft                     # реальные кадры прогноза (кадр=hop)
    valid = (mel_len > 0) & (wav_len > 0) & (wav.shape[1] > 0)
    if not valid.any():
        return 0.0, 0.0
    # общая длина: мин. по валидным сэмплам из (длина прогноза, длина цели)
    L_common = int(min(torch.min(Lgens[valid]).item(), torch.min(wav_len[valid]).item()))
    L_common = max(L_common, 1)
    prs = []; tgs = []
    for b in range(B):
        if not valid[b]:
            continue
        prs.append(_resample_to_length(wav_pred[b, :int(Lgens[b])], L_common))
        tgs.append(_resample_to_length(wav[b, :int(wav_len[b])], L_common))
    pr = torch.stack(prs).to(wav.dtype)                    # (B', L_common)
    tgt = torch.stack(tgs).to(wav.dtype)                   # (B', L_common)
    l1 = (pr - tgt).abs().mean()
    sc = 0.0; lm = 0.0; cl = 0.0; ns = 0
    dev = wav.device
    for nfft_f in fft_sizes:
        win_t = torch.hann_window(nfft_f, device=dev, dtype=wav.dtype)
        S = torch.stft(tgt, nfft_f, hop_length=nfft_f // 4, center=True,
                       window=win_t, return_complex=True)
        Sp = torch.stft(pr, nfft_f, hop_length=nfft_f // 4, center=True,
                        window=win_t, return_complex=True)
        m = S.abs(); mp = Sp.abs()
        sc += (m - mp).pow(2).sum().sqrt() / (m.sum() + 1e-6)   # норм. spectral conv (здесь sqrt поверх суммы)
        lm += (torch.log(m.clamp_min(1e-5)) - torch.log(mp.clamp_min(1e-5))).abs().mean()
        cl += (Sp - S).abs().mean()                          # фаза+амплитуда, анти-wrapping
        ns += 1
    return l1, (sc + lm + cl) / max(ns, 1)


def duration_loss(log_pred, dur_true, txt_len):
    """log_pred:(B,L) лог-домен предсказание; dur_true:(B,L) целые длительности."""
    m = torch.arange(dur_true.shape[1], device=dur_true.device)[None, :] < txt_len[:, None]
    t = torch.log(dur_true.float() + 1.0)
    d = (log_pred - t).pow(2).masked_fill(~m, 0)
    return d.sum() / (m.sum().clamp(min=1))


def vits_loss(out, mel, txt_len, mel_len, text_w=0.5, kl_w=0.0,
              w_dur=0.1, w_voc=1.0, wav=None, wav_len=None, hop=256, nfft=1024):
    m = torch.arange(mel.shape[2], device=mel.device)[None, :] < mel_len[:, None]
    mask = ~m.unsqueeze(1)
    d2 = (out["mel"] - mel).pow(2).masked_fill(mask, 0)
    loss = d2.sum() / (m.sum().clamp(min=1) * mel.shape[1])
    if out.get("mel_text") is not None:
        # mel_text имеет длину = sum(dur) (~=mel_len на сэмпл) — сравниваем посегментно
        mt = out["mel_text"]; tts = out.get("mel_text_len")
        l_txt = 0.0
        for b in range(mel.shape[0]):
            Lm = int(mel_len[b].item()); Lt = int(tts[b].item()) if tts is not None else mt.shape[2]
            seg = mt[b:b + 1, :, :Lt]
            if Lt != Lm:
                seg = F.interpolate(seg, size=Lm, mode="linear", align_corners=False)
            l_txt += (seg - mel[b:b + 1, :, :Lm]).pow(2).mean()
        loss = loss + text_w * l_txt / max(mel.shape[0], 1)
    if kl_w > 0 and "mu" in out and "logv" in out:
        loss = loss + kl_w * (-0.5 * (1 + out["logv"] - out["mu"].pow(2) - out["logv"].exp()).sum()) / mel.shape[0]
    if "log_dur" in out and "dur" in out:
        loss = loss + w_dur * duration_loss(out["log_dur"], out["dur"], txt_len)
    if wav is not None and wav_len is not None and "wav" in out:
        l1, sp = vocoder_loss(out["wav"], wav, wav_len, mel_len, hop=hop, nfft=nfft)
        loss = loss + w_voc * (l1 + sp)
    return loss


def main():
    torch.manual_seed(0)
    import json
    man = json.load(open("model/data/manifest.json", encoding="utf-8"))
    V = len(man["tokenizer"]["symbols"])
    model = Vits(V, d=96, n_mels=80, vd=64)
    ids = torch.randint(2, V, (2, 40)); txt_len = torch.tensor([20, 15])
    mel = torch.randn(2, 80, 200); mel_len = torch.tensor([200, 150])
    wav = torch.randn(2, 200 * 256 + 1024); wav_len = torch.tensor([200 * 256 + 1024] * 2)
    out = model(ids, txt_len, mel=mel, mel_len=mel_len)
    loss = vits_loss(out, mel, txt_len, mel_len, kl_w=0.1, wav=wav, wav_len=wav_len)
    loss.backward()
    out2 = model(ids[:1], torch.tensor([15]))
    print("forward+backward OK; mel_pred", tuple(out["mel"].shape),
          "wav_pred", tuple(out["wav"].shape),
          "loss", round(loss.item(), 4), "| infer wav", tuple(out2["wav"].shape))


if __name__ == "__main__":
    main()