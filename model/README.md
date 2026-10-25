# model/ — VITS-модель «текст → аудио» (без BERT), лёгкая и высококачественная

## Цель
Текст → речь на вашем русском датасете (91 668 пар: `E:\waves` + `E:\cacheE`).
Конвейер выбран под «высокое качество при низких накладных»:
одна **VITS-модель** (text→mel→waveform), вход — только **char-токены** (178 символов,
свои эмбеддинги, **без BERT**), далее **HiFi-GAN-подобный генератор** (mel→wav) и
экспорт в **ONNX FP16/INT8** для CPU real-time (цель RTF 0.1–0.5, размер ~5–20 МБ).

## Состав
| Файл | Назначение |
|---|---|
| `data_prep.py` | чинит пути датасета (`/media/...` → `E:\waves`), сопоставляет mel(по №wav)/bert(по original_idx), валидирует, строит манифест train/val. Проверено: OK=91668/0 BAD. |
| `data.py` | Dataset/Collate: text(char ids) → mel (80, T). Проверено: batch (4,125)+(4,80,581), vocab 178. |
| `vits.py` | Модель: char-эмб + TextEncoder(FFT) → alignment vs mel → Decoder(mel) + Generator(HiFi-style) + Discriminator. Forward/backward и infer-путь смоuk-tested. |
| `train.py` | Обучение (AdamW, L1+текстовая реконструкция, опц. KL/adversarial). `--steps` для быстрой пробы на CPU. |
| `infer.py` | Текст → char-токены → mel → wav (встроенный генератор, 24 кГц). Смоuk: «Привет» → mel(80×160) → wav. |
| `checkpoints/`, `samples/` | выход чекпойнтов и демо-аудио. |

## Запуск
```
python model\data_prep.py
python model\train.py --epochs 10 --batch 8 --d 192          # GPU; день обучения
python model\train.py --steps 3 --device cpu                 # проба на CPU
python model\infer.py --text "Мне надо выспаться." --ckpt model/checkpoints/vits.pt
```

## Рецепт обучения (для качества)
- **Data**: в нормировке mel используем `E:\cacheE\mel_stats.npz` (mean/std per-bin).
- **Потери**: L1 (реконструкция mel) + текстовая реконструкция через alignment + опц. KL(VITS posterior/prior) + adversarial (дискриминатор на waveform).
- **Скорость/размер**: после сходимости — **дистилляция** до ~10М (по образцу tiny-tts 1.6М / Kokoro 82М) и **ONNX FP16**; цель RTF на CPU 0.1–0.5.
- **Вокодер**: встроенный генератор достаточен; при желании сравнить с Vocos/MB-iSTFT (ещё быстрее) / HiFi-GAN-претрейн.

## Пояснения к выбору
См. исследование: кодек-LM (VALL-E-стиль) даёт топ-качество и zero-shot, но требует
сотни тысяч часов и медлен на CPU — против вашей цели. VITS (Piper/VITS2) — лучший
баланс «русский + свои данные + мало/быстро/качественно без BERT». tiny-tts
(1.6М/3.4МБ ONNX, 53× realtime CPU) — ориентир по финальному размеру, но английский
и без публичного кода обучения.

## Статус
Скелет собран и проверен: данные грузятся (91668/0), модель обучается (forward+backward),
infer выдаёт wav. Для реальной речи требуется полноценный GPU-тренинг (часы) — см. выше.