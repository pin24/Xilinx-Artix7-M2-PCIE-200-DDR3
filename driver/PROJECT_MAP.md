# PROJECT_MAP — карта проекта XDMA Artix-7 M.2 (PCIe-200-DDR3)

> Корень: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3` (git-репозиторий, ветка `XDMA_DDR3_TMUL`)
> Плата: Xilinx Artix-7 XC7A200T, M.2, PCIe Gen2 x4, 256 МБ DDR3 (MT41J128M16XX-125).
> Назначение: троичный ускоритель (TFloat48) с XDMA + DFX (частичная реконфигурация), обвязка PyTorch.
> Дата инвентаризации: 2026-09-11.

## Каталоги верхнего уровня

| Каталог | Назначение | Ключевые файлы |
|---|---|---|
| `rtl/` | RTL дизайна: ядро, интеграция, тестбенчи + Python-верификаторы | `integration/tdot_axi4.sv` (регистры ядра), `integration/icap_ctrl.sv`, `integration/xdma_ddr3_core_top.sv` (топ), `integration/xadc_temp.sv`, `rtl/tf40_*.sv`, `rtl/compute_core*.sv`, `block/tfmul_raw.sv`, `block/tfadd_raw.sv`, `block/tbyte_mul.sv`, `tb/*`, `verify_rtl_*.py` |
| `scripts/` | TCL-флоу сборки DFX-проекта (Vivado 2025.2) | `build_dfx.tcl` (мастер-скрипт: BD→synth→impl→bitstream, BAR0=128MB, FATAL-гейт тайминга), `xdma_ddr3_dfx_bd.tcl` (сборка BD), `post_bd_dfx.tcl`, `check_timing_fatal.tcl`, `timing_report_analysis.tcl`, `tcl_timing_lib.tcl`, `suppress_lut_overutil.tcl` |
| `dfx_block_designs/` | Варианты Reconfigurable Partition (RP) | `default.tcl`, `test.tcl` (RP-локальная карта, апертура 0x40010000/64KB) |
| `constraints/` | XDC/TCL констрейны | `xdma_ddr3_pins.xdc` (пины, клоки), `xdma_ddr3_early.xdc`, `pblock.xdc` (DFX pblock + SNAPPING_MODE + RESET_AFTER_RECONFIG), `timing_exceptions.tcl` (set_clock_groups) |
| `docs/` | Документация-источник истины и история | `ADDRESS_MAP.md` (КАРТА АДРЕСОВ — канон), `ERROR_HISTORY.md` (BUG-001…052), `worklog.md` (история задач) |
| `driver/` | Windows KMDF-драйвер XDMA + хостовые утилиты + эмуляторы | `driver.c`, `test_xdma.c`, `build.cmd`, `install.cmd`, `uninstall.cmd`, `clean.cmd`, `XDMA.inx`, `security_cookie.c`, `emulate_test.py`, `edge_cases.py`, `XDMA_Driver.vcxproj`, `XDMA_Test.vcxproj`, `DEPRECATED.md`, `ROLLBACK.md`, артефакты `build/` |
| `pytorch_layer/` | Хост-обвязка для PyTorch: доступ к плате, DFX-swap, ICAP | `xdma_driver.py` (XdmaLinux/XdmaWindows/TdotCore/TdotScheduler), `fpga_backend.py` (CPU-эмуляция ↔ FPGA), `icap_load.py`, `dfx_swap.py`, `monitor_temp.py`, `flash_write.py` (заглушка), `ternary_dot_layer.py`, `verify_fpga_backend.py` |
| `ternary_sw/` | Эталонные Python-модели троичной арифметики TFloat40/48 + тесты | `block/tfloat48.py`, `block/arith48.py`, `block/trits.py`, `ternary/tfloat40.py`, `ternary/arith.py`, `tests/test_tfloat40.py`, `benchmark.py`, `verify_cpu.py` |
| `third_party/` | Сторонний HDL | `m2-artix7-accelerator-card/hdl/**` (datamover-контроллеры, `up_axi.v`) |
| `xdma_driver_win_src_2017/` | Reference: исходники Xilinx XDMA Windows-драйвера 2017 | `sys/XDMA.inf`, `libxdma/`, `inc/`, `exe/`, `CHANGELOG.md`, `DRIVER_DEVLOG.md` |
| `_backup_20260911_215624/` | Снапшот исходников перед аудитом (309 файлов, 19 МБ) | подкаталоги driver/pytorch_layer/scripts/docs/rtl/… |

## Корневые файлы

| Файл | Назначение |
|---|---|
| `README.md`, `README_BLOCK.md`, `xdma_ddr3_dfx_README.md` | Описание проекта/блока/сборки |
| `Makefile` | Обёртки `make build/proj/clean` для TCL-флоу |
| `project_config.tcl`, `block_design_top.tcl` | Конфигурация проекта и BD |
| `ANALYSIS_AND_SPEC_FIX.md` | Первый аудит (BUG-001…009) |
| `INTEGRATION_REPORT.md` | Отчёт интеграции |
| `dfx_runtime.txt` | Рантайм-заметки DFX |

## Поток сборки (Vivado)

`Makefile` → `scripts/build_dfx.tcl` → (2b) `xdma_ddr3_dfx_bd.tcl` (создание BD) → (2c) `post_bd_dfx.tcl` → (2d) конфиг BAR0=128MB / адреса → synth → RTL из `rtl/` → impl → FATAL-гейт тайминга → `build/artifacts_dfx/*.bit|.bin` (+ partial для RP).
Проект собирается в `C:\build_dfx` (генерируется заново; в репозитории `.xpr` нет).

## Внешние (вне корня, для справки)

- `C:\A7_M2\EXAMPLES\**` — референсные проекты Xilinx (XDMA, XDMA_DDR3, RIFFA, IBERT, примеры M.2-платы).
- `C:\AMDDesignTools\2025.2` — установленный Vivado 2025.2.
- `C:\build_dfx` — рабочая директория последней сборки (лог от 2026-09-10 22:17).

## Структура зависимостей (кто кого использует)

- Драйвер (`driver.c`) ↔ железо: AXI-Lite (BAR0) и (в легаси) DDR3-мост; в DFX — DDR3 только по DMA.
- `test_xdma.c` → IOCTL драйвера (`\\.\XDMA0`) → регистры 0x40000000…0x46000000 и DDR3.
- `pytorch_layer/*` → `xdma_driver.py` (Linux: /dev/xdma0_*; Windows: `xdma_rw.exe`) → регистры/DMA.
- `fpga_backend.py` → `ternary_sw/block/*` (эталон) и `xdma_driver.TdotCore` (железо).
- `dfx_swap.py` → `icap_load.py` (ICAP) + DFX socket GPIO.
- RTL-верификаторы (`rtl/verify_*.py`, `rtl/block/verify_*.py`) → Python-модели в `ternary_sw/`.
