# TFloat48 Ternary FP Accelerator — XDMA + DDR3 + BRAM (Artix-7 XC7A200T, M.2 PCIe)

Троичный FP-ускоритель **TFloat48** на плате M.2 (Xilinx Artix-7 XC7A200T),
доступный хосту через PCIe (XDMA) с памятью DDR3 и диагностическим BRAM.
Ветка `2ch-pipeline`. Сборка — **только FLAT** (DFX полностью удалён).

## Формат TFloat48
- 48 бит = 6 байт, блоки по 4 трита (1 байт).
- Мантисса M = 20 тритов (нормализована [3^18, 3^19)), экспонента E = 4 трита (bias 40).
- Точность мантиссы 3^-18 ≈ 5.2e-9 (~в 22 раза точнее float32).
- Вся арифметика на LUT: DSP = 0, BRAM ≈ 10%.
- Формат элементов в памяти задаётся `ELEM_FMT` (CAPS[19:17]):
  `0`=legacy tf48 (8 Б), `1`=fp32 (4 Б, **нереализуемо на чипе**, host-конверсия),
  `2`=PACKED6 tf48 (6 Б). — см. `docs/ADDRESS_MAP.md` §3.2.

## Архитектура FLAT (без DFX)

Static design на **одном полном битстриме** (`build_flat.tcl`):

- **XDMA** (PCIe): BAR0 AXI-Lite 128 МБ (периферия), DMA-каналы для данных,
  MSI-X на BAR2.
- **MIG DDR3** `0x80000000` — 256 МБ.
- **diag_bram** `0x10000000` — 8 КБ (диагностика read-пути ядра без MIG).
- **tdot_axi4** — троичное ядро: AXI4-мастер читает data/weights из DDR3/BRAM +
  AXI-Lite регистры.
- **XADC** — температура/VCCINT.

Ядро tdot ходит в память через **один AXI4 master**; выбор DDR3 vs BRAM —
декодом адреса в SmartConnect (`0x80000000`→MIG, `0x10000000`→diag_bram_ctrl).

## Два набора DMA-каналов на хосте

| Назначение | Узел (Windows) | translateAxiBase | Хост шлёт |
|---|---|---|---|
| DDR3 запись | `\\.\XDMA0dma\h2c_0..3` | TRUE | raw-смещение от `0x80000000` |
| DDR3 чтение | `\\.\XDMA0dma\c2h_0..3` | TRUE | raw-смещение от `0x80000000` |
| BRAM запись | `\\.\XDMA0dma\h2c_bram_0` | FALSE | полный картовый адрес (`0x10000000+`) |
| BRAM чтение | `\\.\XDMA0dma\c2h_bram_0` | FALSE | полный картовый адрес (`0x10000000+`) |

⚠ Флаги живут на общем движке channel 0 — BRAM- и DDR3-каналы одного
направления нельзя использовать одновременно в одном потоке. См. §1.2
в `docs/ADDRESS_MAP.md`.

## Состав репозитория
| Каталог | Содержимое |
|---|---|
| `rtl/block/` | Ядро: `tbyte_add/mul.sv`, `tfmul_raw.sv`, `tfadd_raw.sv`, `compute_dot_par_raw.sv`, PACKED6 |
| `rtl/integration/` | `tdot_axi4.sv` (AXI4-мастер + AXI-Lite, ядро), `xadc_temp.sv`, `xdma_ddr3_core_top.sv` |
| `constraints/` | XDC: `xdma_ddr3_pins.xdc`, `xdma_ddr3_early.xdc` |
| `scripts/` | `build_flat.tcl` — главная сборка (synth+impl+bitstream+artifacts), `post_bd_flat.tcl` |
| `pytorch_layer/` | Хост-софт: `xdma_driver.py`, `test_dma_win.py`, `monitor_temp.py`, `bench_dma_serial.py` |
| `ternary_sw/` | Python-эталон арифметики TFloat48 (arith48) + тесты |
| `driver/, xdma_driver_win_src_2017/` | Windows KMDF-драйвер XDMA_DMA + test_xdma.exe |
| `docs/` | `ADDRESS_MAP.md` (карта адресов), `AUDIT_FULL_*.md`, `OBSERVABILITY.md`, `worklog.md` |

## Карта адресов (FLAT-BD, PCIe BAR0 128 МБ)

Подробная карта: [`docs/ADDRESS_MAP.md`](docs/ADDRESS_MAP.md).

| Модуль | Адрес | Размер | Примечание |
|---|---|---|---|
| DataMover MM2S/S2MM ctrl | 0x4001_0000 / 0x4001_8000 | 4K | Контроль независимого DMA-пула |
| AXI GPIO (LED) | 0x4002_0000 | 4K | LED + MIG status |
| **TDOT registers** | **0x4002_3000** | 4K | Троичный ускоритель |
| XADC | 0x4600_0000 | 4K | Температура/напряжение |
| DDR3 (MIG) | 0x8000_0000 | 256 MB | Доступ хоста через DMA-каналы; ядра — через M_AXI_TDOT |
| BRAM (diag) | 0x1000_0000 | 8 KB | Доступ через DMA-каналы `_bram`; ядра — через M_AXI_TDOT |

> DFX Socket / ICAP / SPI / HWICAP в flat **не существуют** (удалены с DFX).
> `dfx_swap.py`, `icap_load.py` — легаси.

Данные в памяти: `data[i]`, `weights[i]` — элементы по схеме ELEM_FMT (см.
карту §6.2); результат dot — по `result_addr`.

## Верификация
- `rtl/integration/verify_tdot_axi4.py 32` — PASS (RTL == raw-модель).
- `rtl/integration/verify_tdot_axi4_packed6x.py PY` — PASS (PACKED6).
- `python scripts/bench_tdot_auto.py --unit` — PASS (паковка/конверсия).
- `python scripts/bench_tdot_auto.py --mock` — PASS (без железа).
- `python xdma_driver.py --selftest [--dot]` — PASS на железе.

## Сборка

```cmd
REM Из корня репозитория:
cd Xilinx-Artix7-M2-PCIE-200-DDR3_2chanle
make build
```

Makefile запускает `scripts/build_flat.tcl` — полная flat-сборка
(synth + impl + write_bitstream + экспорт `.bit/.bin/.mcs/.rbt`).

### Опции

```cmd
make build NUM_MAC=32 ADDERS=8 ELEM_FMT=0 JOBS=12   # legacy (32/8)
make build NUM_MAC=16 ADDERS=4 ELEM_FMT=0 JOBS=12   # legacy (16/4)
make build NUM_MAC=16 ADDERS=4 ELEM_FMT=2 JOBS=12   # PACKED6 (16/4)
make proj     # только создать проект
make clean    # очистка
```

Артефакты: `build/artifacts_flat/` (`xdma_ddr3_core_top.{bit,bin,mcs,prm,rbt}`,
`timing_summary.rpt`, `utilization.txt`). Логи — `build/logs_flat/`.

### Верификация перед сборкой

```bash
C:\Python39\python.exe rtl\integration\verify_tdot_axi4.py 32
C:\Python39\python.exe scripts\bench_tdot_auto.py --unit
```

## Драйвер Windows
Сборка: `driver/dma/build.cmd` (WDK) → `XDMA_DMA.sys`, `XDMA_DMA.inf`
(текущая версия 1.1.33.0). Установка: `pnputil /add-driver .../XDMA_DMA.inf /install`.
Тест: `test_xdma.exe`, `test_dma.exe`. Устройство: `PCI\VEN_10EE&DEV_7024`.
Хост-бэкенды: `xdma_driver.py` (XdmaWinDma/XdmaWinUpstream/XdmaWinDriver).

## Открытые задачи
- [ ] Стенд: заливка p6_a4 (PACKED6) .bit/.mcs + драйвер + `bench_tdot_auto.py --input fp32`
- [ ] Гипотеза `automatic int g` в `tf48_div_pipe.sv:94` (fp32 LUT-взрыв) — не верифицирована
- [ ] Аудит полный: `docs/AUDIT_FULL_2026-10-19.md` — реестр R1..R18; приоритеты см. там
- [ ] Какоба: obs_smi.py div-by-zero guard, file_io.c TraceError-текст
- [ ] AXI 64→128 — отложено (не bottleneck)