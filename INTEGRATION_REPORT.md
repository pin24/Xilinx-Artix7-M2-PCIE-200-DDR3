# Интеграция троичного FP-ядра (compute_dot_par_raw, NUM_MAC=32) в XDMA+DDR3

> **Обновление 28.08.2026 (исправления по ANALYSIS_AND_SPEC_FIX.md):**
> - AXI-Lite slave `tdot_axi4`/`tdot_axi_lite` переписан: независимый приём AW/W
>   (устранена потеря записей/зависание), RES0 = результат[31:0], RES1 = [47:32],
>   GO при BUSY игнорируется, FIFO сбрасывается на новом запуске.
> - `icap_ctrl` переписан: CSIB=0 ровно на 1 такт icap_clk (62.5 МГц через
>   BUFGCE_DIV), CDC toggle-handshake, backpressure на DATA при занятом mailbox.
>   Формат данных: хост шлёт LE-слова битстрима (sync 0xAA995566 -> DATA 0x665599AA).
> - Такт PCIe-домена экспортирован из BD (`axi_aclk_out/axi_aresetn_out/axi_aclk_in`,
>   `scripts/fix_bd_clock_export.tcl`) — устранены неявные провода в top и DRC
>   SmartConnect о clock domain S01.
> - Констрейны: добавлен `diff_clock_rtl_0_clk_n` = E10 (MGTREFCLK1N_216, UG482).
> - Карта адресов синхронизирована с `build_all.tcl` (см. ниже).


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
- `u_xadc` (xadc_temp, FIX-5 RTL-1): **~50 LUT** (AXI-Lite slave, raw_temp/vccint=0 пока XADC Wizard не заведён)
- `xdma_ddr3_i` (BD): **29 197 LUT**
  - xdma_0 (XDMA): ~22 389 LUT, mig_7series_0 (DDR3): ~6 455 LUT, axi_smc: ~4 184 LUT

> **Примечание (FIX-5)**: модуль `debug_mon.sv` **не реализован** —
> заявленный в ранних версиях отчета debug-монитор отсутствует в
> `rtl/integration/` (см. `ANALYSIS_AND_SPEC_FIX.md` B-5, P1-6). Адрес
> 0x47000000 остаётся зарезервированным в `docs/ADDRESS_MAP.md`, но
> в текущей сборке недоступен. Если потребуется — создать модуль и
> скрипт `add_debug_bd.tcl` (отдельная задача).

## Схема подключения (полная)
```
хост (PyTorch / xdma_rw)
  │  XDMA M_AXI_LITE  (xdma_control, 32-бит)
  ▼
axi_periph ─ M00 → axi_gpio            (0x4000_0000, LED)
          ├─ M01 → S_AXI_TDOT_REGS     (0x4000_1000, tdot_axi4 регистры)
          ├─ M02 → S_AXI_ICAP_REGS     (0x4000_2000, ICAP)
          └─ M03 → S_AXI_XADC_REGS     (0x4600_0000, XADC; FIX-5: подключён к u_xadc)

  хост ─ XDMA M_AXI (xdma_user) ─→ DDR3 0x8000_0000
          ↑
  tdot_axi4.M_AXI ─ M_AXI_TDOT ─┐ axi_smc/S01 (такт 125 МГц привязан через
                                 │  BD-порты axi_aclk_out/axi_aclk_in —
                                 │  см. scripts/fix_bd_clock_export.tcl)
                                 │   │ M00 → BRAM
                                 │   │ M01 → MIG DDR3
                                 │   └ M02 → BRAM (debug буфер, не используется)

  Legacy M_AXI_ICAP (если остался в wrapper) — удалён скриптом
  add_icap_xadc_bd.tcl (FIX-5 RTL-3); при пересборке wrapper пропадает.
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

### debug_mon — НЕ реализован (отложено)
- Модуль `debug_mon.sv` отсутствует в `rtl/integration/` (см. `ANALYSIS_AND_SPEC_FIX.md` B-5).
- В BD нет ни порта `S_AXI_DEBUG_REGS`, ни скрипта `add_debug_bd.tcl`.
- Адрес `0x4700_0000` остаётся зарезервированным в `docs/ADDRESS_MAP.md`.
- Если в будущем потребуется — создать модуль и добавить через `add_debug_bd.tcl`
  (отдельная задача, не блокирует текущую сборку).

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
| `rtl/integration/xadc_temp.sv` | AXI-Lite slave: регистры TEMP/VCCINT/STATUS (база 0x46000000) |
| `rtl/integration/xdma_ddr3_core_top.sv` | Top-уровень (BD + все модули) |

### BD
| Скрипт | Назначение |
|--------|-----------|
| `scripts/add_tdot_axi4_bd.tcl` | axi_smc NUM_SI 1→2, порт M_AXI_TDOT |
| `scripts/add_tdot_axil_host.tcl` | axi_periph NUM_MI 1→2, порт TDOT_REGS |
| `scripts/add_icap_xadc_bd.tcl` | axi_periph NUM_MI 2→4: M02=ICAP_REGS@0x40002000, M03=XADC_REGS@0x46000000; cleanup legacy M_AXI_ICAP (FIX-5) |
| `scripts/add_debug_bd.tcl` | **не существует** (debug_mon не реализован, см. B-5) |
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