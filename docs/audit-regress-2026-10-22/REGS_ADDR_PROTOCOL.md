# Регрессионный аудит: регистры ↔ адреса ↔ протоколы ↔ совместимость (flat 32/16/DEVPROG_EN=1)

Дата: 2026-10-22 (Thu). Модель: deepseek-v4-flash.
Область: репозиторий `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3`.
Сборка: **flat** (без DFX), `build_flat.tcl` → `NUM_MAC=32`, `ADDERS=16`, `DEVPROG_EN=1`
(`scripts/build_flat.tcl:42-44`); активный BD — `scripts/xdma_ddr3_dfx_bd.tcl` + `scripts/post_bd_flat.tcl`.
Режим аудита: **read-only** (файлы + безопасное чтение регистров). Плата залипла — таймауты чтения не трактуются как находки.

Источники истины, сведённые друг с другом: `docs/ADDRESS_MAP.md`, `rtl/integration/tdot_axi4.sv`,
`scripts/xdma_ddr3_dfx_bd.tcl`, `scripts/post_bd_flat.tcl`, `scripts/build_flat.tcl`,
`pytorch_layer/xdma_driver.py`, `pytorch_layer/test_dma_win.py`, `scripts/obs_smi.py`,
`scripts/monitor_obs.py`, `xdma_driver_win_src_2017/libxdma/reg.h`,
`xdma_driver_win_src_2017/libxdma/dma_engine.{c,h}`, `xdma_driver_win_src_2017/sys/file_io.c`.

Вердикты: **OK** — согласовано; **MISMATCH** — прямое расхождение спецификации и кода; **RISK** — согласовано формально, но есть рабочий риск/неоднозначность.

---

## 1. Карта адресов PCIe / BAR

### 1.1 BAR-конфигурация XDMA IP (v4.2)

Спецификация (BD-конфиг `scripts/xdma_ddr3_dfx_bd.tcl:662-706`): XDMA **4.2**, PCIe x4 Gen2 (5.0 GT/s),
128-bit AXI, **2 H2C + 2 C2H**, MSI-X включён, `axilite_master_en=true`, `axilite_master_size=128`,
`pciebar2axibar_axil_master=0x40000000`, `pf0_bar0_size=128`, 64-bit AXI-адрес, `mode_selection=Advanced`.

| Объект | Спецификация / источник | Факт в коде | Вердикт |
|---|---|---|---|
| IP-версия XDMA | PG195 v4.0 (для v4.x); активная — **v4.2** | `create_bd_cell -vlnv xilinx.com:ip:xdma:4.2` в `xdma_ddr3_dfx_bd.tcl:99,662`; легаси `block_design_top.tcl` — v4.1 | OK (активная сборка v4.2; reg.h ссылается на pg195-pcie-dma.pdf v4.0) |
| BAR0 | 128 MB, окно AXI-Lite `0x40000000…0x47FFFFFF` | `pf0_bar0_size {128}`, `axilite_master_size {128}`, `pciebar2axibar_axil_master {0x40000000}` (`xdma_ddr3_dfx_bd.tcl:678,699-701`, `post_bd_flat.tcl:60-63`) | OK. Внутри BAR0: `0x0-0x7FFF` — конфиг-регистры XDMA, остальной диапазон — M_AXI_LITE → периферия (аудит 2026-10-01, сдвиг на 0x20000) |
| BAR2 | стр. «НЕ мост данных»; там таблица MSI-X (64-бит BAR_3:2) | `pf0_msix_cap_table_bir {BAR_3:2}`, table @0x8000/32Б, PBA @0x8FE0, size 0x1F; `pf0_msix_enabled {true}` (`xdma_ddr3_dfx_bd.tcl:683-688`) | OK (совпадает с ADDRESS_MAP.md §1/§1.2) |
| DDR3 в PCIe | нет прямого мэппинга; данные — только через DMA h2c/c2h | ADDRESS_MAP.md §1.2; `xdma_driver.py:40-50` (FIX-11 не маппит BAR2 как DDR3) | OK |
| Ветви адреса (хост) | `0x40000000≤a<0x80000000` → AXI-Lite; `a≥0x80000000` → DDR3 (DMA) | `xdma_driver.py:49-50`, `_route()` в `XdmaLinux` (`xdma_driver.py:137-150`) | OK формально, но см. 1.2 ниже (окно на самом деле 128MB, не до 0x7FFFFFFF) |

### 1.2 Трансляция user-offset → BAR-offset

`file_io.c` берёт адрес прямо из `DeviceOffset` запроса: `offset = params.Parameters.Read.DeviceOffset`
(`sys/file_io.c:314,365`), читает/пишет `(PUCHAR)bar + offset` (`file_io.c:333,383`). Хост САМ вычитает
`AXI_LITE_BASE` перед вызовом — это и делает `_xfer`/`read`/`write` во всех ctypes-бэкендах.

| Объект | Спецификация / источник | Факт в коде | Вердикт |
|---|---|---|---|
| `\control` узел → BAR0 (config) | `DEVNODE_TYPE_CONTROL` → `configBarIdx` | `file_io.c:147-150` | OK |
| `\user` узел → user BAR (BAR2) | `DEVNODE_TYPE_USER` → `userBarIdx` | `file_io.c:151-159` | OK (в DFX-сборке userBarIdx<0 — см. ниже) |
| Периферия через какой узел? | ADDRESS_MAP §1.1: `\\.\XDMA0`/FIX-1 через **BAR0 (config)** | `XdmaWinUpstream.read/write` используют `self._usr if not None else self._ctl` (`xdma_driver.py:579-586`); `XdmaWinDma` — `self._user if not None else self._ctrl` (`test_dma_win.py:194-200`) | **RISK/фактически OK**: на DFX-плате `\user` не создаётся (BAR2 — MSI-X, `userBarIdx<0`, `file_io.c:152-156`) → открытие падает → фолбэк на `\control`=BAR0. Код работает правильно, но комментарии обеих ctypes-обёрток утверждают «периферия в \user» — вводят в заблуждение. Рекомендуется чтение через `\control` (offset=addr−0x40000000) как единственный путь. |
| Трансляция DMA offset | Драйвер добавляет AXI-базу централизованно | `EngineProgramDma`: `deviceOffset += XDMA_DDR3_AXI_BASE` (`dma_engine.c`, рег. `reg.h:52-59`), диапазон-чек `endOff > XDMA_DDR3_AXI_BASE + 0x10000000` (256MB) | OK. Хост шлёт чистый DDR3-offset (0..0x0FFFFFFF); соответствие `write_dma/read_dma` во всех бэкендах |
| Окно AXI-Lite в комментариях драйвера | ADDRESS_MAP: 128MB (до `0x47FFFFFF`) | `xdma_driver.py:41` комментарий «AXI-Lite [0x4000_0000 .. 0x7FFF_FFFF]»; `test_dma_win.py:192` — проверка `addr < 0x80000000` | **MISMATCH(косметич.)**: драйвер допускает до `0x7FFFFFFF`, реально BAR0=128MB (`0x40000000…0x48000000`). Обращение в `0x48000000..0x7FFFFFFF` = несуществующий BAR-offset → `ValidateBarParams` отклонит (см. 1.3). На практике периферия на `0x4002xxxx` — не затрагивается |

### 1.3 Граничная проверка BAR (`ValidateBarParams`)

`ValidateBarParams` (`file_io.c:284-303`): `if (offset + length >= xdma->barLength[nBar]) return INVALID_DEVICE_REQUEST;`

Реализация использует строгое `>=`. Корректный доступ, касающийся последнего байта BAR
(`offset + length == barLength`), отклоняется, хотя по смыслу «внутри BAR» (addresses
`offset … offset+length-1` все `< barLength`) он валиден.

| Объект | Спецификация / источник | Факт в коде | Вердикт |
|---|---|---|---|
| Граница BBB | «доступ вне адресного диапазона BAR» (должен быть `>` для `offset+length==barLength`) | `offset + length >= barLength` (`file_io.c:297`) | **MISMATCH**: любой IRP, конец которого совпадает с концом BAR (включая чтение последнего 32-битного слова control-бар), возвращает ошибку. Для 64KB control-бара это чтение `offset=0xFFF0,len=0x10` и т.п. На текущем хосте чтения ≤4Б в начале BAR — не затрагивается, но заложен риск |

---

## 2. Регистры ядра tdot (`tdot_axi4.sv`, база `0x40023000`)

Декодер: `case (awaddr_q[7:2])` на запись (write, `tdot_axi4.sv:377-417`) и `case (araddr_q[7:2])` на чтение
(`tdot_axi4.sv:457-529`). **Индекс = байтовый_смещение >> 2** (окно 256 Б, `C_S_AXI_ADDR_WIDTH=8`).
Все 32-битные регистры, байтовый адрес = `REG_BASE + индекс*4`.

### 2.1 Полная сверка индексов (ADDRESS_MAP §3 ↔ RTL ↔ драйвер)

| Байт-смещение | Имя | RTL write idx | RTL read idx | Драйвер (оффсет) | Вердикт |
|---|---|---|---|---|---|
| 0x00 | CTRL | 6'd0 | 6'd0 | TdotCore.start → `_reg_w(0x00,1)` | OK |
| 0x04 | STATUS | — | 6'd1 | `_reg_r(0x04)` | OK |
| 0x08 | N_IN | 6'd2 | 6'd2 | `_reg_w(0x08,n)` | OK |
| 0x0C | RES0 | — | 6'd3 | `_reg_r(0x0C)` | OK |
| 0x10 | RES1 | — | 6'd4 | `_reg_r(0x10)` & 0xFFFF | OK |
| 0x14/0x18 | DATA_ADDR_LO/HI | 6'd5/6 | 6'd5/6 | `_reg_w(0x14/0x18, DDR3_BASE+off)` | OK |
| 0x1C/0x20 | WEIGHTS_ADDR_LO/HI | 6'd7/8 | 6'd7/8 | `_reg_w(0x1C/0x20)` | OK |
| 0x24/0x28 | RESULT_ADDR_LO/HI | 6'd9/10 | 6'd9/10 | `_reg_w(0x24/0x28)` | OK |
| 0x2C/0x30 | CORE_RES0/1 | — | 6'd11/12 | `read_core_result_reg` (`_reg_r(0x2C/0x30)`) | OK |
| 0x40 | SCHED_CTRL | 6'd16 | 6'd16 | `SCHED_CTRL=0x40` | OK |
| 0x44 | SCHED_WPTR | 6'd17 | 6'd17 | `SCHED_WPTR=0x44` (RING-1024: [9:0]) | OK |
| 0x48 | SCHED_RPTR | — | 6'd18 | `SCHED_RPTR=0x48` | OK |
| 0x4C/0x50 | DESC_BASE_LO/HI | 6'd19/20 | 6'd19/20 | `SCHED_DESC_LO=0x4C/HI=0x50` | OK |
| 0x54/0x58 | COMP_BASE_LO/HI | 6'd21/22 | 6'd21/22 | `SCHED_COMP_LO=0x54/HI=0x58` | OK |
| 0x5C | SCHED_STATUS | — | 6'd23 | `SCHED_STATUS=0x5C`; биты busy=0/irq_pending=1 | OK |
| 0x60 | DONE_CNT | — | 6'd24 | `SCHED_DONE_CNT=0x60` | OK |
| 0x64 | CORE_PARAMS | — | 6'd25 | `_reg_r(0x64)`; `[7:0]=NUM_MAC,[15:8]=ADDERS` | OK |
| 0x68 | MAGIC | — | 6'd26 | `0x54444F54`; `probe_firmware`/`monitor_obs` читают `0x68` | OK |
| 0x6C | OBS_CTRL | 6'd27 | 6'd27 | `OBS_CTRL=0x6C`; CLEAR b0/FREEZE b1 | OK |
| 0x70 | BUILD_ID | — | 6'd28 | `OBS_BUILD_ID=0x70` | OK |
| 0x74 | CAPS | — | 6'd29 | `OBS_CAPS=0x74`; поля NUM_MAC/ADDERS/L2BURST/sched/regmap | OK (см. 2.2) |
| 0x78..0xA8 | OBS-счётчики | — | 6'd30..40 | `OBS_CYCLES_LO=0x78`…`OBS_FIFO_FULL=0xA8` | OK (последовательно +0x4) |
| 0xAC | SNAP | 6'd43 | 6'd43 | `OBS_SNAP=0xAC`, W-любое | OK |
| 0xB0..0xE0 | S-тени | — | 6'd44..56 | `OBS_SHADOW_BASE=0xB0` + 4*i (13 слов) | OK |
| 0xE4 | DP_CTRL | 6'd57 | 6'd57 | `DeviceProgRunner.DP_CTRL=0xE4`; `obs_smi.rr(0xE4)` | OK |
| 0xE8/0xEC/0xF0 | DP_DATA/TABLE/MBOX_BASE | 6'd58/59/60 | 6'd58/59/60 | `DP_DATA_BASE=0xE8/TABLE_BASE=0xEC/MBOX_BASE=0xF0` | OK |
| 0xF4 | DP_STAT | — | 6'd61 | нет в драйвере (RO) | OK (не используется хостом) |
| 0xF8 | RD_TIMEOUT_EVENTS | — | 6'd62 | `obs_smi.rr(0xF8)` | OK |
| 0xFC | WR_TIMEOUT_EVENTS | — | 6'd63 | `obs_smi.rr(0xFC)` | OK |

**Вывод §2.1**: вся базовая и планировочная карта, OBS, CORE_PARAMS/MAGIC совпадают индекс-в-индекс.

### 2.2 CAPS-биты (0x74)

`6'd29: rdata = {8'(OBS_REGMAP_V), 7'b0, 1'b1, CAPS_L2BURST, CAPS_ADDERS, CAPS_NUMMAC}` (`tdot_axi4.sv:490-491`)
= `[31:24]=regmap(1)`, `[23:17]=0`, `[16]=sched(1)`, `[15:12]=L2BURST(=clog2(32)=5)`, `[11:8]=adders`,
`[7:0]=num_mac`. `read_caps()` (`xdma_driver.py:779-788`) читает те же сдвиги. ОСЯ. OK.

### 2.3 Ловушки «word vs byte offset» (новые RO 0x62/0x63)

Внимание — **двойственная нумерация**. Декодер работает по `idx = addr[7:2]`, поэтому:

- Регистры слов 57..63 физически живут на байтовых смещениях `0xE4,0xE8,0xEC,0xF0,0xF4,0xF8,0xFC`.
- Если обратиться к «естественным» последовательным байтам `0x62`/`0x63` (слово 24/25), декодер вернёт
  `6'd24`/`6'd25` = **DONE_CNT** / CORE_PARAMS — т.е. `0x62` алиасится на DONE_CNT (0x60>>2==24).

| Объект | Спецификация | Факт | Вердикт |
|---|---|---|---|
| 0x62 (байт) | — | `idx=24` → DONE_CNT | RISK (ловушка): кто-то, используя `0x62/0x63` как байты, получит DONE_CNT/CORE_PARAMS, а не RD/WR_TIMEOUT |
| 0xF8/0xFC (байт) | RD_TIMEOUT_EVENTS / WR_TIMEOUT_EVENTS | `obs_smi.py:277-284` читает именно `0xF8/0xFC` — ПРАВИЛЬНО | OK (obs_smi корректно обошёл ловушку) |
| DP_STAT (байт 0xF4) | RO: `{8'd0, dp_fifo_level, dp_stall_code, dp_wdog_active, complete, active}` | `tdot_axi4.sv:526-527` | OK |

Дополнительно: `ADDRESS_MAP.md §3` **не документирует** регистры 0xE4..0xFC (DP-режим, DP_STAT,
RD/WR_TIMEOUT). Карта заканчивается на `0xB0..0xE0` (S-тени). Это документационный пробел.

### 2.4 Счётчики таймаутов и сторожевые (2016-10-21/22, regressions)

| Объект | Факт в коде | Вердикт |
|---|---|---|
| `rd_to_cnt`/`wr_to_cnt` в ветке срабатывания | СТЕКУЩИЙ код ясно сбрасывает счётчик: `rd_to_cnt <= 0` в fire-ветке (`tdot_axi4.sv:658`), аналогично `wr_to_cnt <= 0` (`tdot_axi4.sv:745`). Регистры `rd_issued=0; rd_recv=0; r_ready_r=1` на новом `rd_start` (`tdot_axi4.sv:620-622`) | OK (прежний дефект «не обнуляется → AR мёртв до reset» в текущем RTL ИСПРАВЛЕН; раньше в линте-ветке) |
| `DP_WDOG_MAX=1<<22` не влезает в 20 бит | ТЕКУЩИЙ `logic [21:0] dp_wdog_cnt; // FIX 2026-10-22: 1<<22 needs 22 bits` (`tdot_axi4.sv:811`) | OK (исправлено, 22 бита) |
| RD/WR_TIMEOUT_LIMIT=1<<19 на `[19:0]` | `logic [19:0] rd_to_cnt, wr_to_cnt` (`tdot_axi4.sv:250`); `1<<19=524288` умещается в 20 бит | OK |
| Rx-данные после abort | timeout-ветка RTL «retire» задачи: снимает `busy`, ставит `done`, двигает `sched_rptr`, НО **completion-запись опускается** (комментарий `tdot_axi4.sv:985-987`) | **RISK**: при аппаратном таймауте планировщика `RPTR` продвинется без записи completion → хост `collect()` прочитает мусор/старое значение слота, а `dot_batch()` корректно упадёт по `status!=0`, но результат всё равно потерян. Это прямо про «abort/retiry задачи» из задания — механизм есть, но НЕ возвращает статус таймаута в completion |

---

## 3. Регистры XDMA IP (по `reg.h`)

| Смещение | Блок | Факт (reg.h) | PG195 / совместимость | Вердикт |
|---|---|---|---|---|
| 0x0 / 0x1000 (каналы H2C/C2H) | `XDMA_ENGINE_REGS` (control 0x00, controlW1S 0x08, status 0x40, statusRC 0x44, completedDescCount 0x48, pollModeWb 0x80/0x84, intEnableMask 0x88, perf 0xA0..0xB4) | PG195: layout идентичен для H2C (base=движковый offset) и C2H (+0x1000) | OK |
| 0x0 / 0x1000 | idle: рег. канал — базовый индекс двигателя | `engine->regs = configBarAddr + offset + chan*0x1000` | PG195 | OK |
| 0x2000 | IRQ block | `XDMA_IRQ_REGS` (userIntEnable 0x04, userIntRequest 0x28, userIntPending 0x30, userVector[4] 0x40) | PG195: IRQ_BLOCK_OFFSET=0x2000 | OK |
| 0x3000 | Config block | `XDMA_CONFIG_REGS` (busDev 0x04, pcieMPS 0x08, pcieMRRS 0x0C, msiEnable 0x14, pcieWidth 0x18, pcieControl 0x1C, userMPS 0x40, userMRRS 0x44, writeFlushTimeout 0x60) | PG195: CONFIG_BLOCK_OFFSET=0x3000 | OK |
| 0x4000/0x5000 | SGDMA H2C/C2H | `XDMA_SGDMA_REGS` (firstDescLo 0x80, firstDescHi 0x84, firstDescAdj 0x88, descCredits 0x8C) | PG195: SGDMA_BLOCK_OFFSET=0x4000, +0x1000 для C2H | OK |
| 0x6000 | SGDMA common | `XDMA_SGDMA_COMMON_REGS` (control 0x10, controlW1S 0x14, controlW1C 0x18, creditModeEnable 0x20) | PG195 | OK |
| XDMA_CTRL_RST (control bit31) | канал reset | `XDMA_CTRL_RST (BIT_N(31))`, `XDMA_EngineResetChannel` пишет `controlW1S = XDMA_CTRL_RST` | PG195 для MM-канала control: bit31 не описан как аппаратный reset | **RISK**: по результатам теста 1.2.7.6 bit31 на этом битстриме — no-op/reserved (аппаратный wedge не снимается; маленькая запись после reset снова timeout). Драйвер `channelResetOnTimeout` по умолчанию TRUE (`dma_engine.h:213`), но на железе не спасает — реальная митигация только power-cycle (совпадает с памятью проекта) |
| `XDMA_CTRL_NON_INCR_ADDR` (bit25) | адресный режим | использует в `IoctlSetAddrMode`/ADDRMODE_GET | PG195: bit25 non-increment | OK |
| `XDMA_CTRL_POLL_MODE` (bit26) | poll | `engine->poll` | PG195 | OK |
| `XDMA_ENGINE_REGS.status` (0x40) = «6'h10,2'b0» | status | комментарий `reg.h:126` | PG195: status base 0x40 | OK |

---

## 4. Протоколы передачи

### 4.1 SGDMA-дескриптор (32 Б, LE)

`struct xdma_descriptor_t { UINT32 control; UINT32 numBytes; UINT32 srcAddrLo; srcAddrHi;
dstAddrLo; dstAddrHi; nextLo; nextHi; }` (`dma_engine.h:233-244`) — ровно 8×UINT32 = 32 Б, порядок
полей matches PG195 legacy descriptor.

| Поле | Драйвер | PG195/спека | Вердикт |
|---|---|---|---|
| control magic | `XDMA_DESC_MAGIC=0xAD4B0000` (`dma_engine.c`) | magic=0xAD в [31:24] | OK |
| control nextAdj | `nextAdj<<8`, `firstDescAdj` с учётом MRRS и 4KB (`OptimizeDescriptors`, `dma_engine.c`) | [15:8]=nextAdj | OK |
| control STOP/COMPLETED | последний дескриптор: `control |= STOP|COMPLETED` | bit0=Stop, bit1=Complete | OK |
| control EOP | только для ST (`EngineType_ST`) | bit4=EOP | OK (в MM не ставится — верно) |
| numBytes | `XDMA_DESC_MAX_BYTES=8192` срез (`dma_engine.h:38`), FIX-ROF | длина в байтах | OK (см. 5.2 про консистентность) |
| src/dst | H2C: src=host, dst=card(+AXI_BASE); C2H: наоборот | PG195 | OK |
| next | bus-адрес следующего дескриптора, последний = 0 | PG195 | OK |
| nextAdj на последнем | очищается `desc[k2].control &= ~(0xFF<<8)` (после robot-среза) | последний должен nextAdj=0 | OK |

### 4.2 Completion (что «готово») и IRQ

- Драйвер читает `engine->regs->completedDescCount` (0x48) и `statusRC` (0x44, read-clear снимает BUSY)
  для определения готовности (`dma_engine.c`, `XDMA_EngineWaitCompletion`). Критерий «готово» = `hwDone &&
  cdc>=numDescriptors` (`file_io.c:798`).
- IRQ: перенос завершается только последним пакетом (`WdfDmaTransactionDmaCompleted==TRUE`); на промежуточных
  пакетах `isReqPending=TRUE` и ждётся следующий (`file_io.c:801-837`, BUG-060/D-2). Исправление избавляет от
  «IRP остался незавершённым» по multi-packet.
- MSI-X: IRQ движка → `usr_irq_req[0]` (`post_bd_flat.tcl:181`, `tdot_irq`). TDOT-планировщик: `sched_irq`
  (уровень, держится до irq_ack) → 2-FF `tdot_irq_sync` в `xdma_ddr3_core_top.sv:109-112` → `usr_irq_req`.
  Linux: `events_0` (`xdma_driver.py:1078-1094`).
- кредиты: `creditModeEnableW1S = BIT_N(channel)<<16` на открытии (`dma_engine.c`) — включены, потом не трогаются.

### 4.3 AXI4 / 4KB-кламп / burst tdot

- tdot: `M_AXI_ARLEN` клампится к 4KB-границе (`bnd_bytes_w/bnd_words_w`, `tdot_axi4.sv:1352-1366`, A4.3.1
  из ADDRESS_MAP §3.4). `BURST_RD_LEN=32` (256Б/AR), `BURST_WR_LEN=8` (пишет 1 слово).
- `M_AXI_ARSIZE=3` (8Б/beat, 64-bit data), `ARBURST=INCR`, `ARCACHE=0b0011` (non-bufferable modifiable).
- Хост смещение ≥4 байта (дескрипторная адресация), `write_dma/read_dma` добор до чётного 4Б.
- CDC 125 МГц (XDMA axi_aclk=125 МГц, tdot M_AXI и M_AXI_LITE оба @125МГц `FREQ_HZ 125000000`
  `post_bd_flat.tcl:134,229`, `xdma_ddr3_dfx_bd.tcl:930,943`) → SmartConnect → MIG. МИГ user-интерфейс
  (частота ui_clk) не закреплена в прочитанном BD; `rst_mig_7series_0_100M` — только имя резет-модуля
  (`xdma_ddr3_dfx_bd.tcl:653`). **Точное значение ui_clk и способ CDC между 125МГц tdot и MIG надо
  подтверждать по сгенерированному `mig.prj`** (в проде: write через `mig_7series` wiz).

### 4.4 Планировщик tdot (кольцо 1024)

- RTL: кольцо mod 1024, 10-битные `sched_wptr_q/sched_rptr_q` (`tdot_axi4.sv:263-264`); таблица дескрипторов
  32КБ, completion 16КБ (RING-1024 2026-10-20).
- Драйвер: `SCHED_RING_DEPTH=256`, `self.mask = ring_depth - 1 = 0xFF` (`xdma_driver.py:923,956`),
  проверка `len(jobs) >= self.depth` (`xdma_driver.py:1008`), `submit` пишет `start = wptr % depth`.

| Объект | Спецификация | Факт в коде | Вердикт |
|---|---|---|---|
| Ёмкость кольца | RTL — 1024; ADDRESS_MAP §3.1 — mod 1024 | Драйвер по умолчанию `depth=256` (маска 0xFF); `wait/collect` тоже маск 0xFF | **RISK/MISMATCH(конфигурац.)**: хост ограничивает кольцо 256, хотя RTL умеет 1024. При ручном `TdotScheduler(ring_depth=1024)` маска была бы 0x3FF — ок, но дефолтный путь работает на 256, а карта `obs_smi` считает occupancy на 1024 (`occ&0x3FF`). Некритично для функциональности, но теряет половину глубины конвейера планировщика |
| flush | RTL: `sched_rptr_q <= 0` в CS_IDLE по flush | драйвер: сброс в init (`xdma_driver.py:966-973`) | OK |
| IRQ при опустошении | `irq_pending` когда rptr+1==wptr | RTL `tdot_axi4.sv:1225-1227`; хост читает events / поллит | OK |

---

## 5. Совместимость (версия IP vs драйвер, WDF/KMDF)

| Объект | Спецификация | Факт | Вердикт |
|---|---|---|---|
| Версия драйвера | WDF/KMDF | INF/проект — 2017 upstream; отдельные фиксы 1.x | — |
| «single WDF packet» (BUG-053/E-19) | ≤ 1 packet на request | `WdfDmaTransactionSetMaximumLength(..., XDMA_MAX_TRANSFER_SIZE=8MB)` (`file_io.c:776,928`); мотивация — движок не рестартует между пакетами | OK (известное ограничение, в памяти проекта E-19/BUG-053) |
| XDMA_MAX_TRANSFER_SIZE vs DMA_CHUNK | 8MB макс. пакет | `xdma_driver.py:444` `XdmaWinUpstream.DMA_CHUNK=1MiB`; `test_dma_win.py:89` `=1MiB` (по умолч. seq), `XDMA_MAX_TRANSFER=8MiB` opt-in | OK (но см. ниже расхождение) |
| XDMA_MAX_TRANSFER_SIZE vs `test_dma_win.DMA_CHUNK` | память проекта: «DMA_CHUNK raised 1MiB→8MiB (=XDMA_MAX_TRANSFER_SIZE)» для XdmaWinDma | `test_dma_win.py:89` комментарий — «BUG-071... DMA_CHUNK=1<<20 1MiB default»; реальный код `DMA_CHUNK = 1 << 20` (1MiB), а `XDMA_MAX_TRANSFER = 8<<20` отдельно; в `xdma_driver.py:444` тоже `1MiB` | **MISMATCH с памятью проекта**: зафиксировано «8MiB», в коде 1MiB. Это НЕ баг (1MiB < 8MiB безопаснее, меньше шанс 0x124), но память устарела: фактический дефолт 1MiB, 8MiB только opt-in через `XDMA_MAX_TRANSFER` |
| MDL/SG лимиты | 8MB при 4КБ-страницах = 2048 SG = `XDMA_MAX_DESC_COUNT=2048` | `dma_engine.h:47` `XDMA_MAX_DESC_COUNT = 8MB/4096`; банк = `XDMA_MAX_DESC_COUNT * 32 + 32 = 65568 Б` (2049 слотов) (`dma_engine.c`); `XDMA_DESC_MAX_BYTES=8192` срез | OK (банк покрывает худший случай фрагментации 2048 слотов) |
| ROF/0x124 (root port 8086:7f3c) | риск Receiver-Overflow при больших переносах | FIX-ROF 2026-10-05: срез 8192Б/дескриптор + nextAdj=0 («disable prefetch») (`dma_engine.c`); риск для 8MiB дефолта оставлен (примечание `file_io.c:774-776`) | OK (митигировано срезом); 1MiB-чанк на хосте дополнительно снижает риск |
| `BURST_RD_LEN` в RTL (32) vs дескрипторные лимиты | — | RTL читает из DDR3 по 32 слова (256Б) — не конфликтует с 8192Б-дескрипторами XDMA (это независимые тракты: DDR3 хост-каналы vs AXI-мастер ядра) | OK |

---

## 6. Точки расхождения, актуальные именно после обновлений (с приоритетом)

Приоритет 1 — наиболее вероятно влияют на наблюдаемое поведение (wedged h2c, abort/retiry, новые 0x62/0x63):

| Приоритет | Точка расхождения | Факт | Способ проверки (read-only) |
|---|---|---|---|
| **1** | **RTL timeout-ветка «retire» задачи ДРОПАЕТ completion** (`tdot_axi4.sv:984-994`). `RPTR` продвигается, `done_cnt` растёт, но completion-слот не пишется → хост `collect()` вернёт мусор, и время «потери» не диагностируется через штатный канал | Механизм есть, но не пишет статус таймаута в completion W1 | Прочитать `DP_STAT` (0xF4), `RD_TIMEOUT_EVENTS`/`WR_TIMEOUT_EVENTS` (0xF8/0xFC) в `obs_smi`/ручкой: если rd/wr>0 — задача была abort. Сопоставить с `DONE_CNT` — рост при отсутствии валидных completion |
| **2** | `SCHED_RING_DEPTH` (драйвер) = 256 при RTL 1024; occ-счётчик `obs_smi` на 1024 | При больших батчах хост видит «кольцо переполнено» раньше, чем может движок; рассогласование глубины между драйвером и картой | `SCHED_WPTR/RPTR` (0x44/0x48): сравнить старшие биты (для 256 vs 1024). Read-only логика (`mask=0xFF` vs 0x3FF) |
| 3 | BIT31 channel-reset — no-op/reserved на битстриме | `XDMA_EngineResetChannel` пишет BIT31; тест 1.2.7.6 — не снимает wedge | Read-only: `completedDescCount` (0x48) до/после IOCTL_CHANNEL_RESET — при живом контролле увидим, реальный motion только power-cycle (уже отмечено в памяти) |
| 4 | `ValidateBarParams` `>=` грань BAR | последний регистр/байт BAR нечитаем | Read-only: прочитать последнее слово control-бара (offset=barLength-4). Для периферии — `0x40023000+0xFC` (WR_TIMEOUT) и `0x40023000+0xFE` (если окно позволяет) |
| 5 | Документация: ADDRESS_MAP §3 не содержит 0xE4..0xFC; драйверные комментарии «периферия в \user»; DSP-зеркало 0x62/0x63 | — | Сверка по §2.3/2.4 выполнена; рекомендуется дописать карту |

---

## 7. Итоговая сводка (таблица «объект → источник → факт → вердикт»)

| Объект | Источник | Факт в коде | Вердикт |
|---|---|---|---|
| IP XDMA | `xdma_ddr3_dfx_bd.tcl:662` | v4.2, AXI-Lite 128MB, MSI-X BAR2, 2+2 | OK |
| BAR0/bar2/ддр3 | ADDRESS_MAP §1 | совпадает | OK |
| транслирование MA_OFFSET | file_io.c:314,333 plus XDMA_DDR3_AXI_BASE | чистый DDR-offset | OK |
| граница BAR | file_io.c:297 | `offset+length>=barLength` | **MISMATCH** |
| все рег. tdot 0x00..0xE0 | RTL vs ADDRESS_MAP vs driver | совпадают | OK |
| CAPS / MAGIC / CORE_PARAMS | — | совпадают | OK |
| RO 0xE4..0xFC (DP, timeout) | RTL 6'd57..63 | байты 0xE4..0xFC; драйвер/obs_smi корректны | OK (карта ADDRESS_MAP не дополнена) |
| ловушка 0x62/0x63 | — | алиас на DONE_CNT (0x60) | RISK (задокументировано) |
| rd/wr_to_cnt, DP_WDOG | RTL 2026-10-22 | оба исправлены | OK |
| дескриптор/SGDMA/completion | dma_engine.h:233-244 | PG195-совместим | OK |
| IRQ/MSI-X | post_bd_flat.tcl:181 | usr_irq_req[0] | OK |
| 4KB-кламп / burst | tdot_axi4.sv:1352 | OK | OK |
| DMA_CHUNK | xdma_driver.py:444, test_dma_win.py:89 | 1MiB (память говорила 8MiB) | **MISMATCH(память)** — некритично, безопаснее |
| single-WDF-packet / 0x124 | file_io.c:776; dma_engine.h:32 | 8MB cap, 8192 срез, nextAdj=0 | OK |
| RTL abort-drop completion | tdot_axi4.sv:984-994 | RPTR++ без записи completion | **RISK** (главный кандидат по симптоматике) |
| глубина кольца | RTL 1024 vs драйвер 256 | рассогласование | RISK |

---

## 8. Ограничения аудита

- Плата залипла: аппаратные таймауты чтения не трактовались как находки; единственные измеряемые «живые»
  факты взяты из памяти проекта и кода, не с железа.
- Частота `ui_clk` MIG и точные параметры CDC 125↔MIG не подтверждены по сгенерированному `mig.prj`
  (BD задаёт частоты интерфейсов, но не саму пользовательскую частоту MIG) — пункт требует отдельной
  проверки при живом железе.
- Не выполнялась запись/конфигурация: любые изменения — только после разблокировки платы и отдельного запроса.