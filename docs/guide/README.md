# Руководство по проекту (docs/guide)

Это лёгкое, структурированное руководство по tdot-акселератору (FPGA XDMA + DDR3),
его устройству, написанию программ, host-софту, сборке/прошивке и TTS-модели.
Старые AUIDT/CHANGE_LOG`и остаются в `docs/` для истории; здесь — текущее состояние.

## Оглавление

1. **[01-architecture.md](01-architecture.md)** — Обзор и аппаратная архитектура.
2. **[02-tdot-engine.md](02-tdot-engine.md)** — Движок dot (ядро, точность, длинные dot).
3. **[03-device-prog.md](03-device-prog.md)** — Как написать программу слоёв (unit-таблица, батч, цепочки, ограничения).
4. **[04-host-software.md](04-host-software.md)** — Хост-софт: драйвер, DMA, скрипты, лимиты.
5. **[05-data-path-deadlock.md](05-data-path-deadlock.md)** — Data-путь: почему вешался и как починен.
6. **[06-train-and-bench.md](06-train-and-bench.md)** — Обучение на FPGA, бенч FPGA vs CPU, пропускная способность.
7. **[07-tts-model.md](07-tts-model.md)** — Текст-в-аудио модель (`model/`).
8. **[08-build-flash.md](08-build-flash.md)** — Сборка прошивки и прошивка платы.

## Быстрый старт (коротко)

- **Плата (рабочий конфиг):** NUM_MAC=32, ADDERS=8, DEVPROG_EN=1 (CORE_PARAMS=0x820),
  data-путь синхронный (без async-конвертера). Device_prog, DDR, обучение работают.
- **Проверить плату:**
  ```
  python scripts/probe_core.py
  python scripts/obs_smi.py --once
  ```
- **Один dot через device_prog (ожид. 3.5):**
  ```
  python scripts/test_dprog_single_dot.py
  ```
- **Обучение MLP по датасету через batched device_prog:**
  ```
  python scripts/train_dprog_batch_mlp.py --epochs 8 --batch 32 --samples 1000 --lr 0.1 --seed 0
  ```
- **Сравнение FPGA vs CPU + пропускная способность:** `docs/06-train-and-bench.md`.
- **Написать свою программу слоёв:** `docs/03-device-prog.md`.
- **Собрать/прошить:** `docs/08-build-flash.md`.

## Ключевые понятия (сводка)

- **tdot** — ядро-акселератор точечных произведений (`dot`) над числами TFloat48
  (тройная мантисса 40 тритов + экспонента 3^x). Один dot ширины `n` = произведение накопителей.
- **NUM_MAC** — число параллельных умножителей; **ADDERS** — число параллельных аддеров дерева редукции.
- **MAX_N_TOTAL = MAX_PASSES(32) × NUM_MAC** — потолок ширины одного dot (на 32/8 = 1024).
- **device_prog** — интерпретатор «программы слоёв» в DDR: читает unit-таблицу, сам
  разворачивает её в dot-задачи и пишет результаты + mailbox-статус.
- **DMA-каналы** — host пишет/читает DDR через h2c/c2h; устойчивая пропускная ~70 MB/s.