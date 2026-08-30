# TFloat48 Ternary FP Accelerator — XDMA + DDR3 (Artix-7 XC7A200T, M.2 PCIe)

Проект троичного FP-ускорителя **TFloat48** на плате M.2 (Xilinx Artix-7 XC7A200T),
доступного хосту через PCIe (XDMA) c памятью DDR3, с интеграцией в PyTorch.

## Формат TFloat48
- 48 бит = 6 байт, блоки по 4 трита (1 байт).
- Мантисса M = 20 тритов (нормализована [3^18, 3^19)), экспонента E = 4 трита (bias 40).
- Точность мантиссы 3^-18 ≈ 5.2e-9 (~в 22 раза точнее float32).
- Вся арифметика на LUT: DSP = 0, BRAM ≈ 10%.

## Состав репозитория
| Каталог | Содержимое |
|---|---|
| `rtl/block/` | Блочное ядро: `tbyte_add/mul.sv`, `tfmul_raw.sv`, `tfadd_raw.sv`, `compute_dot_par_raw.sv` (параллельный dot, параметр NUM_MAC) + тестбенчи и Python-верификация |
| `rtl/rtl/` | Ранняя версия ядра (tf40_*, конвертеры f32↔tf) |
| `rtl/integration/` | `tdot_axi4.sv` (AXI4-мастер + AXI-Lite регистры ускорителя), `icap_ctrl.sv`, `xadc_temp.sv`, `xdma_ddr3_core_top.sv` |
| `constraints/` | XDC-файлы платы |
| `scripts/` | TCL-скрипты сборки BD (XDMA + MIG DDR3 + interconnect) и битстрима |
| `pytorch_layer/` | Хост-софт: `fpga_backend.py`, `xdma_driver.py`, `icap_load.py`, `ternary_dot_layer.py` |
| `ternary_sw/` | Python-эталон арифметики TFloat48 (arith48) и тесты |
| `driver/`, `xdma_driver_win_src_2017/` | Windows KMDF-драйвер XDMA + test_xdma.exe (собран и подписан тестовым сертификатом WDK) |

## Карта адресов (PCIe BAR0 128 МБ / AXI M_AXI_LITE, согласована с `scripts/build_all.tcl`)
| Модуль | Адрес |
|---|---|
| AXI GPIO (LED) | 0x4000_0000 |
| TDOT registers (акселератор) | 0x4000_1000 |
| ICAP | 0x4000_2000 |
| XADC (S_AXI_XADC_REGS; FIX-5: подключён к `u_xadc` в top-level) | 0x4600_0000 |
| DDR3 (через XDMA M_AXI) | 0x8000_0000 |

Debug monitor (`debug_mon.sv`) **не реализован** — файл отсутствует в `rtl/integration/`, в BD нет ни порта `S_AXI_DEBUG_REGS`, ни скрипта `add_debug_bd.tcl`. Адрес 0x4700_0000 остаётся зарезервированным (см. `docs/ADDRESS_MAP.md` §2 и `ANALYSIS_AND_SPEC_FIX.md` B-5).

Данные в DDR3: `data[i]`, `weights[i]` — TFloat48 в младших 48 битах 64-битного слова; результат dot — по `result_addr`.

## Ресурсы (XC7A200T, Vivado 2021.2)
- Ядро NUM_MAC=32: ~55k LUT (45%); NUM_MAC=64: ~115k (85%).
- Полный дизайн (ядро 32 + XDMA + DDR3): ~101k LUT (~75%), 0 DSP.

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

Скрипт автоматически:
1. Находит Vivado 2021.2 (проверяет `C:\Xilinx\Vivado\2021.2\bin` и `C:\AMDDesignTools\Vivado\2021.2\bin`)
2. Создаёт проект в `build/m2_artix7_xdma_ddr3/`
3. Строит BD (XDMA + MIG DDR3 + GPIO + BRAM + TDOT + ICAP + XADC)
4. Добавляет RTL троичного ядра
5. Настраивает карту адресов (BAR0=128MB, GPIO/TDOT/ICAP/XADC)
6. Запускает synth + impl + write_bitstream
7. Экспортирует `.bit` / `.bin` / `.mcs` в `build/artifacts/`

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

Если `build.bat` не находит Vivado, добавьте его в PATH или запустите напрямую:

```cmd
"C:\Xilinx\Vivado\2021.2\bin\vivado.bat" -mode batch -source scripts\build.tcl -tclargs NUM_MAC=32
```

### Структура после сборки

```
build/
├── m2_artix7_xdma_ddr3/         — Vivado проект
│   ├── m2_artix7_xdma_ddr3.xpr
│   ├── m2_artix7_xdma_ddr3.srcs/
│   │   ├── sources_1/bd/xdma_ddr3/   — Block Design
│   │   └── constrs_1/                — констрейны
│   └── m2_artix7_xdma_ddr3.runs/
│       ├── synth_1/                  — результаты синтеза
│       └── impl_1/                   — результаты имплементации
└── artifacts/                   — финальные битстримы
    ├── xdma_ddr3_core_top.bit   — для JTAG загрузки
    ├── xdma_ddr3_core_top.bin   — для ICAP загрузки
    └── xdma_ddr3_core_top.mcs   — для SPI flash
```

### Верификация (опционально, перед сборкой)

```bash
# Симуляция AXI4-мастера (требует Vivado xsim):
C:\Python39\python.exe rtl\integration\verify_tdot_axi4.py 32

# Статический lint RTL (без Vivado):
python3 scripts/rtl_lint.py
```

### Устаревший скрипт

`scripts/build_all.tcl` — предыдущая версия (требует существующий проект).
Используйте `scripts/build.tcl` для сборки с нуля.

Примечание: ошибка `write_bitstream` (вызов с `.bin` вместо `.bit`) исправлена —
`build.tcl` пишет `.bit` + `-bin_file` + `.mcs`.

Сборка также экспортирует такт PCIe-домена из BD: `scripts/fix_bd_clock_export.tcl`
(шаг 6 в `build.tcl`, идемпотентно) создаёт порты `axi_aclk_out` /
`axi_aresetn_out` / `axi_aclk_in`; в `xdma_ddr3_core_top.sv` выход замкнут на вход
(loopback), тактируя ускоритель и ICAP реальным `xdma_0/axi_aclk`.

## Драйвер Windows
`driver/build.cmd` (WDK) → `XDMA.sys`; тест: `test_xdma.exe`.
Известные исправленные проблемы — см. `xdma_driver_win_src_2017/DRIVER_DEVLOG.md`.

## Открытые задачи
- [x] Исправить `write_bitstream` в `build_all.tcl` и собрать .bit/.bin — исправлено (`write_bitstream` + `-bin_file` + `.mcs`), битстрим собран 25.08
- [x] RTL-баг: GO затирает N_IN через биты [16:8] CTRL — исправлено (`rtl/integration/tdot_axi4.sv`: запись в CTRL меняет только бит0 GO, N_IN — отдельный регистр 0x08)
- [x] Экспорт такта из BD: порты `axi_aclk_out`/`axi_aresetn_out`/`axi_aclk_in` (`scripts/fix_bd_clock_export.tcl`, шаг 6 в `build_all.tcl`; в top — loopback на `axi_aclk`)
- [x] FIX-5: инстанцирован `xadc_temp.sv` в `xdma_ddr3_core_top.sv`; S_AXI_XADC_REGS подключён к `u_xadc` (база 0x46000000). `add_icap_xadc_bd.tcl` синхронизирован с `build_all.tcl`/`resize_bar0.tcl` (M02=ICAP@0x40002000, M03=XADC@0x46000000)
- [ ] DMA-тест DDR3 (ReadBlock/WriteBlock)
- [ ] Интеграционное тестирование на плате, загрузка через ICAP
- [ ] Инсталлятор драйвера
- [ ] Конфликты LOC GT-ланок PCIe (нужна схема платы; см. комментарий в конце `constraints/xdma_ddr3_pins.xdc` и `vivado_9916.backup.log:1138-1144`)
