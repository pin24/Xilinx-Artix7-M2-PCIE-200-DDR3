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
| `rtl/integration/` | `tdot_axi4.sv` (AXI4-мастер + AXI-Lite регистры ускорителя), `icap_ctrl.sv`, `debug_mon`, `xdma_ddr3_core_top.sv` |
| `constraints/` | XDC-файлы платы |
| `scripts/` | TCL-скрипты сборки BD (XDMA + MIG DDR3 + interconnect) и битстрима |
| `pytorch_layer/` | Хост-софт: `fpga_backend.py`, `xdma_driver.py`, `icap_load.py`, `ternary_dot_layer.py` |
| `ternary_sw/` | Python-эталон арифметики TFloat48 (arith48) и тесты |
| `driver/`, `xdma_driver_win_src_2017/` | Windows KMDF-драйвер XDMA + test_xdma.exe (собран и подписан тестовым сертификатом WDK) |

## Карта адресов (PCIe BAR / AXI)
| Модуль | Адрес |
|---|---|
| AXI GPIO (LED) | 0x4000_0000 |
| TDOT registers (акселератор) | 0x4400_0000 |
| ICAP | 0x4600_0000 |
| Debug monitor | 0x4700_0000 |
| DDR3 | 0x8000_0000 |

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
```bash
# Верификация
C:\Python39\python.exe rtl\integration\verify_tdot_axi4.py 32

# Полная сборка (BD → synth → impl → bitstream)
C:\AMDDesignTools\Vivado\2021.2\bin\vivado.bat -mode batch -source scripts\build_all.tcl
```
Примечание: в `build_all.tcl` есть известная ошибка — `write_bitstream` вызывается
с выходным файлом `.bin` (Vivado требует `.bit`), поэтому битстрим последней сборки не сгенерирован.
(Vivado требует `.bit`) — битстрим последней сборки не был сгенерирован.

## Драйвер Windows
`driver/build.cmd` (WDK) → `XDMA.sys`; тест: `test_xdma.exe`.
Известные исправленные проблемы — см. `xdma_driver_win_src_2017/DRIVER_DEVLOG.md`.

## Открытые задачи
- [ ] Исправить `write_bitstream` в `build_all.tcl` и собрать .bit/.bin
- [ ] RTL-баг: GO затирает N_IN через биты [16:8] CTRL
- [ ] DMA-тест DDR3 (ReadBlock/WriteBlock)
- [ ] Интеграционное тестирование на плате, загрузка через ICAP
- [ ] Инсталлятор драйвера
