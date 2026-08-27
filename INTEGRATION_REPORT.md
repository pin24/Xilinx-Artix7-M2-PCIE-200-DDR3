# Интеграция троичного FP-ядра (compute_dot_par_raw, NUM_MAC=32) в XDMA+DDR3

## Результат синтеза (XC7A200T, Vivado 2021.2, jobs 19)

Полный AXI4-мастер `tdot_axi4` + ядро + ICAP + XDMA/DDR3:

| Ресурс | Использовано | Доступно | % |
|--------|-------------|----------|---|
| Slice LUTs | **~101 000** | 134 600 | **~75%** |
| Slice Registers | ~55 000 | 269 200 | ~20% |
| Block RAM Tile | 36.5 | 365 | 10.00% |
| DSPs | 0 | 740 | 0% |

Лимит LUT <= 134 600 — **ВЫПОЛНЕН** (запас ~33k LUT / 25%).

## Иерархия (top-level)
- `u_tdot` (tdot_axi4: AXI4-мастер + регистры + FIFO + ядро): **63 573 LUT**
  - `u_core` (compute_dot_par_raw, NUM_MAC=32): **54 916 LUT**
    - 32x `gen_mac[i].u_mul` (tfmul_raw), 1x `u_add` (tfadd_raw)
  - AXI4-обвязка (burst read/write FSM, FIFO 48-bit, AXI-Lite): ~8 657 LUT
- `u_icap` (icap_ctrl): **~200 LUT**
- `u_debug` (debug_mon, если добавлен): **~1 500 LUT**
- `xdma_ddr3_i` (BD): **29 197 LUT**
  - xdma_0 (XDMA): ~22 389 LUT, mig_7series_0 (DDR3): ~6 455 LUT, axi_smc: ~4 184 LUT

## Схема подключения (полная)
```
хост (PyTorch / xdma_rw)
  │  XDMA M_AXI_LITE  (xdma_control, 32-бит)
  ▼
axi_periph ─ M00 → axi_gpio            (0x4000_0000, LED)
          ├─ M01 → S_AXI_TDOT_REGS     (0x4400_0000, tdot_axi4 регистры)
          ├─ M02 → S_AXI_ICAP_REGS     (0x4600_0000, ICAP)
          └─ M03 → S_AXI_DEBUG_REGS    (0x4700_0000, debug_mon)

  хост ─ XDMA M_AXI (xdma_user) ─→ DDR3 0x8000_0000
          ↑                           ↑
  tdot_axi4.M_AXI ─ M_AXI_TDOT ─┐ axi_smc/S01
  debug_mon.M_AXI ─ M_AXI_DEBUG─┘ axi_smc/S02
                                    │ M00 → BRAM
                                    │ M01 → MIG DDR3
                                    └ M02 → BRAM (debug буфер)
```

## Модули

### tdot_axi4 — полный AXI4-мастер троичного ускорителя
- AXI4 master (AW/AR/W/R/B, INCR-burst, BURST_RD_LEN=16)
- FIFO 48-bit, распаковка TFloat48 из 64-битных слов (младшие 48 бит)
- Регистры: CTRL(0x00,GO)/STATUS(0x04,BUSY/DONE)/N_IN(0x08)/RES0/1(0x0C,0x10)/
  DATA_ADDR(0x14,0x18)/WEIGHTS_ADDR(0x1C,0x20)/RESULT_ADDR(0x24,0x28)/CORE_RES0/1
- Верифицирован: verify_tdot_axi4.py PASS (NUM_MAC=16/32), 4 случая, 0 несовпадений

### icap_ctrl — перезагрузка на лету через PCIe
- Write-only AXI-Lite slave, ICAPE2 X32, clk_en/2 (62.5 MHz)
- Регистры: CTRL(0x00,GO/STOP), STATUS(0x04,READY/BUSY), DATA(0x08,write-only)
- Хост пишет слова напрямую в DATA, контроллер отправляет в ICAP

### debug_mon — отладка без JTAG (опционально)
- Кольцевой буфер снапшотов в BRAM (0x0000_1000) или DDR3 (0x8003_0000)
- Каждый снапшот: 64 байта (cstate, адреса, core_result, fifo, AXI-трафик)

## Формат данных в DDR3
- `data[i]` по адресу `data_start + i*8` — TFloat48 в младших 48 битах
- `weights[i]` по адресу `weights_start + i*8` — TFloat48 в младших 48 битах
- Результат по адресу `result_addr` — 64-битное слово, младшие 48 бит

## Верификация
- `verify_tdot_axi4.py 16/32` — **PASS** (0 несовпадений с raw-моделью)
- `rtl_vs_arith48.py` — **PASS** (8/8 RTL == arith48 == torch)
- `verify_fpga_backend.py` — **PASS** (протокол хоста через mock)
- `ternary_dot_layer.py` — max diff ~5e-7 против torch.dot

## Файлы и скрипты

### RTL
| Файл | Назначение |
|------|-----------|
| `rtl/block/compute_dot_par_raw.sv` | Ядро dot (NUM_MAC=32, tfmul_raw×32 + tfadd_raw) |
| `rtl/block/tfmul_raw.sv` | Умножитель TFloat48 без нормализации |
| `rtl/block/tfadd_raw.sv` | Сумматор с нормализацией |
| `rtl/integration/tdot_axi4.sv` | AXI4-мастер + AXI-Lite регистры ускорителя |
| `rtl/integration/icap_ctrl.sv` | ICAP-контроллер для перезагрузки |
| `rtl/integration/debug_mon.sv` | Debug-монитор (кольцевой буфер) |
| `rtl/integration/xdma_ddr3_core_top.sv` | Top-уровень (BD + все модули) |

### BD
| Скрипт | Назначение |
|--------|-----------|
| `scripts/add_tdot_axi4_bd.tcl` | axi_smc NUM_SI 1→2, порт M_AXI_TDOT |
| `scripts/add_tdot_axil_host.tcl` | axi_periph NUM_MI 1→2, порт TDOT_REGS |
| `scripts/add_icap_xadc_bd.tcl` | axi_periph NUM_MI 2→3, порт ICAP_REGS |
| `scripts/add_debug_bd.tcl` | axi_periph 3→4, axi_smc 2→3, порт DEBUG |
| `scripts/build_all.tcl` | Полная сборка (BD → synth → impl → bitstream) |

### Хостовые скрипты
| Файл | Назначение |
|------|-----------|
| `pytorch_layer/xdma_driver.py` | Драйвер XDMA (Linux /dev + Windows xdma_rw) |
| `pytorch_layer/icap_load.py` | Загрузка `.bin` в FPGA через ICAP |
| `pytorch_layer/monitor_temp.py` | Мониторинг температуры (XADC, через MIG) |
| `pytorch_layer/debug_reader.py` | Чтение debug-буфера и отображение снапшотов |
| `pytorch_layer/verify_fpga_backend.py` | Сверка FPGA-протокола (mock) |

### Верификация
| Скрипт | Результат |
|--------|-----------|
| `rtl/integration/verify_tdot_axi4.py 32` | PASS (0 mismatch) |
| `rtl/block/rtl_vs_arith48.py` | PASS (8/8 RTL == arith48) |
| `pytorch_layer/verify_fpga_backend.py` | PASS (CPU == FPGA mock) |
| `pytorch_layer/ternary_dot_layer.py` | max diff 5e-7 vs torch |

## Запуск
```bash
# верификация AXI4-мастера
C:\Python39\python.exe rtl\integration\verify_tdot_axi4.py 32

# полная сборка (BD → synth → impl → .bit → .bin → .mcs)
C:\AMDDesignTools\Vivado\2021.2\bin\vivado.bat -mode batch -source scripts\build_all.tcl

# загрузка битстрима через ICAP (после первой прошивки по JTAG)
C:\Python39\python.exe pytorch_layer\icap_load.py m2_artix7_xdma_ddr3.runs\impl_1\xdma_ddr3_core_top.bin

# мониторинг температуры
C:\Python39\python.exe pytorch_layer\monitor_temp.py --interval 2
```

## Битовая конвенция TFloat48
RTL выводит TFloat48 в формате `[E:8][M:40]` (экспонента в старших 8 битах):
```python
# декодирование в Python
bits = ((o & 0xFFFFFFFFFF) << 8) | ((o >> 40) & 0xFF)
value = TFloat.from_bits(bits).to_float()
```