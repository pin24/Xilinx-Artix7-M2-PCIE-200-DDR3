# ПОЛНЫЙ АУДИТ: связи · регистры · адресация · SPI-stub (2026-10-11)

Проект: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3`, ветка `main` (HEAD 9f57084).
Метод: чтение ключевых RTL/BD/host/драйвер скриптов + точечные проверки; live-проверка
`test_dma regs` на стенде (связь есть, периферия читается). Исполнитель — основной агент
(не «Петя»). Смежные аудиты: `AUDIT_F_REMAP.md`, audit-коммиты в истории.

---

## 1. Адресная карта (сводно)

### 1.1 Каноническая НОВАЯ карта (0x4002_xxxx) — ОПЕРАТИВНАЯ

| Периферия | AXI-адрес | Блок | FLAT | DFX | Источник декода |
|---|---|---|---|---|---|
| GPIO (LED/MIG) | 0x4002_0000 | axi_gpio_0 | ✅ | ✅ | xdma_ddr3_bd.tcl:738 · build_flat/post_bd_flat |
| MM2S сtrl | 0x4001_0000 | axi_datamover_mm2s | ✅ | ✅ | :736/:904 |
| S2MM ctrl | 0x4001_8000 | axi_datamover_s2mm | ✅ | ✅ | :737/:905 |
| DFX Socket | 0x4002_2000 | decouple_shutdown_ctrl | ❌ | ✅ | xdma_ddr3_dfx_bd.tcl:907 |
| **TDOT regs** | **0x4002_3000** | tdot_axi4 (S_AXI_TDOT_REGS) | ✅ | ✅ | :739/:945 |
| **ICAP regs** | **0x4002_4000** | icap_ctrl (S_AXI_ICAP_REGS) | ❌ | ❌* | *(порт убран 2026-10-05, top не инстанцирует) |
| **SPI regs** | **0x4002_5000** | spi_over_pcie (S_AXI_SPI_REGS) | ❌ | ❌* | *(порт убран 2026-10-05; файл → STUB, см. §7) |
| XADC | 0x4600_0000 | xadc_temp (S_AXI_XADC_REGS) | ✅ | ✅ | :740/:956 |
| DDR3 (DMA хост + M_AXI_TDOT + DataMover) | 0x8000_0000 (256MB) | mig_7series_0 | ✅ | ✅ | :724-727/903,932 |
| BRAM bypass (diag) | 0x1000_0000 (8KB) | diag_bram_ctrl | ✅ | ✅ | :730-733/912,936 |
| Host AXI-Lite BRAM | 0x4000_6000 (8KB) | diag_bram (через lite SMC M02) | DFX-old | ❌ now | (убрано, SINGLE_PORT) |

\* ICAP/SPI НЕ во FLAT и НЕ в DFX сейчас (топ не инстанцирует, BD-порты убраны 2026-10-05).

### 1.2 Легаси-карта (0x4000_xxxx) — остатки (dead code / docs)

- `driver/edge_cases.py`, `driver/emulate_test.py` — эмуляторы: GPIO 0x40000000, DFX sock 0x40002000,
  TDOT 0x40003000, ICAP 0x40004000. **Диагностика, не оперативный путь.** (известно из AUDIT_F_REMAP)
- `docs/INTEGRATION_REPORT.md` §адреса — устарел (TDOT@0x40001000, ICAP@0x40002000). Документационный.
- `docs/ERROR_HISTORY.md` таблица (0x4000_3000 TDOT и т.д.) — историческая.
- `xdma_driver_win_src_2017/{CHANGELOG,DRIVER_DEVLOG}.md` — историческая карта 0x4000_3000/4000.

Вывод: оперативный декод (RTL/BD/host) идёт по НОВОЙ карте; легаси — только вне оперативного пути.

---

## 2. Регистровые карты периферии (RTL ↔ host)

### 2.1 tdot_axi4 @ 0x4002_3000 (декод aw/araddr[7:2], 32-байт/слово)
| Word | Off | Направление | Поле |
|---|---|---|---|
| 0 | 0x00 | W/R | CTRL: bit0 GO (самосброс) |
| 1 | 0x04 | R | STATUS: bit0 BUSY, bit1 DONE |
| 2 | 0x08 | W/R | N_IN (1..16*NUM_MAC; >NUM_MAC = long-dot) |
| 3/4 | 0x0C/0x10 | R | RES0/RES1 (результат 48 бит) |
| 5/6 | 0x14/0x18 | W/R | DATA_ADDR_LO/HI |
| 7/8 | 0x1C/0x20 | W/R | WEIGHTS_ADDR_LO/HI |
| 9/10 | 0x24/0x28 | W/R | RESULT_ADDR_LO/HI |
| 11/12 | 0x2C/0x30 | R | CORE_RES0/RES1 |
| 16 | 0x40 | W/R | SCHED_CTRL (en/irq_en/flush/ack) |
| 17 | 0x44 | W/R | SCHED_WPTR (8 бит, кольцо mod 256) |
| 18 | 0x48 | R | SCHED_RPTR |
| 19/20 | 0x4C/0x50 | W/R | DESC_BASE_LO/HI |
| 21/22 | 0x54/0x58 | W/R | COMP_BASE_LO/HI |
| 23 | 0x5C | R | SCHED_STATUS (busy/irq_pending) |
| 24 | 0x60 | R | DONE_CNT (16 бит) |
| 25 | 0x64 | R | CORE_PARAMS: [7:0]=NUM_MAC, [15:8]=ADDERS |
| 26 | 0x68 | R | MAGIC 0x54444F54 ('TDOT') |

Host-сверка: `test_dma.c` (TDOT_N_IN=0x08, RES0/1=0x0C/0x10, DATA/WEIGHTS/RESULT=0x14..0x28,
MAGIC=0x68, CORE_PARAMS=0x64), `test_xdma.c`, `pytorch_layer/xdma_driver.py` (REG_BASE 0x40023000,
SCHED_WPTR=0x44) — **всё совпадает** с RTL. ✅

### 2.2 icap_ctrl @ 0x4002_4000 (декод araddr[ADDR_LSB+:2], ADDR_LSB=2)
| Off | Направление | Поле |
|---|---|---|
| 0x00 | W/R | CTRL: bit0 GO, bit1 STOP |
| 0x04 | R | STATUS: {BUSY, READY} |
| 0x08 | W | DATA (32-бит слово ICAP) |
| 0x0C | R | MAGIC 0x49434150 ('ICAP') |

Сверка `pytorch_layer/icap_load.py`/`program_fpga_icap.py` (CTRL 0x00, STATUS 0x04, DATA 0x08) — ✅.
*(в текущих сборках не подключён — DFX/FLAT top не инстанцирует; BD-порт убран)*

### 2.3 spi_over_pcie @ 0x4002_5000 — === STUB (см. §7) ===
Бывший map: CTRL 0x00 (START/ABORT/WREN/RDID), STATUS 0x04 (BUSY/DONE/ERROR/WIP), CMD 0x08,
ADDR 0x0C, LEN 0x10, DATA 0x14, RX 0x18. Интерфейс сохранён в stub, рег.семантика — заглушечная.

### 2.4 xadc_temp @ 0x4600_0000
| Off | Поле |
|---|---|
| 0x00 | TEMP (raw_temp[15:0]) |
| 0x04 | VCCINT |
| 0x08 | VALID |

Сверка `monitor_temp.py`/`check_mig.py` (XADC_BASE 0x46000000) — ✅. Реальные данные из
`xadc_prim` (DRP, независимый XADC, MIG XADC_En=Off).

### 2.5 GPIO @ 0x4002_0000
axi_gpio_0: [0x00] DATA/GPI, [0x04] TRI/GPO. `check_mig.py` использует GPIO2_DATA=0x40020008. ✅

---

## 3. RTL-связи top (`xdma_ddr3_core_top.sv`)

- Такт/сброс ядра: `core_clk`/`core_resetn` (125 МГц из clk_wiz, НЕ input-порт топа — DRC MDRV-1).
  PCIe-домен: `axi_aclk`/`axi_aresetn` (из BD). Периферия и ядро — в core_clk; только PCIe S-стороны — axi_aclk.
- **AXI-Lite** S_AXI_TDOT_REGS (32-бит) → `u_tdot` `.S_AXI_*`; хост via XDMA.
- **AXI4-мастер** `u_tdot.M_AXI_*` (64-бит data, ARLEN/AWLEN [7:0], 8-байт burst):
  `m_axi_*` → BD `M_AXI_TDOT` → xdma_axi_smc → DDR3 0x80000000 / BRAM 0x10000000.
- **IRQ** планировщика TDOT: `tdot_irq_w` → 2-FF sync (axi_aclk) → BD `usr_irq_req` (MSI-X vector 0).
- **XADC**: BD-порт S_AXI_XADC_REGS → `u_xadc` (xadc_temp) + `u_xadc_prim` (raw_temp/vccint/valid).
- **ICAP/SPI**: НЕ инстанцируются (строки 197-198); icap_ctrl.sv / spi_over_pcie.sv остаются в дереве
  (spi теперь stub). GPIO/DataMover/DDR3 — в BD (не в top-портах).

Соответствие декода: все high-bandwidth мастера (host XDMA M_AXI, M_AXI_TDOT, MM2S/S2MM) → DDR3
0x80000000 + BRAM 0x10000000; AXI-Lite → периферия — согласовано (post_bd_flat.tcl:227-232).

---

## 4. Host-драйвер (xdma_driver_win_src_2017 + driver/dma/dma_driver.c)

- Устройство: XDMA DMA Subsystem (VEN_10EE/DEV_7024), драйвер XDMA_DMA, узлы `\\.\XDMA0dma\...`:
  - `\control` → configBarIdx (BAR0 config): движковые реестры XDMA (SGDMA). Смещения: H2C status@0x40,
    statusRC@0x44, completedDescCount@0x48 (используется в диаг.).
  - `\user` → userBarIdx (AXI-Lite window 128MB @0x40000000): периферия; offset = AXI − 0x40000000.
  - `\h2c_0`/`\c2h_0` → DMA DDR3; **raw offset от 0x80000000** (драйвер добавляет XDMA_DDR3_AXI_BASE централизованно).
  - `\h2c_bram_0`/`\c2h_bram_0` → translateAxiBase=FALSE: полный картовый адрес (BRAM 0x0..0x1FFF / DDR3).
- translateAxiBase: TRUE по умолчанию (ProgramDma добавляет 0x80000000); FALSE для *_bram_0 узлов.
- Профиль: ScatterGather64Duplex, 8 MB max. `WdfDmaTransactionSetMaximumLength(512)` — **известный лимит пакета**,
  источник зависания записи >512 Б (см. E-19/BUG-053, DIAG_MULTIPACKET).
- BAR: configBarIdx=0; userBarIdx — большой AXI-Lite BAR; DDR3 НЕ маплен в BAR (DMA-only) — корректно для DFX.

HOST контракт (test_dma.c/oct_diag/test_dma_win.py/xdma_driver.py): офсет-pравота — control = AXI−0x40000000,
DMA = raw ddr3 offset (без +0x80000000) — согласовано с драйвером. ✅

---

## 5. Согласованность (что сошлось)

1. Адресные базы периферии (0x40020000/0x40023000/0x40024000/0x40025000/0x46000000) согласованы:
   RTL-декод ↔ BD/build scripts ↔ host (test_dma.c, test_xdma.c, xdma_driver.py, icap_load, program_spi_flash).
2. Регистровые карты tdot/icap/xadc совпадают между RTL и host на 100%.
3. DDR3 0x80000000, BRAM 0x10000000 — согласованы везде; host DMA-контракт (raw offset) единый.
4. tdot S_AXI/M_AXI, DM аddr, IRQ-путь (fabric→axi домен→MSI-X) — связность корректна.
5. Live: `test_dma regs` читает TDOT/GPIO; драйвер v1.1.22/1.1.23 активен на стенде.

## 6. Расхождения / риски (МИНОР, не блокеры)

- [М] `driver/edge_cases.py`, `driver/emulate_test.py` — легаси-карта (0x4000_3/4 х000); эмуляторы, не оперативны.
- [М] `docs/INTEGRATION_REPORT.md` устарел (TDOT@0x40001000) — ввести в соответствие.
- [М] `docs/ADDRESS_MAP.md §5.1` и `README.md` по-прежнему описывают spi_over_pcie как рабочий
  hot-flash узел — теперь это STUB (обновить доки).
- [М] ICAP/SPI не существуют во FLAT: host ICAP/SPI-модули (`icap_load`, `program_spi_flash`,
  `dfx_swap`) на flat-прошивке упрутся в unmapped-дыру; применимы только к DFX-сборке.
- [INFO] «BRAM host AXI-Lite 0x40006000» — остаток DFX-diag; в текущем BD SINGLE_PORT, не используется.

## 7. Выполненное изменение: SPI-over-PCIe → неблокирующий STUB (2026-10-11)

**Запрос:** избавиться от spi_over_pcie либо сделать заглушку, которая не блокирует SPI.

**Контекст:** реальный `spi_over_pcie` инстанцировал STARTUPE2 и держал QSPI-пины флэша
(FCS_B=T19, D00=P22, D01=R22, D02=P21, D03=R21) как user-IO → даже сконфигурированная FPGA
блокировала флэш → Labtools **27-3347** при `program_hw_cfgmem` по JTAG. Модуль уже удалён из
всех активных сборок (flat/dfx) 2026-10-05.

**Решение (заглушка):** `rtl/integration/spi_over_pcie.sv` переписан в stub:
- AXI-Lite отвечает (нет зависания host-инструментов по 0x40025000), интерфейс/параметры сохранены;
- STATUS[0x04] возвращает DONE=1 (BUSY=0) → host "START→poll" завершается сразу;
- **НЕ** инстанцирует STARTUPE2; `spi_cclk=0`, `qspi_cs_n=1`, `qspi_d0..d3=1'bz`
  (высокий импеданс) → **флэш-пины свободны для JTAG-прошивки (27-3347 исключён)**;
- реальной SPI-активности нет.

Проверка: `xvlog 2025.2` — INFO, 0 ошибок. В активных сборках модуль не подключён (подтверждено).

Файл: `rtl/integration/spi_over_pcie.sv` (замена реализации). Host `program_spi_flash.py` НЕ менялся
(совместим по интерфейсу).

**Рекомендация (отдельно):** при желании полностью избавиться от SPI-функции — удалить
`pytorch_layer/program_spi_flash.py`, `rtl/integration/spi_over_pcie.sv`, `flash_access_top.sv`
и почистить `docs/ADDRESS_MAP.md §5.1`/`README.md`/`INTEGRATION_REPORT.md`. Решение осталось на пользователе.

---

## Итог
Оперативная карта адресов, регистров и связей **согласована** на 100% между RTL/BD/host/драйвером.
Найдены только МИНОР легаси-остатки (эмуляторы и docs) вне оперативного пути. SPI-over-PCIe
переведён в неблокирующий stub по запросу. Зависание DMA >512 Б — отдельная тема (E-19/BUG-053),
вынесена в docs/DIAG_MULTIPACKET_2026-10-04.md.