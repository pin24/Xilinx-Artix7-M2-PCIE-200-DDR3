#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""data_prep.py — подготовка датасета текста-в-аудио под VITS2 (без BERT).

Исходники:
  E:\\waves\\<N>.wav                       аудио (24kHz mono)
  E:\\cacheE\\dataset_items.json           список {audio_path, line_num, original_idx, text}
  E:\\cacheE\\mel\\<N>.npy                 80-биновые мел-спектрограммы (24kHz)
  E:\\cacheE\\bert\\<N>.npy                BERT-эмбеддинги (НЕ используем в модели — только держим путь
                                            на случай будущего conditioning)
  E:\\cacheE\\tokenizer.json               char-токенизатор (178 символов + спец.)

Действия: чинит префикс audio_path (/media/pin240/... -> E:\\waves), сопоставляет
мел/bert по номеру wav, проверяет целостность (wav/mel/bert существуют, формы согласованы),
строит train/val сплит и сохраняет model/data/manifest.json.
Использование: python model\\data_prep.py [--out model/data/manifest.json] [--val 0.01] [--seed 0]
"""
import os, json, sys, glob, argparse
import numpy as np

WAVES_DIR   = r"E:\waves"
CACHE_DIR   = r"E:\cacheE"
MEL_DIR     = os.path.join(CACHE_DIR, "mel")
BERT_DIR    = os.path.join(CACHE_DIR, "bert")
KEYS_JSON   = os.path.join(CACHE_DIR, "dataset_items.json")
TOK_JSON    = os.path.join(CACHE_DIR, "tokenizer.json")
OLD_PREFIX  = "/media/pin240/ssd 512/waves/"
NEW_PREFIX  = "E:\\waves\\"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="model/data/manifest.json")
    ap.add_argument("--val", type=float, default=0.01)
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()

    items = json.load(open(KEYS_JSON, encoding="utf-8"))
    tok = json.load(open(TOK_JSON, encoding="utf-8"))
    print(f"items={len(items)} tok_symbols={len(tok['symbols'])}")

    # проверим токенизатор: каждый символ текста есть в словаре
    vocab = set(tok["symbols"])
    missing = set()
    for it in items[:5000]:
        for ch in it["text"]:
            if ch not in vocab and ch != " ":   # пробел обычно = space_id
                missing.add(ch)
    print("символы вне словаря (первые):", sorted(list(missing))[:20] if missing else "нет")

    ok, bad = 0, 0
    bad_examples = []
    for i, it in enumerate(items):          # i = original_idx (0-баз., ключ BERT!)
        it["text"] = str(it["text"]).strip()
        ap_ = it["audio_path"]
        if ap_.startswith("/"):
            ap_ = NEW_PREFIX + os.path.basename(ap_)     # чиним префикс
            it["audio_path"] = ap_
        num = os.path.splitext(os.path.basename(ap_))[0]
        it["wav"] = ap_
        it["mel"] = os.path.join(MEL_DIR, num + ".npy")   # ключ по номеру wav
        it["bert"] = os.path.join(BERT_DIR, f"{it.get('original_idx', i)}.npy")  # ключ по original_idx
        it["n_frames"] = int(np.load(it["mel"]).shape[1]) if os.path.exists(it["mel"]) else -1
        if (os.path.exists(it["wav"]) and os.path.exists(it["mel"])
                and os.path.exists(it["bert"]) and it["n_frames"] > 0):
            ok += 1
        else:
            bad += 1
            if len(bad_examples) < 5:
                bad_examples.append((it["audio_path"], it["mel"], it["bert"], it["n_frames"]))
    print(f"OK={ok} BAD={bad}")
    if bad_examples:
        print("примеры плохих:", bad_examples)

    # проверка формы мелов
    shapes = {}
    for it in items[:2000]:
        s = tuple(np.load(it["mel"]).shape)
        shapes[s] = shapes.get(s, 0) + 1
    print("формы мел (первые 5):", sorted(shapes.items(), key=lambda x: -x[1])[:5])

    # train/val
    rng = np.random.default_rng(a.seed)
    idx = rng.permutation(len(items))
    n_val = max(1, int(len(items) * a.val))
    val_i = set(idx[:n_val].tolist())
    good = [it for it in items if it["n_frames"] > 0]
    train = [it for i, it in enumerate(good) if i not in val_i]
    val = [it for i, it in enumerate(good) if i in val_i]
    manifest = {"tokenizer": tok, "meta": {
        "sr": 24000, "n_mels": 80, "mean": None, "std": None,
        "note": "VITS2 без BERT; mel 80-bin @24kHz; char-токены (свой эмбеддинг)",
    }, "train": train, "val": val}
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    json.dump(manifest, open(a.out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"манифест: {a.out} train={len(train)} val={len(val)}")

if __name__ == "__main__":
    main()