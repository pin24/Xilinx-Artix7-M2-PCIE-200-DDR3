# CHANGE LOG / BUILD — 2026-10-13 (flat NUM_MAC=16/ADDERS=4 c OBS; BUILD_ID=2a1ea150)

Сборка: `C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts\build_flat.tcl`
Проект: `C:\build_flat` → артефакты `build\artifacts_flat` (`.bit/.bin/.mcs/.rbt`), 13.10 21:56.

## Конфигурация (из synth-лога / .xpr)
| Параметр | Значение |
|---|---|
| NUM_MAC | 16 |
| ADDERS | 4 |
| BUILD_ID (generic) | `32'h2a1ea150` (коммит с OBS+SPI-stub) |
| Device | xc7a200tfbg484-2, Speed -2 |

## Тайминг (routed, `xdma_ddr3_core_top_timing_summary_routed.rpt`)
| Метрика | Значение |
|---|---|
| **WNS** | **+0.549 ns** (MET) |
| TNS | 0.000 ns |
| TNS failing / total | 0 / 101364 |
| WHS | +0.036 ns |
| THS | 0.000 ns |
| WPWS | 0.000 ns (failing 0 / 36233) |
| Итог | **All user specified timing constraints are met** |

## Утилизация (placed)
| Ресурс | Использовано | Доступно | % |
|---|---|---|---|
| LUT as Logic | 58755 | 133800 | 43.91% |
| LUT as Memory | 4730 | 46200 | 10.24% |
| F7/F8 Muxes | 703 / 60 | 66900 / 33450 | 1.05 / 0.18 |
| Block RAM Tile | 43.5 (RAMB36=42, RAMB18=3) | 365 | 11.92% |
| DSPs | 0 | 740 | 0.00% |
| CARRY4 | 1623 | — | (CarryLogic) |

## Сравнение с предыдущими сборками (одинаковая конфигурация 16/4)
| Точка | NUM_MAC/ADDERS | WNS | LUT (Slice) | Комментарий |
|---|---|---|---|---|
| FLAT baseline (ef51c65, 2026-10-11) | 32/16 | +0.111 | 63.8% | до rebalance |
| Rebalance (e62f6eb) | 16/4 | +0.334 | ~62449 (~46.7%) | без OBS, до fpbody |
| **Текущая (2a1ea150, 2026-10-13)** | **16/4 + OBS** | **+0.549** | Logic 58755 (43.9%), total ~47.4% | +OBS-наблюдаемость + 4KB-clamp |

**Итог по таймингу:** на конфигурации 16/4 WNS вырос **+0.334 → +0.549 ns** (+0.215 ns) при добавлении
OBS-счётчиков и 4KB-клампа — деградации нет, запас положительный. FATAL-гейт пройден (0 violations).

**Примечание:** legacy-отчёт `artifacts_flat/timing_FATAL.rpt` датирован 11.10 (старая неудачная
сборка) и НЕ соответствует текущей — текущая прошла MET, файл устарел (кандидат на удаление).