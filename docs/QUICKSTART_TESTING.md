# Быстрый старт: тесты, мониторинг и запуск (2026-10-20)

Актуально для прошивки **NUM_MAC=32, ADDERS=2, кольцо-1024** (подтверждено `ring_check.py`).
Все скрипты сами определяют NUM_MAC из CORE_PARAMS и глубину кольца — вручную ничего не
задавать.

---

## 1. Проверка глубины кольца — `scripts/ring_check.py`

Определяет фактическую глубину hardware-кольца перебором и проверяет корректность vs CPU.

```bat
cd /d C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3
set PYTHONIOENCODING=utf-8

REM авто-обнаружение (256/512/1024)
python scripts\ring_check.py --probe --batch 1000

REM проверить конкретную глубину
python scripts\ring_check.py --depth 1024 --batch 1000
```

Пример вывода (плата 32/2):
```
FIRMWARE: {'NUM_MAC': 32, 'ADDERS': 2, 'CORE_PARAMS': 544}
ring_depth=1024, batch=1000 -> OK (2132 задач/с)
=== фактическое кольцо на борту = 1024 (NUM_MAC=32) ===
```

## 2. Мониторинг FPGA

```bat
set PYTHONIOENCODING=utf-8   REM обязателен: дашборды печатают символ Δ

python scripts\monitor_obs.py --interval 1.0            REM дашборд
python scripts\monitor_obs.py --dot 32 --interval 1.0   REM дашборд с нагрузкой
python scripts\obs_smi.py --dot 32 --interval 0.5       REM альтернатива
```

`--num-mac` не нужен: читается из CAPS.

## 3. Обучение

```bat
REM ELM на FPGA (веса на плате, батч через кольцо), скрытый 64, 2000 пар
python data\nn_audio_train_fpga.py --hidden 64 --pairs 2000

REM обычный MLP (градиентное обучение) на CPU
python data\nn_audio_train_cpu.py --epochs 400 --batch 128 --pairs 40000

REM генерация аудио обученной моделью
python data\nn_audio_infer_fpga.py --freq 440 --limit 4000 --bench
```

## 4. Прошивка (быстрее всего)

Флеш-скрипты уже содержат `PROGRAM.UNPROTECT` (снятие защиты чипа, фикс Labtools 27-3347)
и указывают на актуальный артефакт `build/artifacts_flat/xdma_ddr3_core_top.mcs`.

```bat
REM 1) пины флеша освободить (flash_access) + UNPROTECT + стирание + программирование
vivado -mode batch -source _flash_now.tcl

REM 2) пересборка прошивки 32/2
set "PATH=C:\AMDDesignTools\2025.2\Vivado\bin;%PATH%"
vivado -mode batch -source scripts\build_flat.tcl -tclargs NUM_MAC=32 ADDERS=2 JOBS=4 -nojournal
```

Замечание: если `PROGRAM.UNPROTECT` не поддерживается частью (в `scripts/flash_program.tcl`
предупреждение о валидных свойствах) — удалите строку UNPROTECT и стирайте
`program_hw_cfgmem -erase_all -hw_cfgmem ${cfg}`.

## 5. Устройственная программа (end-to-end на плате, черновик)

Идея: слои на плате, хост шлёт `[данные] + [программа]: сколько раз прогнать данные через
слой и что вернуть`. Бит-точная модель: `data/devseq.py`; дизайн: `docs/device-prog-2026-10-20.md`.

```bat
python data\devseq.py    REM самопроверка модели (vs forward_batch, повторные проходы)
```

## 6. Функциональные тесты симуляции (RTL)

```bat
REM симуляция 32/2 (+кольцо 1024 в RTL): dot 4/4 + TEST5 align-abort
REM каталог-чистая комната: C:\Temp\gigatool\sim32x2 (regen hex -> xvlog -> xelab -> xsim)
cd C:\Temp\gigatool\sim32x2
python gen_hex.py
xvlog -sv <пути к rtl/block/*.sv + rtl/integration/tdot_axi4.sv + tb_tdot_axi4.sv>
xelab tb_tdot_axi4 -debug typical
xsim tb_tdot_axi4 -runall
REM итог: out == expected (4 случая), PASS T5
```

## 7. Проверка исходников

```bat
python -m py_compile scripts\ring_check.py data\devseq.py pytorch_layer\fpga_backend.py pytorch_layer\xdma_driver.py
make -n help    REM парсится (фикс регрессии Makefile)
```

---

Полезные факты:
- Прошивка на борту: `NUM_MAC=32, ADDERS=2`, кольцо **1024**.
- Автодетект: NUM_MAC из CORE_PARAMS, глубина кольца — правится host-параметром `ring_depth`
  (адаптивная маска `mask=depth-1`, `CH=depth-6`).
- Производительность: ~2132 задач/с на кольце 1024 (при 15 мс/IOCTL — лимит платы).
- `BUG-071`: 15 мс на host-IOCTL — не дефект, а латентность «маленькой» MDL-транзакции;
  вылечивается малой ценой submit-ов и (в перспективе) устройственным секвенсором (см. §5).