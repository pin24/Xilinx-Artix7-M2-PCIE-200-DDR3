#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""data.py — Dataset/Collate под VITS2 (без BERT): text(char tokens) -> mel (80 bin).

Берёт манифест model/data/manifest.json (собран data_prep.py). Каждая пара несёт
text, wav, mel(80,frames), bert(НЕ используем), n_frames. Возвращает батч:
  text_ids, text_len, mel, mel_len, wav(optional)
Токенизация: char-уровень по tokenizer.json symbols (178; pad/unk/bos/eos/space).
"""
import os, json, sys
import torch
import numpy as np
from torch.utils.data import Dataset

SPECIAL = {"<pad>": 0, "<unk>": 1, "<bos>": 2, "<eos>": 3, "<space>": 4}

def load_tokenizer(tok_path):
    t = json.load(open(tok_path, encoding="utf-8"))
    syms = t["symbols"]
    stoi = {s: i for i, s in enumerate(syms)}
    assert stoi[" " if " " in stoi else "<space>"] >= 0
    return stoi, len(syms)

class TTSPair(Dataset):
    """Ленивый датасет: хранит только манифест, аудио/мел читает с диска на лету.

    Никаких массивов в памяти не держим (lazy); каждое обращение к __getitem__
    грузит мел и (опционально) wav с диска. Соответствие кадров mel->wav делается
    в loss/вокодере через коэффициент кадров (см. vits.py), поэтому здесь длина
    wav не меняется — отдаём как есть.
    """
    def __init__(self, manifest_path, split="train", tokenizer=None, load_wav=False):
        self.m = json.load(open(manifest_path, encoding="utf-8"))
        self.items = self.m[split]
        tok = tokenizer or self.m["tokenizer"]
        self.stoi, self.vocab_size = load_tokenizer_from(tok)
        self.load_wav = load_wav
    def __len__(self):
        return len(self.items)
    def __getitem__(self, i):
        it = self.items[i]
        mel = np.load(it["mel"]).astype(np.float32)          # (80, T)
        ids = [self.stoi.get(ch, self.stoi.get("<unk>", 1)) for ch in it["text"]]
        ids = [self.stoi.get("<bos>", 2)] + ids + [self.stoi.get("<eos>", 3)]
        out = {"ids": np.asarray(ids, np.int64), "mel": mel,
               "n_frames": mel.shape[1], "text": it["text"]}
        if self.load_wav:
            import soundfile as sf
            x, sr = sf.read(it["wav"], dtype="float32")
            x = torch.from_numpy(x).unsqueeze(0)             # (1, T_audio)
            out["wav"] = x
            out["wav_len"] = torch.tensor(x.shape[1], dtype=torch.long)
        return out

def load_tokenizer_from(tok):
    syms = tok["symbols"]
    stoi = {s: i for i, s in enumerate(syms)}
    # пробел: в symbols есть '<space>'; если сам пробел присутствует — берём его
    if " " in stoi and "<space>" in stoi:
        stoi[" "] = stoi["<space>"]
    return stoi, len(syms)

def collate(batch):
    b = len(batch)
    max_t = max(x["mel"].shape[1] for x in batch)
    max_l = max(len(x["ids"]) for x in batch)
    mel = torch.zeros(b, 80, max_t); mel_len = torch.zeros(b, dtype=torch.long)
    ids = torch.zeros(b, max_l, dtype=torch.long); txt_len = torch.zeros(b, dtype=torch.long)
    for i, x in enumerate(batch):
        m = torch.from_numpy(x["mel"]); mel[i, :, :m.shape[1]] = m; mel_len[i] = m.shape[1]
        t = torch.as_tensor(x["ids"]); ids[i, :t.shape[0]] = t; txt_len[i] = t.shape[0]
    out = {"ids": ids, "txt_len": txt_len, "mel": mel, "mel_len": mel_len}
    if "wav" in batch[0]:
        max_w = max(x["wav"].shape[1] for x in batch)
        wav = torch.zeros(b, max_w); wav_len = torch.zeros(b, dtype=torch.long)
        for i, x in enumerate(batch):
            wav[i, :x["wav"].shape[1]] = x["wav"][0]; wav_len[i] = x["wav"].shape[1]
        out["wav"] = wav; out["wav_len"] = wav_len
    return out

def make_loaders(manifest="model/data/manifest.json", batch=8, split="train", shuffle=True, load_wav=False):
    d = TTSPair(manifest, split=split, load_wav=load_wav)
    return torch.utils.data.DataLoader(d, batch_size=batch, shuffle=shuffle,
                                       collate_fn=collate, num_workers=0), d

if __name__ == "__main__":
    dl, ds = make_loaders(batch=4, split="val")
    b = next(iter(dl))
    print("batch:", {k: tuple(v.shape) if torch.is_tensor(v) else v for k, v in b.items()})
    print("vocab_size =", ds.vocab_size)