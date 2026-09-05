# ADDRESS MAP — единый источник истины (DFX-вариант)

> **Служебный файл**: единственная согласованная карта адресов, регистров и
> BAR-конфигурации проекта **XDMA + DDR3 + DFX (TFloat48)** на Artix-7
> XC7A200T (ветка `XDMA_DDR3_TMUL`).
>
> **Активная сборка**: `scripts/build_dfx.tcl` → `scripts/xdma_ddr3_dfx_bd.tcl`
> → `scripts/post_bd_dfx.tcl` + RP из `dfx_block_designs/default.tcl`
> (альтернатива: `dfx_block_designs/test.tcl`).
>
> Все остальные источники (RTL-комментарии, BD TCL, драйвер, хост-софт,
> README) обязаны соответствовать этому файлу. Любые правки адресов
> **сначала** вносятся сюда, затем синхронизируются во все остальные файлы.
>
> Легаси не-DFX карта (TDOT `0x40001000`, ICAP `0x40002000`, ссылки на
> `build_all.tcl`) **устарела** — см. §11 «История изменений».

---

## 1. PCIe / BAR конфигурация

| Параметр | Значение | Где задано |
|---|---|---|
| PCIe Vendor ID | `0x10EE` (Xilinx) | `pf0_device_id`-блок в `scripts/xdma_ddr3_dfx_bd.tcl` |
| PCIe Device ID | `0x7024` | то же + `driver/XDMA.inx`, `xdma_driver_win_src_2017/sys/XDMA.inf` |
| PCIe lanes / Gen | x4 Gen2 | `pl_link_cap_max_link_width/speed` в BD |
| Режим XDMA | **AXI DMA** (2 H2C + 2 C2H канала) + AXI-Lite bridge | `xdma_rnum_chnl/wnum_chnl`, `axilite_master_en` |
| **BAR0** (AXI-Lite, M_AXI_LITE) | **128 MB**, окно AXI `0x40000000`…`0x47FFFFFF` | `scripts/build_dfx.tcl` шаг 2d (`pf0_bar0_scale/size`), `pf0_bar2axibar_axil_master=0x40000000` |
| **BAR2** | НЕ сконфигурирован как мост данных; таблица MSI-X размещена на 64-битном BAR2 (`pf0_msix_cap_table_bir = BAR_3:2`) | BD-конфиг XDMA; фактический размер BAR2 печатает «PCIe BAR REPORT» в `build_dfx.tcl` шаг 2d |
| **DDR3 в PCIe-пространстве** | **Отсутствует** — DMA-режим: данные хост↔DDR3 идут через H2C/C2H каналы XDMA | см. §1.2 |

### 1.1. Выбор BAR / устройства (логика хост-драйвера)

| Диапазон AXI-адресов | Канал доступа | Что там |
|---|---|---|
| `0x40000000` … `0x47FFFFFF` | Windows: `\\.\XDMA0` (FIX-1 роутит в BAR0); Linux: `/dev/xdma0_control`, offset = addr − 0x40000000 | Вся периферия AXI-Lite (§2) |
| `0x80000000` … `0x8FFFFFFF` | Только DMA-каналы (h2c/c2h) | DDR3 256 MB (§6) |

### 1.2. Куда идут данные (важно для хост-софта)

В DFX-сборке XDMA работает в **DMA-режиме**: `M_AXI` обслуживает
H2C/C2H-каналы (SmartConnect → MIG `0x80000000` и RP). Второй BAR-мост к
DDR3 **не сконфигурирован**, поэтому:

- MMIO-чтение/запись DDR3 с хоста (через `/dev/xdma0_user` / BAR2) в DFX-сборке
  **не работает** — второго BAR-моста нет;
- поток данных хост↔DDR3: **DMA-каналы** (`/dev/xdma0_h2c_0`,
  `/dev/xdma0_c2h_0` на Linux; `xdma_rw.exe h2c_0 ...` на Windows).
  Python DMA-API реализована в `xdma_driver.py`: `XdmaDevice.write_dma/
  read_dma` (смещения от `0x8000_0000`, чанки 1 МиБ, кратность 4 байта);
  `TdotCore.write_tf48/read_tf48` идут через неё автоматически; на Linux при
  наличии usr-узла (легаси-сборка с BAR2) — прозрачный MMIO-фолбэк.
  Самопроверка на железе: `python xdma_driver.py --selftest [--dot]`;
- ядро `tdot_axi4` читает/пишет DDR3 самостоятельно (M_AXI_TDOT → SmartConnect
  → MIG), хост лишь программирует адреса в регистрах (§3);
- DataMover'ы внутри RP ходят в DDR3 по **RP-локальным** адресам
  `0x00000000…0x0FFFFFFF` (алиас окна MIG, апертура RP `APERTURES {{0x0 256M}}`).

> MSI-X: таблица прерываний лежит на 64-битном BAR2
> (`pf0_msix_cap_table_bir = BAR_3:2`, offset `0x8000`, PBA `0x8FE0`).
> Корректность включения/размера BAR2 контролирует «PCIe BAR REPORT» при
> сборке (`build_dfx.tcl` шаг 2d). При переключении драйвера на polled-режим
> BAR2 может отсутствовать.

---

## 2. Карта AXI-Lite (внутри BAR0, каноническая DFX-карта)

Источник истины: `scripts/xdma_ddr3_dfx_bd.tcl` (assign_bd_address),
`scripts/build_dfx.tcl` шаг 2d, `scripts/post_bd_dfx.tcl`.

| Периферия | Базовый адрес | Размер | Мастер lite-SMC | Назначение |
|---|---|---|---|---|
| **AXI GPIO (LED/status)** | `0x40000000` | 4 KB | M00 | GPIO ch1: 3 светодиода (out); GPIO2 ch2: 2 бита MIG status (`mmcm_locked`, `init_calib_complete`) |
| **AXI HWICAP** | `0x40001000` | 4 KB | M02 | Xilinx IP (PG135), ICAP-клок = clk50 (50 MHz) — стандартный путь загрузки битстримов |
| **DFX Socket** | `0x40002000` | 4 KB | M01 | `dfx_socket/decouple_shutdown_ctrl`: shutdown/decouple RP — см. §4 |
| **TDOT registers** | `0x40003000` | 4 KB | M03 | Регистры троичного ядра `tdot_axi4` — см. §3 |
| **ICAP registers** | `0x40004000` | 4 KB | M04 | Кастомный `icap_ctrl` (ICAPE2 X32 @ 62.5 MHz) — см. §5 |
| **DFX Partition MM2S** | `0x40010000` | 4 KB | — | DataMover MM2S control (внутри RP, через `dfx_socket`) |
| **DFX Partition S2MM** | `0x40018000` | 4 KB | — | DataMover S2MM control (внутри RP, через `dfx_socket`) |
| **XADC** | `0x46000000` | 4 KB | M05 | Температура/VCCINT (`xadc_temp.sv`, `u_xadc`) — см. §7 |

> Диапазон `0x40011000`–`0x40017FFF` и `0x40019000`–`0x4001FFFF` внутри
> апертуры RP (`0x40010000`, 64 KB) свободен для дополнительных IP будущих
> RP-вариантов (например, GPIO варианта `test.tcl` @ `0x40012000`).

---

## 3. Регистры TDOT (`tdot_axi4.sv`, база `0x40003000`)

Источник истины: `rtl/integration/tdot_axi4.sv` (декод `[5:2]`).

Все регистры 32-битные, байтовый адрес.

| Offset | Имя | R/W | Битовое поле | Описание |
|---|---|---|---|---|
| `0x00` | `CTRL` | W | `[0]` GO | Запуск вычисления; самосброс через 1 такт |
| `0x04` | `STATUS` | R | `[0]` BUSY, `[1]` DONE | Состояние вычислителя |
| `0x08` | `N_IN` | R/W | `[31:0]` | Число пар (1…NUM_MAC); 0 или >NUM_MAC → эффективно NUM_MAC |
| `0x0C` | `RES0` | R | `[31:0]` | Результат `[31:0]` (защёлкивается по DONE) |
| `0x10` | `RES1` | R | `[15:0]` | `{16'h0, результат[47:32]}` |
| `0x14`/`0x18` | `DATA_ADDR_LO/HI` | R/W | `[31:0]` | Полный AXI-адрес `data` в DDR3 (`0x80000000 + смещение`) |
| `0x1C`/`0x20` | `WEIGHTS_ADDR_LO/HI` | R/W | `[31:0]` | Адрес `weights` |
| `0x24`/`0x28` | `RESULT_ADDR_LO/HI` | R/W | `[31:0]` | Адрес результата |
| `0x2C`/`0x30` | `CORE_RES0/1` | R | `[31:0]`/`[15:0]` | Живые зеркала результата ядра (debug, AUDIT-05) |

Сборка 48-битного результата:
`result = ((res1 & 0xFFFF) << 32) | (res0 & 0xFFFFFFFF)`.

⚠ `test_xdma.c`/`emulate_test.py` исторически собирали результат как
`... | (res0 & 0xFFFF)` — теряя биты [31:16]. В драйвере это исправлено
(`FIX-1`), формула выше — каноническая.

---

## 4. DFX Socket (`decouple_shutdown_ctrl`, база `0x40002000`) — горячая замена

AXI GPIO v2.0 (dual). Регистры: GPIO_DATA `0x00`, GPIO_TRI `0x04`,
GPIO2_DATA `0x08`, GPIO2_TRI `0x0C`. Проводка — `xdma_ddr3_dfx_bd.tcl`,
hier `dfx_socket`.

**Канал 1 (выходы, 3 бита)** — управление:

| Бит | Назначение | Куда идёт |
|---|---|---|
| 0 | **DECOUPLE** — удерживать `rp_resetn` в сбросе | `dfx_decoupler.resetn.decouple` |
| 1 | **SHUTDOWN M** — заглушить шину RP M_AXI (RP → статика/DDR3) | `dfx_axi_shutdown_static_master.request_shutdown` |
| 2 | **SHUTDOWN S** — заглушить шину RP S_AXI (статика → RP) | `dfx_axi_shutdown_static_slave.request_shutdown` |

**Канал 2 (входы, 5 бит = `xlconcat_status`)** — статус:

| Бит | Сигнал |
|---|---|
| 0 | master `shutdown_requested` |
| 1 | master `in_shutdown` |
| 2 | slave `shutdown_requested` |
| 3 | slave `in_shutdown` |
| 4 | `decouple_status` |

### 4.1. Протокол горячей замены RP (без JTAG)

1. Записать `0b111` в `GPIO_DATA` (decouple + оба shutdown).
2. Дождаться `GPIO2_DATA == 0b11010` (`in_shutdown` M+S + `decouple_status`).
3. Загрузить **частичный** битстрим RP: через `icap_ctrl` (`0x40004000`,
   протокол §5, скрипт `pytorch_layer/icap_load.py`) или через HWICAP
   (`0x40001000`, PG135).
4. Записать `0b000` в `GPIO_DATA` — `dfx_axi_shutdown_manager` возобновляет
   шины, `dfx_decoupler` снимает сброс RP. PCIe-линк и статика живы всё время.
5. Проверить, что статус ушел в `0b00000`.

Всё это делает одной командой `pytorch_layer/dfx_swap.py <partial.bit>`
(`--status` — только статус, `--timeout`, `--no-verify`).

Частичные битстримы производит сборка: `build_dfx.tcl` шаг 9b /
`gen_bitstream.tcl` (экспорт `*partial*.bit|.bin` в `build/artifacts_dfx/`).

⚠ Апертура/присоединение RP менять нельзя без пересмотра pblock и
register slice'ов (`rp_m_axi_register_slice`, `rp_s_axi_register_slice`
должны совпадать по настройкам — требование UG909).

---

## 5. Регистры ICAP (`icap_ctrl.sv`, база `0x40004000`)

Источник истины: `rtl/integration/icap_ctrl.sv` (декод `[3:2]`).

| Offset | Имя | R/W | Битовое поле | Описание |
|---|---|---|---|---|
| `0x00` | `CTRL` | W | `[0]` GO, `[1]` STOP | GO — старт сессии; STOP — завершение. Самосброс. |
| `0x04` | `STATUS` | R | `[0]` READY, `[1]` BUSY | READY=1 → mailbox свободен. BUSY=1 — сессия активна. |
| `0x08` | `DATA` | W | `[31:0]` | Слово битстрима (LE-представление BE-слова `.bin`). |

Протокол: `CTRL←GO` → для каждого слова: ждать `READY`, писать `DATA` →
`CTRL←STOP`. Порядок байтов: BE-слово `0xAA995566` пишется как `0x665599AA`
(`icap_load.py` делает это автоматически, контракт совпадает с ядром Linux
`xilinx_hwicap`). ICAPE2 тактируется 62.5 MHz (деление 125 MHz / 2 через
register-toggle + BUFG; BUFGCE_DIV на Artix-7 недоступен).

⚠ В `test_xdma.c` регистры называются `ICAP_GO`/`ICAP_READY` (адреса те же),
регистр `DATA` не объявлен — загрузка битстрима через test_xdma невозможна;
использовать `icap_load.py`/`dfx_swap.py`.

---

## 6. DDR3 — адресация и формат данных

- AXI-адрес MIG: `0x80000000`, размер **256 MB** (MT41J128M16XX-125, 16 бит,
  `mig_a.prj` в `xdma_ddr3_dfx_bd.tcl`).
- Хост: только через DMA-каналы (§1.2). RP: RP-локальный алиас `0x00000000`.
- Каждый TFloat48 занимает **64-битное слово** (8 байт, little-endian):
  `[16'h0][E:8][M:40]` — младшие 48 бит значимы.

| Что | Формула адреса |
|---|---|
| `data[i]`    | `data_start    + i * 8` |
| `weights[i]` | `weights_start + i * 8` |
| `result`     | `result_addr` (одно 64-битное слово) |

Соглашение хоста (`pytorch_layer/fpga_backend.py`): data `0x0000`,
weights `0x1000`, result `0x2000` (смещения от `0x80000000`).

---

## 7. Регистры XADC (`xadc_temp.sv`, база `0x46000000`)

| Offset | Имя | R/W | Битовое поле |
|---|---|---|---|
| `0x00` | `TEMP` | R | `[15:0]` raw-код температуры |
| `0x04` | `VCCINT` | R | `[15:0]` raw-код VCCINT |
| `0x08` | `STATUS` | R | `[0]` valid |

Формулы: `temp_c = raw * 503.975 / 4096 − 273.15`;
`vccint = raw * 3.0 / 4096`.

⚠ **BUG-031**: Artix-7 имеет 1 XADC, и он занят MIG (`XADC_En=Off` в MIG,
`xadc_wiz` не создаётся во избежание UTLZ-1). `u_xadc` отвечает на AXI, но
`raw_* = 0` → `monitor_temp.py` читает 0°C/0V. Реальную температуру брать из
MIG status через GPIO2 `axi_gpio_0` (`0x40000000`, GPIO2_DATA `0x08`,
bit0=`mmcm_locked`, bit1=`init_calib_complete`) либо через MIG DRP (TODO).

---

## 8. Формат TFloat48 (битовое представление)

```
64-битное слово в DDR3:
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

---

## 9. RP-варианты (`dfx_block_designs/`)

RP-локальная карта (адреса идентичны host-виду, апертура RP 64 KB
`0x40010000`–`0x4001FFFF`; RP-мастер видит DDR3 с `0x00000000`, 256 MB):

| Сегмент (rp_S_AXI) | default.tcl | test.tcl |
|---|---|---|
| DataMover MM2S control | `0x40010000` / 4K | `0x40010000` / 4K |
| DataMover S2MM control | `0x40018000` / 4K | `0x40018000` / 4K |
| GPIO (внутри RP) | — | `0x40012000` / 4K |
| DataMover Data_MM2S/Data_S2MM (→ MIG) | `0x00000000` / 256 MB | то же |

> ИСПРАВЛЕНО 2026-09-05: в `test.tcl` S2MM был на RP-локальном
> `0x40011000` — хост по каноническому адресу `0x40018000` в него не попадал.
> Диапазоны всех сегментов DataMover унифицированы до 4 KB (и на стороне
> статики: `build_dfx.tcl`, `xdma_ddr3_dfx_bd.tcl`), чтобы оставлять место
> для дополнительных IP внутри апертуры RP.

> WIDENED 2026-09-06: AXIS-сторона DataMover'ов расширена 32→64 бита
> (`c_m_axis_mm2s_tdata_width`/`c_s_axis_s2mm_tdata_width` = 64) в обоих
> вариантах RP (`default.tcl`, `test.tcl`). Потоковый тракт RP: 64b×125 МГц =
> 1,0 ГБ/с (было 500 МБ/с). AXI-сторона (128b), CMD/STS-интерфейсы
> (104/8 бит) и адреса не изменялись; `axis_data_fifo` наследует ширину
> автоматически.

---

## 10. Сводка для хост-разработчика

```python
from xdma_driver import XdmaLinux, XdmaWindows, TdotCore

dev  = XdmaWindows()          # или XdmaLinux("/dev/xdma0")
core = TdotCore(dev, num_mac=32)

# 1. Данные в DDR3: в DFX-сборке — через DMA (h2c/c2h), см. §1.2.
#    (write_tf48() через MMIO работает только в легаси не-DFX сборке с BAR2.)

# 2. Программирование ядра (AXI-Lite, работает всегда):
core.set_addrs(0x0000, 0x1000, 0x2000)   # + 0x80000000 внутри set_addrs
core.set_n(n)
core.start()
core.wait_done(timeout_ms=5000)
res48 = core.read_result_reg()           # или чтение result из DDR3 (DMA)

# 3. Горячая замена RP без JTAG:
#    python pytorch_layer/dfx_swap.py build/artifacts_dfx/*partial*.bit
```

---

## 11. История изменений карты

| Дата | Изменение |
|---|---|
| 2026-08-25 | Исходная легаси-карта: TDOT `0x44000000`, ICAP `0x46000000` |
| 2026-08-26 | `resize_bar0.tcl`: BAR0 128MB; TDOT `0x40001000`, ICAP `0x40002000` (не-DFX) |
| 2026-08-30 | FIX-5: XADC `0x46000000`, `u_xadc` инстанцирован в top |
| 2026-09-01 | DFX-интеграция: HWICAP `0x40001000`, DFX Socket `0x40002000`, TDOT `0x40003000`, ICAP `0x40004000` (каноническая DFX-карта) |
| 2026-09-05 | **Этот файл переписан под DFX-карту** (легаси-карта удалена). MM2S/S2MM-сегменты 32K→4K (build_dfx.tcl, xdma_ddr3_dfx_bd.tcl, default.tcl); `test.tcl` S2MM `0x40011000`→`0x40018000`; задокументировано отсутствие PCIe-мэппинга DDR3 (DMA-only); добавлены §4 (DFX Socket/горячая замена) и §9 (RP-варианты). Синхронизировано: README.md, xdma_driver.py, dfx_swap.py (новый), monitor_temp.py, build_dfx.tcl |

---

## 12. Контрольный список соответствия

При любом изменении адресов/регистров проверить совпадение с этим файлом:

- [x] `scripts/build_dfx.tcl` — шаг 2d (BAR0, адреса, диапазоны 4K)
- [x] `scripts/xdma_ddr3_dfx_bd.tcl` — assign_bd_address + APERTURES RP
- [x] `scripts/post_bd_dfx.tcl` — TDOT/ICAP/XADC-порты и адреса
- [x] `dfx_block_designs/default.tcl`, `dfx_block_designs/test.tcl` — RP-локальная карта
- [x] `rtl/integration/tdot_axi4.sv` — регистровая карта §3
- [x] `rtl/integration/icap_ctrl.sv` — регистровая карта §5
- [x] `rtl/integration/xdma_ddr3_core_top.sv` — инстанции u_tdot/u_icap/u_xadc
- [x] `README.md` — раздел «Карта адресов»
- [x] `pytorch_layer/xdma_driver.py` — REG_BASE `0x40003000`, ICAP_BASE `0x40004000`, DFX_SOCK_BASE `0x40002000`, HWICAP_BASE `0x40001000`
- [x] `pytorch_layer/icap_load.py` — ICAP_BASE `0x40004000`
- [x] `pytorch_layer/dfx_swap.py` — DFX_SOCK_BASE `0x40002000` + биты §4
- [x] `pytorch_layer/monitor_temp.py` — XADC_BASE `0x46000000`
- [x] `driver/driver.c` (FIX-1), `driver/test_xdma.c` — границы BAR0/BAR2, адреса периферии
