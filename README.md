# TFloat48 Ternary FP Accelerator — XDMA + DDR3 (Artix-7 XC7A200T, M.2 PCIe)

Троичный FP-акселератор **TFloat48** на M.2-плате (Artix-7 XC7A200T): хосту доступен через
PCIe (XDMA), память DDR3, ядро считает скалярные произведения (`dot`) для GEMM/нейросетей.

> **Полное руководство: [`docs/guide/README.md`](docs/guide/README.md)** — оглавление и разделы
> (архитектура, движок, написание программ, host-софт, data-путь, тренинг/бенч, TTS, сборка).

## ✅ Актуальное состояние (2026-10-26)

- **Плата (рабочая прошивка): `NUM_MAC=32, ADDERS=8, DEVPROG_EN=1`** → `CORE_PARAMS=0x820`.
- **Data-путь синхронный, без async-конвертера**: `SMC.M00(100МГц)→regslice→MIG(100МГц)`.
  Убран `axi_clock_converter` (он давал deadlock под крупными DMA-бурстами). `ui_clk=100`.
- **Работает:** device_prog (single/batch/chain), DDR-стресс 256КиБ бит-в-бит, обучение MLP
  по датасету (MSE 0.85→0.31), DMA ~70 MB/s.
- **Порог dot:** `MAX_N_TOTAL = MAX_PASSES(32) × NUM_MAC(32) = 1024` (скрытый слой H ≤ 1024).
- **64-MAC** на этом Artix-7 @125МГц на пределе тайминга (нужен перепилинг ядра) — рабочий конфиг 32/8.

Проверка:
```cmd
python scripts/probe_core.py
python scripts/obs_smi.py --once --interval 0.5
python scripts/test_dprog_single_dot.py        % device_prog 3.5
python scripts/train_dprog_batch_mlp.py --epochs 3 --batch 32 --samples 256 --lr 0.1 --seed 0
```

## Формат TFloat48
- 48 бит = 6 байт; мантисса ~20 тритов (цифры в {-1,0,1}), экспонента — множитель 3^x.
- Точность ~3^-18 ≈ 5.2e-9 (~в 22 раза точнее float32). Вся арифметика на LUT (DSP=0).

## Как написать программу для платы (device_prog)
Документация — **[`docs/guide/03-device-prog.md`](docs/guide/03-device-prog.md)**:
формат unit-таблицы (W0-W3), `n_in<<48`, n_batch, src=prev/pass, окно адресов, mailbox,
ограничения (H≤1024, B·H·8≤mem), шаги написания своей программы. Примеры: `scripts/test_dprog_single_dot.py`.

## Карта адресов (кратко)
Полная — [`docs/guide/01-architecture.md`](docs/guide/01-architecture.md) / `docs/ADDRESS_MAP.md`.
| Модуль | Адрес |
|---|---|
| DataMover MM2S / S2MM | 0x4001_0000 / 0x4001_8000 |
| AXI GPIO (MIG status) | 0x4002_0000 |
| **TDOT (ядро+OBS)** | **0x4002_3000** |
| XADC | 0x4600_0000 |
| diag-BRAM | 0x1000_0000 (8К) |
| DDR3 (DMA/ядро) | 0x8000_0000 (256МБ) |

## Драйвер и производительность
- Windows DMA-драйвер `XDMA_DMA.sys` v1.2.7 (`\\.\XDMA0dma\{control,user,h2c_0..,c2h_0..}`).
- Устойчивая пропускная способность host↔DDR через h2c/c2h: **~70 MB/s** (запись ≈72, чтение ≈66).
- Признак «XDMA-узел не открывается / устройство Unknown» → перезагрузка хоста (ресканирование PCIe).

## Сборка и прошивка
Полная инструкция — [`docs/guide/08-build-flash.md`](docs/guide/08-build-flash.md).
```cmd
REM рабочая прошивка 32/8:
C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch ^
  -source scripts\build_flat.tcl -tclargs NUM_MAC=32 ADDERS=8 DEVPROG_EN=1 JOBS=4 -nojournal
REM прошивка QSPI:
C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch ^
  -source scripts\flash_program.tcl -tclargs build\artifacts_flat\xdma_ddr3_core_top.mcs
```

## Состав репозитория (ключевое)
| Каталог | Содержимое |
|---|---|
| `rtl/block/` | Ядро: `tbyte_add/mul`, `tfmul_raw`, `tfadd_raw`, `tfadd48`, `compute_dot_par_raw` |
| `rtl/integration/` | `tdot_axi4.sv` (AXI4-мастер+планировщик+OBS+device_prog), топ, XADC |
| `scripts/` | `build_flat.tcl`, `xdma_ddr3_bd.tcl`, probe/obs/device_prog/train/bench — см. `docs/guide/04-host-software.md` |
| `pytorch_layer/` | Host-софт: `xdma_driver.py`, `test_dma_win.py` и др. |
| `model/` | Текст-в-аудио модель (VITS) — `docs/guide/07-tts-model.md` |
| `docs/guide/` | **Актуальное руководство** (этот файл — оглавление) |
| `docs/` (прочее) | Исторические CHANGE_LOG / AUDIT — для ретроспективы |

## Верификация
```bash
python scripts/probe_core.py
python scripts/obs_smi.py --once
python scripts/test_dprog_single_dot.py
python -m pytest ternary_sw/tests/ -q
```

## История
Исторические (устаревшие) данные/задачи перенесены в `docs/CHANGE_LOG_*.md` и worklog —
актуальная истина — в `docs/guide/` и в этом README.