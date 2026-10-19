# ADDRESS MAP — единый источник истины (FLAT-вариант)

> **Служебный файл**: единственная согласованная карта адресов, регистров и
> BAR-конфигурации проекта **XDMA + DDR3 + BRAM (TFloat48)** на Artix-7
> XC7A200T (ветка `2ch-pipeline`, HEAD bf1e18b).
>
> **Активная сборка**: `scripts/build_flat.tcl` → `scripts/xdma_ddr3_bd.tcl`
> → `scripts/post_bd_flat.tcl`. DFX полностью удалён — только flat.
>
> Все остальные источники (RTL-комментарии, BD TCL, драйвер, хост-софт,
> README) обязаны соответствовать этому файлу. Любые правки адресов
> **сначала** вносятся сюда, затем синхронизируются во все остальные файлы.
>
> dfx-specific блоки (DFX Socket, ICAP, SPI, HWICAP, RP-варианты) в этой
> карте **НЕ существуют** — они были реализованы только в DFX-сборке, которая
> удалена. Их упоминание в исторических документах — легаси.

---

## 1. PCIe / BAR конфигурация

| Параметр | Значение | Где задано |
|---|---|---|
| PCIe Vendor ID | `0x10EE` (Xilinx) | BD XDMA `pf0_device_id` |
| PCIe Device ID | `0x7024` | то же + `driver/dma/build/XDMA_DMA.inf` |
| PCIe lanes / Gen | x4 Gen2 | `pl_link_cap_max_link_width/speed` в BD |
| Режим XDMA | **AXI DMA** (H2C + C2H канала) + AXI-Lite bridge | `xdma_rnum_chnl/wnum_chnl`, `axilite_master_en` |
| **BAR0** (AXI-Lite, M_AXI_LITE) | **128 MB**, окно AXI `0x40000000`…`0x47FFFFFF` | `build_flat.tcl` шаг 2d, `pf0_bar0_scale/size`, `pf0_bar2axibar_axil_master=0x40000000` |
| **BAR2** | НЕ мост данных; на нём таблица MSI-X (`pf0_msix_cap_table_bir = BAR_3:2`) | BD-конфиг XDMA; фактический размер печатает «PCIe BAR REPORT» в `build_flat.tcl` |
| **DDR3 в PCIe-пространстве** | **Отсутствует** — данные хост↔DDR3 идут через DMA-каналы | см. §1.2 |
| **BRAM в PCIe-пространстве** | **Отсутствует** — доступ только через DMA-каналы с `translateAxiBase=false` | см. §1.2, §6.1 |

### 1.1. Выбор BAR / устройства (логика хост-драйвера)

| Диапазон AXI-адресов | Канал доступа | Что там |
|---|---|---|
| `0x40000000` … `0x47FFFFFF` | Windows: `\\.\XDMA0dma\user` (AXI-Lite, периферия); offset = addr − 0x40000000; Linux: `/dev/xdma0_control` | Вся периферия AXI-Lite (§2) |
| `0x80000000` … `0x8FFFFFFF` | DMA-каналы `h2c/c2h` (translateAxiBase=TRUE) | DDR3 **256 MB** (§6) |
| `0x10000000` … `0x10001FFF` | DMA-каналы `h2c_bram/c2h_bram` (translateAxiBase=FALSE) | BRAM **8 KB** (§6.1) |

### 1.2. Куда идут данные (важно для хост-софта)

XDMA работает в **DMA-режиме**: `M_AXI` обслуживает H2C/C2H-каналы
(SmartConnect → MIG `0x80000000` и diag_bram `0x10000000`). Второй BAR-мост к
DDR3/BRAM **не сконфигурирован**, поэтому:

- MMIO-чтение/запись DDR3/BRAM с хоста (через BAR2) **не работает** — второго
  BAR-моста нет;
- поток данных хост↔память: **только DMA-каналы**:

| Назначение | Windows узел | translateAxiBase | Хост шлёт |
|---|---|---|---|
| DDR3 запись | `\\.\XDMA0dma\h2c_0` | TRUE | raw-смещение от `0x80000000` |
| DDR3 чтение | `\\.\XDMA0dma\c2h_0` | TRUE | raw-смещение от `0x80000000` |
| BRAM запись | `\\.\XDMA0dma\h2c_bram_0` | FALSE | полный картовый адрес (`0x10000000+`) |
| BRAM чтение | `\\.\XDMA0dma\c2h_bram_0` | FALSE | полный картовый адрес (`0x10000000+`) |

Python DMA-API реализована в `xdma_driver.py`: `XdmaDevice.write_dma/read_dma`
(смещения от `0x8000_0000` для DDR3, чанки 1 МиБ, кратность 4 байта);
`TdotCore.write_tf48/read_tf48` идут через неё автоматически. Самопроверка на
железе: `python xdma_driver.py --selftest [--dot]`.

**BRAM-каналы (`h2c_bram_0`/`c2h_bram_0`) разделяют DMA-движок channel 0 с
обычными `h2c_0`/`c2h_0`**: флаг `translateAxiBase` живёт на движке (не на
файле) и переопределяется при каждом открытии файла (`file_io.c:189-196`).
⇒ BRAM- и DDR3-каналы одного направления нельзя использовать **одновременно
в активном потоке** — последнее открытие переопределит трансляцию. Для
BRAM-тестов — изолированный прогон.

### 1.3. Ключевые константы драйвера

- `XDMA_DDR3_AXI_BASE = 0x80000000` (`drv_src_2017/inc/reg.h:59`) — база,
  добавляемая двигателем только при `translateAxiBase=TRUE`.
- Драйвер: `\\.\XDMA0dma` (симлинк `dma_driver.c`). Ноды: `control`,
  `user`, `bypass`, `h2c_0..3`, `c2h_0..3`, `h2c_bram_0`, `c2h_bram_0`,
  `event_0..15`. DEVNODE перечислены в `sys/file_io.c:50-85`.
- Регистры tdot доступны через **`\user`** (AXI-Lite периферия), а не `\control`
  (config-BAR). В `test_dma_win.py` (XdmaWinDma) компактный бэкенд с
  `\\.\XDMA0dma` + `\user` для регистров и `\h2c_0`/`\c2h_0` для DMA.

---

## 2. Карта AXI-Lite (внутри BAR0, каноническая FLAT-карта)

Источник истины: `scripts/xdma_ddr3_bd.tcl` (assign_bd_address),
`scripts/build_flat.tcl` шаг 2d, `scripts/post_bd_flat.tcl`.

| Периферия | Базовый адрес | Размер | Мастер lite-SMC | Назначение |
|---|---|---|---|---|
| **DataMover MM2S ctrl** | `0x40010000` | 4 KB | lite-M01 | Контроль MM2S (независимый DMA-путь, см. §6.2) |
| **DataMover S2MM ctrl** | `0x40018000` | 4 KB | lite-M02 | Контроль S2MM |
| **AXI GPIO (LED/status)** | `0x40020000` | 4 KB | lite-M00 | GPIO ch1: 3 светодиода (out); GPIO2 ch2: 2 бита MIG status (`mmcm_locked`, `init_calib_complete`) |
| **TDOT registers** | `0x40023000` | 4 KB | lite-M03 | Регистры троичного ядра `tdot_axi4` — см. §3 |
| **XADC** | `0x46000000` | 4 KB | lite-M04 | Температура/VCCINT (`xadc_temp.sv`) — см. §7 |

> **НЕ существуют во FLAT-сборке** (были только в удалённой DFX):
> DFX Socket `0x40022000`, ICAP `0x40024000`, SPI `0x40025000`,
> HWICAP `0x40001000`. Обращение к ним на flat-прошивке попадает в
> unmapped-пространство AXI-Lite.

---

## 3. Регистры TDOT (`tdot_axi4.sv`, база `0x40023000`)

Источник истины: `rtl/integration/tdot_axi4.sv` (декод `[7:2]`).

Все регистры 32-битные, байтовый адрес.

### 3.1. Управление (Write)

| Offset | Имя | R/W | Битовое поле | Описание |
|---|---|---|---|---|
| `0x00` | `CTRL` | W | `[0]` GO | Запуск вычисления; самосброс через 1 такт. Игнорируется при `sched_en=1` |
| `0x08` | `N_IN` | W | `[31:0]` | Число пар (1…16·NUM_MAC = MAX_N_TOTAL); 0 → NUM_MAC; >NUM_MAC — long-dot (проходы по NUM_MAC с аккумулятором tfadd48) |
| `0x14`/`0x18` | `DATA_ADDR_LO/HI` | W | `[31:0]` | Полный AXI-адрес `data` (DDR3 `0x80000000+` / BRAM `0x10000000+`) |
| `0x1C`/`0x20` | `WEIGHTS_ADDR_LO/HI` | W | `[31:0]` | Полный AXI-адрес `weights` |
| `0x24`/`0x28` | `RESULT_ADDR_LO/HI` | W | `[31:0]` | Полный AXI-адрес результата |
| `0x40` | `SCHED_CTRL` | W | `[0]` sched_en, `[1]` irq_en, `[2]` flush, `[3]` irq_ack | Планировщик. При `sched_en=1` внешний GO игнорируется |
| `0x44` | `SCHED_WPTR` | W | `[7:0]` | Хостовый указатель записи кольца (doorbell; кольцо mod 256) |
| `0x4C`/`0x50` | `DESC_BASE_LO/HI` | W | `[31:0]` | База таблицы дескрипторов (полный AXI, DDR3/BRAM) |
| `0x54`/`0x58` | `COMP_BASE_LO/HI` | W | `[31:0]` | База области завершений |
| `0x6C` | `OBS_CTRL` | W | `[0]` CLEAR (импульс), `[1]` FREEZE (уровень) | Наблюдаемость (см. §3.4) |
| `0xAC` | `OBS_SNAP` | W | любое | Атомарный снимок в тени |

### 3.2. Статус (Read)

| Offset | Имя | Битовое поле | Описание |
|---|---|---|---|
| `0x00` | `CTRL` | `[0]` go_reg | Защёлка GO |
| `0x04` | `STATUS` | `[0]` BUSY, `[1]` DONE | Состояние вычислителя |
| `0x08` | `N_IN` | `[31:0]` | Число пар |
| `0x0C` | `RES0` | `[31:0]` | Результат `[31:0]` (защёлка по DONE) |
| `0x10` | `RES1` | `[15:0]` | `{16'h0, результат[47:32]}` |
| `0x14`–`0x28` | адреса LO/HI | `[31:0]` | Зеркала write-полей |
| `0x2C`/`0x30` | `CORE_RES0/1` | `[31:0]`/`[15:0]` | Живые зеркала результата ядра (debug, AUDIT-05) |
| `0x40` | `SCHED_CTRL` | `[0]` sched_en, `[1]` irq_en, `[2]` flush, `[3]` irq_pending | Состояние планировщика |
| `0x44` | `SCHED_WPTR` | `[7:0]` | Хостовый указатель записи |
| `0x48` | `SCHED_RPTR` | `[7:0]` | Указатель чтения движка |
| `0x4C`–`0x58` | DESC/COMP_BASE | `[31:0]` | Зеркала баз |
| `0x5C` | `SCHED_STATUS` | `[0]` sched_busy, `[1]` irq_pending | Состояние движка |
| `0x60` | `DONE_CNT` | `[15:0]` | Свободно-бежащий счётчик завершённых задач |
| `0x64` | `CORE_PARAMS` | `[7:0]` NUM_MAC, `[15:8]` ADDERS | Параметры компиляции ядра (автоопределение) |
| `0x68` | `MAGIC` | `0x54444F54` ('TDOT') | Идентификация блока |
| `0x6C` | `OBS_CTRL` | `[1]` obs_freeze | Статус наблюдаемости |
| `0x70` | `BUILD_ID` | 8 hex git-коммита | Идентификация битстрима (`0` = не передан/сборка вне git) |
| `0x74` | `CAPS` | `[7:0]` NUM_MAC, `[11:8]` ADDERS, `[15:12]` log2(BURST_RD_LEN), `[16]`=1, `[19:17]` ELEM_FMT, `[31:24]` REGMAP_V | Возможности битстрима + формат элементов |
| `0x78..0xA8` | OBS-счётчики | CYCLES_LO/HI, BUSY, MEM, LOAD, COMPUTE, AR, BEAT, AR_STALL, R_WAIT, WR, JOB, FIFO_FULL | см. §3.4 |
| `0xAC` | `SNAP` | `0` | Write-only; drive 0 при read |
| `0xB0..0xE0` | S-тени | 13 слов | Теневые копии после SNAP |

**ELEM_FMT (CAPS[19:17])** — определяет формат элементов в памяти ядра:

| Значение | Имя | Байт/элемент | Реализация |
|---|---|---|---|
| `0` | LEGACY | 8 | tf48 в 64-битном слове (младшие 48 бит). **Реализовано и MET** |
| `1` | FP32 | 4 (2 на 64-бит слово) | raw fp32, ядро конвертирует F2T/T2F. **НЕреализуемо на чипе (998% LUT)** — только симуляция/mock; на плате — host-конверсия fp32→tf48 для fmt 0/2 |
| `2` | PACKED6 | 6 | tf48 плотно, WSTRB=0x3F. **Реализовано и MET** |

Сборка 48-битного результата: `result = ((res1 & 0xFFFF) << 32) | (res0 & 0xFFFFFFFF)`.

### 3.3. Планировщик: дескрипторы, завершения, IRQ

Дескриптор — **32 байта** (4×64-бит), `DESC_BASE + rptr*32` (кольцо mod 256):

| Слово | Биты | Содержимое |
|---|---|---|
| W0 | `[47:0]` | `data_addr` — полный AXI (обрезается до 32 бит) |
| W1 | `[47:0]` | `weights_addr` |
| W2 | `[47:0]` | `result_addr` |
| W3 | `[31:16]`/`[15:0]` | `n_total` / `tag` |

Завершение — **16 байт** (2×64-бит), `COMP_BASE + rptr*16`:

| Слово | Биты | Содержимое |
|---|---|---|
| W0 | `[47:0]`/`[63:48]` | `result[47:0]` / `tag` |
| W1 | `[7:0]`/`[15:8]` | `status` (0=OK) / `passes` |

Поток: хост наливает дескрипторы DMA h2c → пишет `SCHED_WPTR` (doorbell) →
движок выбирает задачи (fetch → dot → результат + completion) → при опустошении
и `irq_en` поднимается IRQ → хост читает завершения c2h и сбрасывает IRQ
битом `irq_ack`. IRQ = уровень `tdot_irq` → синхронизация (2-FF, 250 МГц) →
`xdma_0/usr_irq_req[0]` (MSI-X). Хост-API: `TdotScheduler`.

### 3.4. Наблюдаемость (OBS, Task 35)

Полная семантика — `docs/OBSERVABILITY.md`. Кратко:
- `CYCLES` — 64-бит free-running (не подчиняется FREEZE);
- событийные 32-бит счётчики (MEM/LOAD/COMPUTE/AR/BEAT/AR_STALL/R_WAIT/WR/JOB/
  FIFO_FULL) считаются в такт события; `CLEAR` обнуляет всё и тени; `FREEZE`
  паузит события, но не CYCLES;
- `SNAP` → `0xB0..0xE0` — консистентный атомарный снимок;
- host-API: `xdma_driver.TdotCore.{read_build_id, read_caps, obs_clear,
  obs_freeze, obs_snap, obs_read, obs_read_shadow}`;
- вместе с OBS внесён **4KB-кламп read-burst** (AXI4 A4.3.1).

---

## 4. ~~DFX Socket~~ — удалён

DFX-сборка полностью удалена из проекта (2026-10-17). Hot-swap RP,
`dfx_swap.py`, `icap_load.py` для flat **неприменимы** и являются легаси.

---

## 5. ~~ICAP / SPI~~ — удалены (не во FLAT)

- `icap_ctrl.sv` существует в дереве, но **не инстанцирован** в flat-top.
- `spi_over_pcie.sv` — **неблокирующий STUB** (не подключён) — см. AUDIT_FULL 2026-10-19, R11.

---

## 6. DDR3 — адресация и формат данных

### 6.0. DDR3 (MIG, `0x80000000`)

- AXI-адрес MIG: `0x80000000`, размер **256 MB** (0x10000000,
  MT41J128M16XX-125, `C0_MEM_SIZE=268435456`). Не путать с флеш W25Q128 (128
  Мбит = 16 МБ).
- Хост: **только через DMA-каналы** `h2c_0..3`/`c2h_0..3` (translateAxiBase=TRUE,
  raw offset от `0x80000000`).

### 6.1. BRAM (diag_bram, `0x10000000`)

- `diag_bram` (BRAM 1024×64) + `diag_bram_ctrl` (AXI4 SINGLE_PORT), размер
  **8 KB** (0x2000). `xdma_ddr3_bd.tcl:511-526,730-733`.
- Хост: **только через DMA-каналы** `h2c_bram_0`/`c2h_bram_0`
  (translateAxiBase=FALSE, полный картовый адрес от `0x10000000`).
- Тот же адрес `0x10000000` обслуживает мастера: host `xdma_0/M_AXI`, tdot
  `M_AXI_TDOT`, MM2S, S2MM (`xdma_ddr3_bd.tcl:730-733`).
- Использование: диагностика read-пути ядра без MIG (см. `docs/REBUILD_INSTRUCTION.md`,
  `docs/CHANGE_LOG_2026-10-03/05/06`; `test_dma dot_bram`).

### 6.2. Данные в памяти

Формат элемента зависит от ELEM_FMT (см. §3.2):

| ELEM_FMT | Байт/элемент | адрес `data[i]` | адрес `weights[i]` | result |
|---|---|---|---|---|
| 0 (legacy) | 8 | `data_start + i*8` | `weights_start + i*8` | одно 64-бит слово, мл. 48 бит |
| 1 (fp32) | 4 | `data_start + i*4` (2 на 64-бит слово) | `weights_start + i*4` | 64-бит слово, мл. 32 бит (WSTRB=0xF) |
| 2 (PACKED6) | 6 | `data_start + i*6` | `weights_start + i*6` | 6 байт, WSTRB=0x3F |

Соглашение хоста (`pytorch_layer/fpga_backend.py`): data `0x0000`, weights
`0x1000`, result `0x2000` (смещения от `0x80000000`).

Регионы планировщика (смещения от `0x80000000`, константы в
`pytorch_layer/xdma_driver.py`):

| Регион | Смещение | Размер | Назначение |
|---|---|---|---|
| Таблица дескрипторов | `0x0010_0000` | 8 KB (256×32 Б) | Кольцо команд (mod 256) |
| Область завершений | `0x0011_0000` | 4 KB (256×16 Б) | Completion-записи |
| Selftest-паттерн | `0x0100_0000` | — | `xdma_driver.py --selftest` |
| data (планировщик) | `0x0020_0000` | 2 MB (256×16 KB) | Слоты data, `idx*0x4000` |
| weights (планировщик) | `0x0060_0000` | 2 MB (256×16 KB) | Слоты weights |
| results (планировщик) | `0x00A0_0000` | 2 KB | `idx*8` |

---

## 7. Регистры XADC (`xadc_temp.sv`, база `0x46000000`)

| Offset | Имя | R/W | Битовое поле |
|---|---|---|---|
| `0x00` | `TEMP` | R | `[15:0]` raw-код температуры |
| `0x04` | `VCCINT` | R | `[15:0]` raw-код VCCINT |
| `0x08` | `STATUS` | R | `[0]` valid |

Формулы: `temp_c = raw * 503.975 / 4096 − 273.15`;
`vccint = raw * 3.0 / 4096`.

XADC доступен через примитив `xadc_prim u_xadc_prim` в
`rtl/integration/xdma_ddr3_core_top.sv` (DCLK = clk50, 50 МГц). Он опрашивает
встроенный XADC (temperature + VCCINT) и подаёт реальные значения в `u_xadc`
(`xadc_temp`, AXI-Lite @ `0x46000000`). Хост — `monitor_temp.py`.

> BUG-031 разрешён: доступ к XADC обеспечивает `xadc_prim` (избегает
> конфликта UTLZ-1, обходит сужение `XADC_En=Off` в MIG). Резерв —
> MIG status через GPIO2 (`0x40020000` + 0x08, bit0=`mmcm_locked`,
> bit1=`init_calib_complete`).

---

## 8. Формат TFloat48 (битовое представление)

```
64-битное слово в DDR3 (ELEM_FMT=0 legacy):
  bits [63:48] = 0x0000
  bits [47:40] = E (экспонента, 8 бит, signed, bias 40)
  bits [39:0]  = M (мантисса, 40 бит = 20 тритов, нормализована [3^18, 3^19))

Декодирование из 64-битного слова o:
  bits48 = ((o & 0xFFFFFFFFFF) << 8) | ((o >> 40) & 0xFF)
  value  = TFloat.from_bits(bits48).to_float()      # ternary_sw/block/tfloat48.py

Кодирование float32 → TFloat48:
  bits48 = ((t.e_int & 0xFF) << 40) | (t.m_int & ((1 << 40) - 1))
  word64 = struct.pack("<Q", bits48)
```

PACKED6 (ELEM_FMT=2): каждый tf48 занимает **6 байт** плотно (E в 6-м байте,
`struct.pack("<Q", bits)[:6]`), без zero-расширения до 8 байт.

---

## 9. ~~RP-варианты (двуxk изделие DFX)~~ — удалены

Сборка flat не содержит RP, `dfx_block_designs/default.tcl`, `test.tcl`,
апертур и `post_bd_dfx.tcl`. Этот раздел удалён вместе с DFX.

---

## 10. Сводка для хост-разработчика

```python
from xdma_driver import XdmaWinDriver, TdotCore

dev  = XdmaWinDriver()            # DLL-драйвер (MMIO-регистры, без DMA)
core = TdotCore(dev, num_mac=32)  # или XdmaWinDma для DMA-каналов

# 1. Данные в DDR3: только через DMA-каналы (h2c_0/c2h_0), см. §1.2.
#    write_input() -> write_dma(ddr_off) с offset от 0x80000000.

# 2. Программирование ядра (AXI-Lite, работает всегда):
core.set_addrs(0x0000, 0x1000, 0x2000)   # + 0x80000000 внутри set_addrs
core.set_n(n)
core.start()
core.wait_done(timeout_ms=5000)
res48 = core.read_result_reg()           # или чтение result из памяти (DMA)

# 3. BRAM-диагностика (без MIG): `test_dma dot_bram n`, см. §6.1.
```

Чтобы не потеряться в отличиях DFX/FLAT, брать за основу:
`docs/worklog.md` от 2026-10-17 (удаление DFX) и `docs/AUDIT_FULL_2026-10-19.md`.

---

## 11. История изменений карты

| Дата | Изменение |
|---|---|
| 2026-08-25 | Исходная легаси-карта: TDOT `0x44000000`, ICAP `0x46000000` |
| 2026-08-26 | `resize_bar0.tcl`: BAR0 128MB; TDOT `0x40001000`, ICAP `0x40002000` (не-DFX) |
| 2026-08-30 | FIX-5: XADC `0x46000000`, `u_xadc` инстанцирован в top |
| 2026-09-01 | DFX-интеграция: HWICAP/DFX Socket/TDOT/ICAP (каноническая DFX-карта) |
| 2026-09-05 | Переписано под DFX-карту; документировано отсутствие PCIe-мэппинга DDR3 |
| 2026-09-06 | Планировщик TDOT: регистры 0x40–0x60, long-dot, DDR-регионы, IRQ MSI-X |
| 2026-09-27 | SPI-over-PCIe зафиксирован; актуализация XADC/BUG-031 |
| 2026-10-01 | Периферия сдвинута на +0x20000 (GPIO 0x40020000, TDOT 0x40023000) |
| 2026-10-17 | **DFX полностью удалён** — только flat. ADDRESS_MAP переписан под flat |
| 2026-10-19 | **Актуализация под flat-код** (AUDIT_FULL_2026-10-19): добавлены BRAM `0x10000000`, каналы `h2c_bram/c2h_bram` (translateAxiBase=FALSE), таблица периферии без DFX/ICAP/SPI, форматы ELEM_FMT (0/1/2), §4/5/9 помечены удалёнными |

---

## 12. Контрольный список соответствия

При любом изменении адресов/регистров проверить совпадение с этим файлом:

- [x] `scripts/build_flat.tcl` — шаг 2d (BAR0, адреса, диапазоны 4K)
- [x] `scripts/xdma_ddr3_bd.tcl` — assign_bd_address (AXI-Lite, DDR3, BRAM)
- [x] `scripts/post_bd_flat.tcl` — периферия flat
- [x] `rtl/integration/tdot_axi4.sv` — регистровая карта §3
- [x] `rtl/integration/xdma_ddr3_core_top.sv` — инстанции u_tdot/u_xadc
- [x] `driver/dma/build/XDMA_DMA.inf` — HWID PCI\VEN_10EE&DEV_7024
- [x] `driver/dma` (dma_driver.c, file_io.c, dma_engine.c) — симлинки, каналы, translateAxiBase
- [x] `README.md` — раздел «Карта адресов»
- [x] `pytorch_layer/xdma_driver.py` — REG_BASE `0x40023000`; write_dma/read_dma сдвиг от DDR3_BASE
- [x] `pytorch_layer/test_dma_win.py` — TDOT/GPIO/DDR3_BASE
- [x] `pytorch_layer/monitor_temp.py` — XADC_BASE `0x46000000`