# ADDRESS MAP — единый источник истины

> **Служебный файл**: единственная согласованная карта адресов и регистров
> проекта **XDMA + DDR3 троичного FP-ускорителя TFloat48** на Artix-7 XC7A200T.
>
> Все остальные источники (RTL-комментарии, BD TCL, документация, драйвер,
> хост-софт, тесты) обязаны соответствовать этому файлу. Любые правки
> **сначала** вносятся сюда, затем синхронизируются во все остальные файлы.
>
> **Источник истины для адресов** — `scripts/build_all.tcl` (см. шаг 5).
> **Источник истины для регистров** — `rtl/integration/tdot_axi4.sv`,
> `rtl/integration/icap_ctrl.sv`.

---

## 1. PCIe / BAR конфигурация

| Параметр | Значение | Где задано |
|---|---|---|
| PCIe Vendor ID | `0x10EE` (Xilinx) | `sys/XDMA.inf`, `sys/XDMA.inx`, `driver/XDMA.inx` |
| PCIe Device ID | `0x7024` (XDMA Bridge Subsystem) | то же |
| PCIe lanes / Gen | x4 Gen2 | `scripts/xdma_ddr3_bd.tcl` (XDMA IP config) |
| BAR0 (AXI-Lite, M_AXI_LITE) | **128 MB** (`0x08000000`), окно `0x40000000`…`0x47FFFFFF` | `scripts/build_all.tcl:40-43`, `scripts/resize_bar0.tcl` |
| BAR2 (DDR3, M_AXI) | **256 MB** (`0x10000000`), окно `0x80000000`…`0x8FFFFFFF` | `scripts/xdma_ddr3_bd.tcl:483`, `scripts/add_tdot_axi4_bd.tcl:38` |
| `pciebar2axibar_axil_master` | `0x40000000` (BAR0 → AXI-Lite base) | `scripts/xdma_ddr3_bd.tcl:432` |

### 1.1. Выбор BAR по смещению (логика драйвера)

| Диапазон offset (байт, в `OVERLAPPED.Offset` / `lseek`) | BAR | Что туда попадает |
|---|---|---|
| `0x00000000` … `0x07FFFFFF` | BAR0 | AXI-Lite (относительный offset внутри BAR0; см. §2) |
| `0x08000000` … `0x7FFFFFFF` | BAR0 | «дыра» (внутри 128 MB BAR0; не декодируется периферией) |
| `0x80000000` … `0x8FFFFFFF` | BAR2 | DDR3 (256 MB), `offset − 0x80000000` → BAR2 offset |
| `≥ 0x90000000` | — | вне диапазона, драйвер вернёт `STATUS_INVALID_PARAMETER` |

> **Важно для хост-софта**: Windows-драйвер принимает **абсолютный AXI-адрес**
> (т.е. `0x40001000` для TDOT, `0x80000000` для DDR3). Linux-драйвер
> `/dev/xdma0_control` использует **BAR0-relative offset** (т.е. `0x1000` для
> TDOT). См. §6 «Известные несоответствия».

---

## 2. Карта адресов AXI-Lite (внутри BAR0)

Истинная карта (по `scripts/build_all.tcl:48-63`):

| Периферия | Базовый адрес | Размер | Назначение | RTL/BD-порт |
|---|---|---|---|---|
| **AXI GPIO (LED)** | `0x40000000` | 4 KB | 3 светодиода (GPIO_DATA, GPIO_TRI) | `axi_gpio_0/S_AXI/Reg` |
| **TDOT registers** | `0x40001000` | 4 KB | Регистры троичного ядра `tdot_axi4` | `S_AXI_TDOT_REGS/Reg` |
| **ICAP** | `0x40002000` | 4 KB | Контроллер ICAP (`icap_ctrl`) | `S_AXI_ICAP_REGS/Reg` |
| **XADC** | `0x46000000` | 4 KB | Температура/VCCINT (`xadc_temp.sv`, FIX-5: подключён к `u_xadc`) | `S_AXI_XADC_REGS/Reg` (M03) |
| **DEBUG** *(зарезервировано, НЕ реализовано)* | `0x47000000` | 4 KB | Debug-монитор `debug_mon.sv` — **модуль отсутствует** (см. `ANALYSIS_AND_SPEC_FIX.md` B-5) | — |
| **DDR3 (AXI4 M_AXI)** | `0x80000000` | 256 MB | Данные для вычислений | `mig_7series_0/memmap/memaddr` |
| **BRAM** (через axi_smc) | `0x00000000` | 8 KB | Тестовый буфер / debug | `axi_bram_ctrl_0/S_AXI/Mem0` |

### 2.1. Статус XADC

✅ **FIX-5 (RTL-1)**: `xadc_temp.sv` **инстанцирован** в `xdma_ddr3_core_top.sv`
как `u_xadc` (база `0x46000000`). BD-порт `S_AXI_XADC_REGS` (создаваемый
`scripts/add_icap_xadc_bd.tcl` на `M03`) подключён к AXI-Lite slave.

- Модуль `rtl/integration/xadc_temp.sv` (92 строки) добавляется в `build_all.tcl:26`.
- BD-порт `S_AXI_XADC_REGS` создаётся на `M03` (canonically, FIX-5 RTL-2):
  `scripts/add_icap_xadc_bd.tcl` (адрес `0x46000000`, синхронизировано с
  `resize_bar0.tcl` и `build_all.tcl`).
- Top-level подключение: `xdma_ddr3_core_top.sv:168-181` (instance `u_xadc`).

⚠ **Ограничение**: входы `raw_temp`, `raw_vccint`, `raw_valid` привязаны к 0
(пока в BD не заведён XADC Wizard IP). Слеив отвечает (BVALID/RVALID формируются),
но TEMP/VCCINT читаются как 0. Для реальных значений температуры — добавить
XADC Wizard IP в BD и подключить его выходы к `u_xadc.raw_*` (TODO).

⚠ **Follow-up**: `pytorch_layer/monitor_temp.py:19` всё ещё использует
`XADC_BASE = 0x4500_0000` (устаревший адрес из `add_icap_xadc_bd.tcl` до FIX-5).
Требуется отдельный фикс в host-софте: заменить на `0x4600_0000`.

---

## 3. Регистры TDOT (`tdot_axi4.sv`, база `0x40001000`)

Источник истины: `rtl/integration/tdot_axi4.sv:17-30`.

Все регистры 32-битные, байтовый адрес. Декод `[5:2]` (4-битный индекс).

| Offset | Имя | R/W | Битовое поле | Описание |
|---|---|---|---|---|
| `0x00` | `CTRL` | W | `[0]` GO | Запуск вычисления; самосброс через 1 такт. Запись `0x1` = GO. |
| `0x04` | `STATUS` | R | `[0]` BUSY, `[1]` DONE | BUSY=1 во время выполнения, DONE=1 после завершения |
| `0x08` | `N_IN` | R/W | `[31:0]` | Число пар (1…NUM_MAC); 0 или >NUM_MAC → эффективное значение = NUM_MAC |
| `0x0C` | `RES0` | R | `[31:0]` | Результат `[31:0]` (защёлкивается по DONE) |
| `0x10` | `RES1` | R | `[15:0]` | `{16'h0, результат[47:32]}` (верхние 16 бит результата; биты 31:16 = 0) |
| `0x14` | `DATA_ADDR_LO` | R/W | `[31:0]` | Младшие 32 бита байтового адреса `data` в DDR3 |
| `0x18` | `DATA_ADDR_HI` | R/W | `[31:0]` | Старшие 32 бита адреса `data` |
| `0x1C` | `WEIGHTS_ADDR_LO` | R/W | `[31:0]` | Младшие 32 бита адреса `weights` |
| `0x20` | `WEIGHTS_ADDR_HI` | R/W | `[31:0]` | Старшие 32 бита адреса `weights` |
| `0x24` | `RESULT_ADDR_LO` | R/W | `[31:0]` | Младшие 32 бита адреса результата |
| `0x28` | `RESULT_ADDR_HI` | R/W | `[31:0]` | Старшие 32 бита адреса результата |
| `0x2C` | `CORE_RES0` | R | `[31:0]` | Read-only зеркало результата ядра `[31:0]` (живое значение) |
| `0x30` | `CORE_RES1` | R | `[15:0]` | `{16'h0, результат[47:32]}` (живое значение, без ожидания DONE) |

### 3.1. Сборка 48-битного результата из регистров

```c
// Правильно (RES0 = 32 бита, RES1 = 16 бит):
uint64_t result = ((uint64_t)(res1 & 0xFFFF) << 32) | (res0 & 0xFFFFFFFF);
```

⚠ **НЕ ДЕЛАТЬ ТАК** (устаревший код с ошибкой, теряет биты [31:16]):
```c
// ОШИБКА (test_xdma.c:308, emulate_test.py:290):
uint64_t result = ((uint64_t)(res1 & 0xFFFF) << 32) | (res0 & 0xFFFF);
```

Альтернатива (если нужны все 48 бит безусловно): читать результат из DDR3
по `RESULT_ADDR` (младшие 48 бит 64-битного слова).

### 3.2. То же в `tdot_axi_lite.sv`

LEGACY-дубль `tdot_axi_lite.sv` (не используется в `xdma_ddr3_core_top.sv`,
оставлен для standalone-проверки `core_wrapper_top.sv`) держит
**идентичную** регистровую карту. В комментарии шапки файла было описание
`[0x14] DATA_ADDR_LO/HI` (без указания, что 0x14 = LO, 0x18 = HI), но
декодирование `case (awaddr_q[5:2])` совпадает с `tdot_axi4.sv`.

---

## 4. Регистры ICAP (`icap_ctrl.sv`, база `0x40002000`)

Источник истины: `rtl/integration/icap_ctrl.sv:1-15`.

| Offset | Имя | R/W | Битовое поле | Описание |
|---|---|---|---|---|
| `0x00` | `CTRL` | W | `[0]` GO, `[1]` STOP | GO — старт сессии; STOP — завершение. Самосброс. |
| `0x04` | `STATUS` | R | `[0]` READY, `[1]` BUSY | READY=1 → mailbox свободен, можно писать DATA. BUSY=1 — сессия активна. |
| `0x08` | `DATA` | W | `[31:0]` | Write-only. Слово битстрима для ICAP (LE-представление BE-слова `.bin`). |

### 4.1. Протокол загрузки битстрима

1. Хост: `CTRL ← 0x1` (GO) → `STATUS.BUSY` становится 1.
2. Для каждого 32-битного слова битстрима:
   - Хост ждёт `STATUS.READY == 1`.
   - Хост: `DATA ← word` (LE-прочтение BE-слова `.bin`, т.е. байты
     AA 99 55 66 в файле → запись `0x665599AA` в DATA).
3. После отправки всех слов (включая завершающий `DESYNC`):
   Хост: `CTRL ← 0x2` (STOP). `STATUS.BUSY` сбрасывается в 0.

Подробности и обоснование порядка байтов — в
`rtl/integration/icap_ctrl.sv:1-34` и `pytorch_layer/icap_load.py:1-21`.

⚠ В `test_xdma.c` (driver/ и xdma_driver_win_src_2017/exe/) используются
устаревшие **имена** `ICAP_GO` (адрес 0x00) и `ICAP_READY` (адрес 0x04).
Адреса правильные, но имена вводят в заблуждение: `ICAP_GO` = `CTRL`,
`ICAP_READY` = `STATUS` (поле `READY` — бит 0, но в `STATUS` ещё есть `BUSY` —
бит 1). Регистр `DATA` (0x08) в test_xdma.c **вообще не объявлен**, что не
позволяет через этот тест загрузить битстрим.

---

## 5. Регистры XADC (`xadc_temp.sv`, база `0x46000000`)

✅ **FIX-5 (RTL-1)**: инстанцирован как `u_xadc` в `xdma_ddr3_core_top.sv:168-181`.

| Offset | Имя | R/W | Битовое поле | Описание |
|---|---|---|---|---|
| `0x00` | `TEMP` | R | `[15:0]` | Raw-код температуры XADC (формула ниже) |
| `0x04` | `VCCINT` | R | `[15:0]` | Raw-код напряжения VCCINT |
| `0x08` | `STATUS` | R | `[0]` | `valid` — захвачено новое значение |

Формулы (см. `monitor_temp.py`, `test_xdma.c:TestXadc`):
```python
temp_c  = raw_temp  * 503.975 / 4096.0 - 273.15
vccint  = raw_vccint * 3.0    / 4096.0
```

⚠ **В текущей сборке (FIX-5)** `raw_temp`/`raw_vccint`/`raw_valid`
привязаны к 0 — значения TEMP/VCCINT читаются как 0. Для реальных данных —
завести XADC Wizard IP в BD (TODO).

---

## 6. DDR3 (BAR2) — формат данных

Источник: `rtl/integration/tdot_axi4.sv:11-15`, `pytorch_layer/xdma_driver.py:11-15`,
`pytorch_layer/fpga_backend.py:25-28`.

- Базовый адрес в AXI: `0x80000000` (диапазон `0x80000000`…`0x8FFFFFFF`, 256 MB).
- Каждый TFloat48 занимает **64-битное слово** (8 байт, little-endian).
- **Младшие 48 бит** = число TFloat48; **старшие 16 бит не используются**
  (заполняются нулями при записи ядром).

| Что | Формула адреса |
|---|---|
| `data[i]`    | `data_start    + i * 8` |
| `weights[i]` | `weights_start + i * 8` |
| `result`     | `result_addr` (одно 64-битное слово) |

### 6.1. Стандартное размещение (по `pytorch_layer/fpga_backend.py`)

| Символ | Offset от `0x80000000` | Назначение |
|---|---|---|
| `DDR_DATA`    | `0x0000` | Вектор `data` |
| `DDR_WEIGHTS` | `0x1000` | Вектор `weights` |
| `DDR_RESULT`  | `0x2000` | Результат dot |

Это **соглашение хоста**, а не аппаратное требование. Аппаратно адреса
задаются через регистры TDOT `DATA_ADDR_*`, `WEIGHTS_ADDR_*`, `RESULT_ADDR_*`
(см. §3) — ядро читает/пишет по этим адресам.

---

## 7. Формат TFloat48 (битовое представление и декодирование)

Источник: `INTEGRATION_REPORT.md:143-149`, `pytorch_layer/fpga_backend.py:52-64`,
`rtl/integration/tdot_axi4.sv:11-15`.

### 7.1. В памяти (64-битное слово)

```
bits [63:48] = 0x0000            (не используется)
bits [47:40] = E (экспонента, 8 бит, signed, bias 40)
bits [39:0]  = M (мантисса, 40 бит, 20 тритов, нормализована [3^18, 3^19))
```

То есть в памяти формат: `[16'h0][E:8][M:40]` (старший байт = экспонента).

### 7.2. Чтение 48-битного значения из 64-битного слова

```python
# из DDR3 (или из регистров RES0/RES1, собранных как в §3.1):
o = ...  # uint64, только младшие 48 бит значимы

# Декодирование (E переходит в младшие 8 бит, M — в старшие 40):
bits = ((o & 0xFFFFFFFFFF) << 8) | ((o >> 40) & 0xFF)
value = TFloat.from_bits(bits).to_float()
```

### 7.3. Кодирование float32 → TFloat48 → 48 бит

```python
t = TFloat.from_float(x)              # эталон в ternary_sw/block/tfloat48.py
bits48 = ((t.e_int & 0xFF) << 40) | (t.m_int & ((1 << 40) - 1))
# packs в 64-битное слово для DDR3: struct.pack("<Q", bits48)
```

---

## 8. Сводка для хост-разработчика

Минимальный протокол вызова `tdot_axi4`:

```python
# 0. Открыть устройство
dev = XdmaLinux() | XdmaWindows()
core = TdotCore(dev, num_mac=32, ddr_base=0x80000000)

# 1. Подготовить данные в DDR3 (по адресам относительно DDR_BASE)
core.write_tf48(0x0000, data_bits48)      # data[i]
core.write_tf48(0x1000, weights_bits48)   # weights[i]
# результат будет по адресу 0x2000

# 2. Программировать регистры TDOT (база 0x40001000)
core.set_addrs(data_addr=0x0000, weights_addr=0x1000, result_addr=0x2000)
core.set_n(n)             # n = len(data_bits48)
core.start()              # CTRL = 0x1
core.wait_done(timeout_ms=5000)   # poll STATUS.DONE

# 3. Прочитать результат
res48 = core.read_tf48(0x2000)     # 64-битное слово, младшие 48 бит
# или из регистров:
res48 = (core._reg_r(0x10) & 0xFFFF) << 32 | core._reg_r(0x0C) & 0xFFFFFFFF

# 4. Декодировать
value = decode_tf48(res48)
```

---

## 9. История изменений карты

| Дата | Изменение | Где отражено |
|---|---|---|
| 2026-08-25 | Исходная карта: GPIO 0x40000000, TDOT 0x44000000, ICAP 0x46000000, DEBUG 0x47000000 | README/INTEGRATION_REPORT до коммита `696b0f0` |
| 2026-08-26 | `add_icap_xadc_bd.tcl`: XADC 0x45000000, ICAP 0x46000000 (между ICAP и XADC был конфликт) | `scripts/add_icap_xadc_bd.tcl:74,77` |
| 2026-08-26 | `resize_bar0.tcl`: BAR0 128MB; GPIO 0x40000000, TDOT 0x40001000, ICAP 0x40002000, XADC 0x46000000 | `scripts/resize_bar0.tcl` |
| 2026-08-26 | XADC в `test_xdma.c`: 0x45000000 → 0x46000000 (`CHANGELOG.md` [1.0.0]) | `xdma_driver_win_src_2017/CHANGELOG.md:23` |
| 2026-08-27 | Коммит `696b0f0` обещал синхронизацию: фактическая карта в `build_all.tcl` = GPIO 0x40000000, TDOT 0x40001000, ICAP 0x40002000; XADC не назначен | `scripts/build_all.tcl:48-67` |
| 2026-08-28 | **DRV-6**: создан этот файл как единый источник истины; найденные расхождения зафиксированы в `worklog.md` (раздел DRV-6) | `docs/ADDRESS_MAP.md` (этот файл) |
| 2026-08-30 | **FIX-5 RTL-1**: инстанцирован `xadc_temp.sv` как `u_xadc` в `xdma_ddr3_core_top.sv`; `S_AXI_XADC_REGS` подключён к top-level | `rtl/integration/xdma_ddr3_core_top.sv:147-181, 244-255` |
| 2026-08-30 | **FIX-5 RTL-2**: `add_icap_xadc_bd.tcl` синхронизирован с `build_all.tcl`/`resize_bar0.tcl` — M02=ICAP@0x40002000, M03=XADC@0x46000000 (раньше M02=XADC@0x45000000, M03=ICAP@0x46000000) | `scripts/add_icap_xadc_bd.tcl` |
| 2026-08-30 | **FIX-5 RTL-3**: в `add_icap_xadc_bd.tcl` добавлен cleanup legacy `M_AXI_ICAP` (ANALYSIS_AND_SPEC_FIX.md B-3); после `make_wrapper -force` порт исчезнет из wrapper | `scripts/add_icap_xadc_bd.tcl` |
| 2026-08-30 | **FIX-5 RTL-4**: `debug_mon.sv` подтверждённо отсутствует — документация обновлена (README, INTEGRATION_REPORT, §2). Адрес 0x47000000 остаётся зарезервированным | `README.md`, `INTEGRATION_REPORT.md`, `docs/ADDRESS_MAP.md` |

---

## 10. Контрольный список соответствия

При любом изменении адресов/регистров **обязательно** обновить (пройти
по списку и проверить совпадение с этим файлом):

- [x] `scripts/build_all.tcl` — источник истины (адреса)
- [x] `scripts/resize_bar0.tcl` — соответствует `build_all.tcl`
- [x] `scripts/xdma_ddr3_bd.tcl` — `pciebar2axibar_axil_master = 0x40000000`
- [x] `scripts/add_icap_xadc_bd.tcl` — **FIX-5**: синхронизирован с актуальной картой (M02=ICAP@0x40002000, M03=XADC@0x46000000); добавлен cleanup legacy M_AXI_ICAP
- [ ] `scripts/add_tdot_axil_host.tcl` — deprecated (TDOT 0x44000000, расходится с `build_all.tcl`)
- [x] `rtl/integration/tdot_axi4.sv` — шапка-комментарий (строки 17-30) + декод `[5:2]`
- [x] `rtl/integration/tdot_axi_lite.sv` — то же
- [x] `rtl/integration/icap_ctrl.sv` — шапка (строки 1-15) + декод `[3:2]`
- [x] `rtl/integration/xadc_temp.sv` — декод `[3:2]`
- [x] `rtl/integration/xdma_ddr3_core_top.sv` — **FIX-5**: инстанция `u_xadc` подключена к `S_AXI_XADC_REGS`
- [x] `README.md` — раздел «Карта адресов» (**FIX-5**: XADC=0x46000000, debug_mon помечен как не реализованный)
- [x] `INTEGRATION_REPORT.md` — таблица адресов (**FIX-5**: убраны упоминания debug_mon как существующего)
- [x] `ANALYSIS_AND_SPEC_FIX.md` — часть B-2 (историческая сверка)
- [ ] `pytorch_layer/fpga_backend.py` — `DDR_DATA/DDR_WEIGHTS/DDR_RESULT`
- [ ] `pytorch_layer/xdma_driver.py` — `REG_BASE`, `ICAP_BASE`, `GPIO_BASE`, `DDR_BASE`
- [ ] `pytorch_layer/icap_load.py` — `ICAP_BASE`, `REG_CTRL/STATUS/DATA`
- [ ] `pytorch_layer/monitor_temp.py` — `XADC_BASE` ⚠ **осталось 0x45000000**, требует отдельного фикса на `0x46000000` (не в объёме FIX-5)
- [ ] `driver/driver.c` — BAR0/BAR2 boundary = `0x80000000`
- [ ] `driver/test_xdma.c` — `GPIO_BASE/TDOT_BASE/ICAP_BASE/XADC_BASE/DDR3_BASE` + комментарии RES0/1
- [ ] `driver/emulate_test.py` — то же
- [ ] `driver/edge_cases.py` — то же
- [ ] `xdma_driver_win_src_2017/sys/driver.c` — `AXI_LITE_BASE`, BAR0/BAR2 boundary
- [ ] `xdma_driver_win_src_2017/exe/test_xdma.c` — то же, что `driver/test_xdma.c`
- [ ] `xdma_driver_win_src_2017/sys/XDMA.inf` и `XDMA.inx` — `VEN_10ee&DEV_7024`
- [ ] `driver/XDMA.inx` — `VEN_10ee&DEV_7024`
- [ ] `xdma_driver_win_src_2017/DRIVER_DEVLOG.md` — таблица Address Map
