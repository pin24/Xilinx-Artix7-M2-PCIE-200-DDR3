# 07. Текст-в-аудио модель (model/)

## Цель
Текст → речь (русский) с высоким качеством при низких накладных, **без BERT**.
Архитектура выбрана по ресёрчу 2026: VITS (text→mel→waveform) + лёгкий вокодер-генератор
+ ONNX/дистилляция (ориентир tiny-tts: 1.6М параметров, 3.4МБ ONNX, 53× realtime CPU,
но английский и без открытого кода обучения — берём как цель по размеру).

## Данные
- `E:\waves` — 91 750 wav (24 кГц mono).
- `E:\cacheE` — mel (80-биновые npy), bert (не используем), tokenizer.json
  (178 символов char), dataset_items.json, mel_stats.npz, mel_lengths.npy.
- **Индексация файлов разная:** wav/mel — по номеру из `audio_path` (числа с пробелами
  1..116460); bert — по `original_idx` (0..91667). Путь чинить
  `/media/pin240/ssd 512/waves/` → `E:\waves\`.

## Состав `model/`
| Файл | Назначение |
|---|---|
| `data_prep.py` | чинит пути, мапит файлы, строит манифест train/val (91668 пар, OK/0 BAD) |
| `data.py` | Dataset/Collate: char-токены → mel (80,T) |
| `vits.py` | модель: TextEncoder(FFT) → alignment(attention) → Decoder(mel) + HiFi-генератор + дискриминатор |
| `train.py` | обучение (AdamW + tqdm-бар) |
| `infer.py` | текст → mel → wav@24кГц |
| `README.md` | схема и рецепт |

## Запуск
```
python model/data_prep.py
python model/train.py --epochs 10 --batch 16 --d 192        # GPU (RTX 3090 на машине)
python model/train.py --steps 3 --device cpu                # проба на CPU
python model/infer.py --text "Мне надо выспаться." --ckpt model/checkpoints/vits.pt
```

## Статус
Скелет собран и проверен (данные грузятся, forward+backward, infer→wav работает на смоук).
Для реальной речи нужен полноценный GPU-тренинг (часы) → затем дистилляция/ONNX до
целевых ~5–20МБ и RTF 0.1–0.5 на CPU.

## Почему не codec-LM
VALL-E-стиль (кодек-токены + авто-регрессия) даёт топ-качество и zero-shot, но требует
сотни тысяч часов предобучения, медлен на CPU и обычно conditioning через BERT — против
твоих требований (русский, свои данные 91K пар, низкие накладные, без BERT).