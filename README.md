# TFloat48 Ternary FP Accelerator — XDMA + DDR3 + DFX (Artix-7 XC7A200T, M.2 PCIe)

Проект троичного FP-ускорителя **TFloat48** на плате M.2 (Xilinx Artix-7 XC7A200T),
доступного хосту через PCIe (XDMA) c памятью DDR3, с Dynamic Function eXchange (DFX)
и интеграцией в PyTorch.

## Формат TFloat48
- 48 бит = 6 байт, блоки по 4 трита (1 байт).
- Мантисса M = 20 тритов (нормализована [3^18, 3^19)), экспонента E = 4 трита (bias 40).
- Точность мантиссы 3^-18 ≈ 5.2e-9 (~в 22 раза точнее float32).
- Вся арифметика на LUT: DSP = 0, BRAM ≈ 10%.

## Архитектура DFX

Проект использует **Dynamic Function eXchange** — partial reconfiguration через PCIe:

- **Static region** — XDMA, MIG DDR3, AXI HWICAP, DFX Socket, Clocking Wizard, GPIO
- **Reconfigurable Partition (RP)** — `dfx_partition` Block Design Container (BDC)
- **DFX Socket** — shutdown/decouple менеджеры для безопасной перезагрузки RP

Перезагрузка RP через PCIe (без JTAG):
1. Хост пишет в DFX Socket (0x40002000) → shutdown AXI buses + decouple reset
2. Хост пишет partial bitstream в HWICAP (0x40001000) или icap_ctrl (0x40004000)
3. Хост очищает DFX Socket → RP запускается с новой логикой

Всё одной командой: `python pytorch_layer/dfx_swap.py build/artifacts_dfx/*partial*.bit`
(статус сокета: `python pytorch_layer/dfx_swap.py --status`). Частичные
битстримы экспортирует сборка (build_dfx.tcl шаг 9b / gen_bitstream.tcl).

Подробности: [`xdma_ddr3_dfx_README.md`](xdma_ddr3_dfx_README.md).

## Состав репозитория
| Каталог | Содержимое |
|---|---|
| `rtl/block/` | Блочное ядро: `tbyte_add/mul.sv`, `tfmul_raw.sv`, `tfadd_raw.sv`, `compute_dot_par_raw.sv` (параллельный dot, параметр NUM_MAC) |
| `rtl/integration/` | `tdot_axi4.sv` (AXI4-мастер + AXI-Lite), `icap_ctrl.sv`, `xadc_temp.sv`, `xdma_ddr3_core_top.sv` |
| `constraints/` | XDC-файлы: `xdma_ddr3_pins.xdc` (пины), `xdma_ddr3_early.xdc` (PCIe GT-lane LOC), `pblock.xdc` (DFX RP pblock) |
| `scripts/` | `build_dfx.tcl` — главная сборка DFX, `post_bd_dfx.tcl` — постобработка BD, `build.bat` — Windows wrapper |
| `dfx_block_designs/` | `default.tcl` (DataMover loopback demo), `test.tcl` (GPIO test) — DFX Partition BDC |
| `third_party/m2-artix7-accelerator-card/` | Встроенные HDL из [rigoorozco/m2-artix7-accelerator-card](https://github.com/rigoorozco/m2-artix7-accelerator-card) (up_axi.v, datamover_ctrl.v, DataMover wrappers) |
| `pytorch_layer/` | Хост-софт: `fpga_backend.py`, `xdma_driver.py`, `icap_load.py`, `dfx_swap.py` (горячая замена RP), `ternary_dot_layer.py` |
| `ternary_sw/` | Python-эталон арифметики TFloat48 (arith48) и тесты |
| `driver/`, `xdma_driver_win_src_2017/` | Windows KMDF-драйвер XDMA + test_xdma.exe |
| `docs/` | `ADDRESS_MAP.md` (карта адресов), `ERROR_HISTORY.md` (хронология багов) |

## Карта адресов (DFX-BD, PCIe BAR0 128 МБ)

Подробная карта: [`docs/ADDRESS_MAP.md`](docs/ADDRESS_MAP.md), история изменений: [`docs/ERROR_HISTORY.md`](docs/ERROR_HISTORY.md).

| Модуль | Адрес | Размер | Примечание |
|---|---|---|---|
| AXI GPIO (LED) | 0x4000_0000 | 4K | LED + MIG status |
| AXI HWICAP | 0x4000_1000 | 4K | Xilinx IP (partial reconfig) |
| DFX Socket | 0x4000_2000 | 4K | shutdown/decouple GPIO |
| **TDOT registers** | **0x4000_3000** | 4K | Регистры троичного ускорителя |
| **ICAP registers** | **0x4000_4000** | 4K | icap_ctrl (кастомный, не HWICAP) |
| DFX Partition MM2S | 0x4001_0000 | 4K | DataMover MM2S (окно RP 64K, остаток свободен) |
| DFX Partition S2MM | 0x4001_8000 | 4K | DataMover S2MM (окно RP 64K, остаток свободен) |
| XADC | 0x4600_0000 | 4K | Температура/напряжение (BUG-031: читаются 0, XADC занят MIG) |
| DDR3 (DMA XDMA) | 0x8000_0000 | 256 MB | Доступ хоста через DMA-каналы H2C/C2H (BAR-моста к DDR3 нет) |
| DDR3 (M_AXI_TDOT) | 0x8000_0000 | 256 MB | Доступ ядра tdot_axi4 |

Данные в DDR3: `data[i]`, `weights[i]` — TFloat48 в младших 48 битах 64-битного слова; результат dot — по `result_addr`.

## Ресурсы (XC7A200T, Vivado 2025.2)
- Ядро NUM_MAC=32: ~55k LUT (45%); NUM_MAC=64: ~115k (85%).
- Полный дизайн (ядро 32 + XDMA + DDR3 + DFX): ~101k LUT (~75%), 0 DSP.

## Верификация
- `rtl/integration/verify_tdot_axi4.py 32` — PASS (RTL == raw-модель).
- `rtl/block/rtl_vs_arith48.py` — PASS (RTL == arith48 == torch).
- `pytorch_layer/verify_fpga_backend.py` — PASS (CPU-протокол == mock FPGA).
- Точность dot против torch: max diff ~5e-7.

## Сборка

### Быстрый старт (одна команда)

```cmd
REM Из корня репозитория:
scripts\build.bat
```

`build.bat` автоматически:
1. Находит Vivado 2025.2 в стандартных путях (`C:\AMDDesignTools\...`, `C:\Xilinx\...`)
2. Если путь к репо длиннее 40 символов — создаёт виртуальный диск (subst) для обхода Windows MAX_PATH лимита (Vivado MIG IP генерирует пути 260+ символов)
3. Запускает `scripts\build_dfx.tcl` — сборка DFX-варианта
4. После сборки (успех или fail) отключает виртуальный диск

`build_dfx.tcl` выполняет:
1. Создаёт проект (`C:\build_dfx` на Windows — обход MAX_PATH; на Linux — `build/dfx_proj`; переопределяется переменной окружения `PROJ_DIR`)
2. Добавляет HDL DFX Partition (из `third_party/m2-artix7-accelerator-card/hdl/`)
3. Создаёт BDC `dfx_partition` (из `dfx_block_designs/default.tcl`)
4. Создаёт DFX BD `xdma_ddr3_dfx.bd` (из `scripts/xdma_ddr3_dfx_bd.tcl`)
5. Постобработка BD (из `scripts/post_bd_dfx.tcl`) — добавляет TDOT/ICAP/XADC порты, экспорт клока
6. Настраивает BAR0=128MB и карту адресов; печатает PCIe BAR REPORT (контроль MSI-X/BAR2)
7. Добавляет RTL троичного ядра
8. Запускает synth + impl + write_bitstream
9. Экспортирует `.bit` / `.bin` / `.mcs` **и частичные битстримы RP** (`*partial*`) в `build/artifacts_dfx/`

### Опции сборки

```cmd
REM Сборка с NUM_MAC=16 (меньше LUT):
scripts\build.bat NUM_MAC=16

REM Увеличить параллелизм:
scripts\build.bat JOBS=12

REM Только создать проект без synth (для отладки в GUI):
scripts\build.bat SKIP_SYNTH=1

REM Комбинация:
scripts\build.bat NUM_MAC=32 JOBS=12
```

### Прямой запуск через Vivado

```cmd
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -source scripts\build_dfx.tcl -tclargs NUM_MAC=32
```

### Структура после сборки

```
<CATALOG ПРОЕКТА>                                  — см. п.1 выше (Windows: C:\build_dfx,
                                                     Linux: build/dfx_proj, env: PROJ_DIR)
├── m2_artix7_xdma_ddr3_dfx.xpr
├── m2_artix7_xdma_ddr3_dfx.srcs/
│   ├── sources_1/bd/xdma_ddr3_dfx/                — DFX Block Design
│   └── constrs_1/                                  — констрейны
└── m2_artix7_xdma_ddr3_dfx.runs/
    ├── synth_1/                                    — результаты синтеза
    └── impl_1/ (+ дочерние конфигурации RP)        — имплементация и partial-битстримы

build/artifacts_dfx/                                — финальные артефакты
├── xdma_ddr3_core_top.bit                          — для JTAG загрузки
├── xdma_ddr3_core_top.bin                          — для ICAP загрузки (full)
├── xdma_ddr3_core_top.mcs                          — для SPI flash
└── *partial*.bit / *partial*.bin                   — частичные битстримы RP
                                                     (горячая замена: pytorch_layer/dfx_swap.py)
```

### Верификация (опционально, перед сборкой)

```bash
# Симуляция AXI4-мастера (требует Vivado xsim):
C:\Python39\python.exe rtl\integration\verify_tdot_axi4.py 32

# Статический lint RTL (без Vivado):
python3 scripts/rtl_lint.py
```

## Драйвер Windows
`driver/build.cmd` (WDK) → `XDMA.sys`; тест: `test_xdma.exe`.
Известные исправленные проблемы — см. `xdma_driver_win_src_2017/DRIVER_DEVLOG.md` и `docs/ERROR_HISTORY.md`.

## Открытые задачи
- [x] DFX интеграция: `xdma_ddr3_dfx.bd`, DFX Socket, `dfx_partition` BDC
- [x] ICAP fix: BUFGCE_DIV → BUFG + register divider (Artix-7 не поддерживает BUFGCE_DIV)
- [x] Карта адресов DFX: HWICAP 0x40001000, TDOT 0x40003000, ICAP 0x40004000
- [x] Констрейны: `xdma_ddr3_early.xdc` обновлён под `xdma_ddr3_dfx_i/...`
- [x] Встроены HDL-файлы из reference-репо в `third_party/`
- [ ] DMA-тест DDR3 (ReadBlock/WriteBlock)
- [ ] Интеграционное тестирование на плате, загрузка через ICAP
- [ ] Инсталлятор драйвера
- [ ] Замена DFX Partition на троичное ядро (`tdot_axi4` + `compute_dot_par_raw`)
