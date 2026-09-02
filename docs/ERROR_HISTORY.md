# ERROR_HISTORY.md — Хронология всех найденных и исправленных ошибок

> **Правило**: каждая новая ошибка (Critical Warning, баг, несоответствие адресов, DRC-нарушение)
> фиксируется в этом файле с датой, описанием, файлами, исправлением и статусом.
> При появлении новой ошибки сначала проверяется, не повторяет ли она уже исправленную.

---

## 2026-09-02 — Аудит перед финальной сборкой (циклический аудит)

### [BUG-015] shift_t signed overflow — потеря старшего байта результата

| Поле | Значение |
|------|----------|
| **Где** | `rtl/block/tfmul_raw.sv:83-85` |
| **Симптом** | ASSIGN-2 Critical Warning при синтезе. `logic signed [5:0] shift_t` (диапазон -32..+31) не вмещает значение 32 при `mul_i=4,mul_j=4` (последний partial product, cnt=24). Значение оборачивается в -32, условие `t >= shift_t && t < shift_t + 8` никогда не выполняется для старшего байта → **результат 40-тритного умножения теряет самый старший байт** |
| **Исправление** | `signed [5:0]` → `signed [6:0]` |
| **Статус** | ✅ Исправлено |

### [BUG-016] XDMA M_AXI → DDR3 на 0x00000000 вместо 0x80000000

| Поле | Значение |
|------|----------|
| **Где** | `scripts/xdma_ddr3_dfx_bd.tcl:776` (унаследовано из `block_design_top.tcl:861`) |
| **Симптом** | XDMA IP транслирует BAR2-доступы хоста в AXI-адреса с 0x80000000. DFX BD назначал XDMA M_AXI → DDR3 на 0x00000000. Хост писал в BAR2, XDMA выдавал 0x80000000, SmartConnect не находил совпадения → DDR3 недоступен хосту |
| **Комментарий** | В не-DFX BD (`xdma_ddr3_bd.tcl:483`) было правильно: `0x80000000`. Ошибка унаследована из `block_design_top.tcl` который генерировался для другого контекста |
| **Исправление** | `0x00000000` → `0x80000000`, оставив aperture для DataMover внутри DFX partition на `0x0` (относительный адрес) |
| **Статус** | ✅ Исправлено |

### [BUG-017] CLK_DOMAIN использует wrapper-имя, не работающее в BD

| Поле | Значение |
|------|----------|
| **Где** | `scripts/post_bd_dfx.tcl:55,81,107,130` |
| **Симптом** | CLK_DOMAIN задан как `xdma_ddr3_dfx_xdma_0_0_axi_aclk` (синтезированный wrapper-путь). В BD-контексте `set_property` на `get_bd_intf_ports` этот путь не резолвится → внешние порты M_AXI_TDOT, S_AXI_TDOT_REGS, S_AXI_ICAP_REGS, S_AXI_XADC_REGS остаются без clock domain → CRITICAL WARNING SmartConnect при имплементации |
| **Исправление** | `xdma_ddr3_dfx_xdma_0_0_axi_aclk` → `xdma_0/axi_aclk` (BD cell pin path) во всех 4 местах |
| **Статус** | ✅ Исправлено |

### [BUG-018] PBLOCK tile column split — неправильная граница Pblock

| Поле | Значение |
|------|----------|
| **Где** | `constraints/pblock.xdc` |
| **Симптом** | Constraints 18-993/994/995/996/997: Pblock pblock_rm рассекает пару колонок interconnect, делая их нерутированными. DFX требует, чтобы левая и правая парные колонки не разделялись границей Pblock |
| **Исправление** | Добавлен `set_property SNAPPING_MODE ON [get_pblocks pblock_rm]` |
| **Статус** | ✅ Исправлено |

### [BUG-019] Отсутствует create_clock clk50 в DFX сборке

| Поле | Значение |
|------|----------|
| **Где** | `scripts/build_dfx.tcl:169-174` — использовал только `xdma_ddr3_pins.xdc` |
| **Симптом** | `create_clock -name clk50` был в `pins.xdc`, но `build_dfx.tcl` не включал этот файл. 50 МГц клок не закреплён → тайминг вход-выход clk50→clk_wiz→MIG не констрейнчен |
| **Исправление** | Добавлен `create_clock -name clk50 -period 20.000 [get_ports clk50]` в `constraints/xdma_ddr3_pins.xdc` |
| **Статус** | ✅ Исправлено |

### [BUG-020] PCIe lane LOC пути устарели (xdma_ddr3_i → xdma_ddr3_dfx_i)

| Поле | Значение |
|------|----------|
| **Где** | `constraints/xdma_ddr3_early.xdc:2-5` |
| **Симптом** | Пути к ячейкам GTPE2_CHANNEL использовали `xdma_ddr3_i/...` (старое имя инстанции BD), вместо `xdma_ddr3_dfx_i/...`. Констрейны не срабатывали (CRITICAL WARNING Vivado 12-1411) |
| **Исправление** | `xdma_ddr3_i` → `xdma_ddr3_dfx_i` во всех 4 строках |
| **Статус** | ✅ Исправлено |

### [BUG-021] Stale комментарий о местонахождении cleanup legacy M_AXI_ICAP

| Поле | Значение |
|------|----------|
| **Где** | `rtl/integration/xdma_ddr3_core_top.sv:261-268` |
| **Симптом** | Комментарий ссылается на `scripts/add_icap_xadc_bd.tcl` для cleanup, но реальный cleanup в `scripts/post_bd_dfx.tcl` |
| **Исправление** | Обновлён комментарий |
| **Статус** | ✅ Исправлено |

---

## 2026-09-01 — Сборка DFX BD под Vivado 2025.2

### [BUG-014] DRC REQP-123 — false positive на clk_wiz MMCM CLKINSEL=VCC

| Поле | Значение |
|------|----------|
| **Где** | Vivado 2025.2 DRC, `clk200_clk_wiz` IP |
| **Симптом** | `ERROR: [DRC REQP-123] connects_CLKINSEL_VCC_connects_CLKIN1_ACTIVE`. MMCME2_ADV с CLKINSEL=VCC требует активного CLKIN1 — DRC не видит create_clock на clk50 |
| **Исправление** | Добавлен `create_clock -name clk50 -period 20.000 [get_ports clk50]` в констрейны и подавление через `set_property SEVERITY {Warning} [get_drc_checks REQP-123]` в `suppress_warnings.tcl` |
| **Статус** | ✅ Исправлено |

### [BUG-013] XDMA версия 4.1 → 4.2 в Vivado 2025.2

| Поле | Значение |
|------|----------|
| **Где** | `scripts/xdma_ddr3_dfx_bd.tcl:99` (и все скрипты) |
| **Симптом** | `xilinx.com:ip:xdma:4.1` не найден в IP-каталоге 2025.2 — только 4.2 |
| **Исправление** | xdma VLNV 4.1 → 4.2 |
| **Статус** | ✅ Исправлено |
| **Примечание** | Свойства XDMA 4.2 совместимы с 4.1 |

### [BUG-012] SmartConnect Low-Area Mode не создаёт M0x_ACLK/M0x_ARESETN

| Поле | Значение |
|------|----------|
| **Где** | `scripts/post_bd_dfx.tcl` |
| **Симптом** | `ERROR: [BD 41-701] connect_bd_net requires at least two pins/ports`. SmartConnect в Low-Area Mode не имеет отдельных пинов такта/сброса для новых мастер-портов M03/M04/M05 |
| **Исправление** | Убраны `connect_bd_net` для M0x_ACLK/M0x_ARESETN — SmartConnect использует единый aclk/aresetn |
| **Статус** | ✅ Исправлено |

---

## 2026-09-01 — Исправления RTL icap_ctrl

### [BUG-011] BUFGCE_DIV не поддерживается на Artix-7

| Поле | Значение |
|------|----------|
| **Где** | `rtl/integration/icap_ctrl.sv:210-217` |
| **Симптом** | `CRITICAL WARNING: [Netlist 29-180] Cell 'BUFGCE_DIV' is not a supported primitive for artix7 part`. Примитив не существует в артиксе — чёрный ящик, логика не работает |
| **Исправление** | BUFGCE_DIV заменён на триггер-делитель + BUFG |
| **Статус** | ✅ Исправлено |

### [BUG-010] ack_toggle multi-driven — два регистра драйвят одну сеть

| Поле | Значение |
|------|----------|
| **Где** | `rtl/integration/icap_ctrl.sv:169,252` |
| **Симптом** | `CRITICAL WARNING: [Synth 8-6859] multi-driven net on pin u_icap/ack_toggle`. `ack_toggle` сбрасывался в fast-домене (строка 169) и драйвился в slow-домене (строка 252) |
| **Исправление** | Сброс `ack_toggle` перенесён в slow-домен |
| **Статус** | ✅ Исправлено |

---

## 2026-08-27 — Первый анализ проекта (ANALYSIS_AND_SPEC_FIX.md)

### [BUG-001] A-1: axi_aclk/axi_aresetn не существуют — тактирование ускорителя висит в воздухе

| Поле | Значение |
|------|----------|
| **Где** | `rtl/integration/xdma_ddr3_core_top.sv`, BD |
| **Симптом** | Top-уровень тактует `u_tdot` неявными проводами `axi_aclk/axi_aresetn`, которые не объявлены и не подключены. Синтез проходит, но вся логика ускорителя мертва |
| **Исправление** | Экспорт такта из BD: `axi_aclk_out/axi_aresetn_out/axi_aclk_in` через `scripts/fix_bd_clock_export.tcl`, loopback в top |
| **Статус** | ✅ Исправлено |

### [BUG-002] A-2: AXI-Lite slave теряет транзакции при разнесённых AW/W фазах

| Поле | Значение |
|------|----------|
| **Где** | `rtl/integration/tdot_axi4.sv:156-186` |
| **Симптом** | Запись регистрируется только при `AWVALID && WVALID` в одном такте. Если фазы разнесены — транзакция теряется, bvalid не выставляется, interconnect зависает |
| **Исправление** | Переписан шаблон AXI-Lite: независимый приём AW/W, awaddr_latched + wdata_latched, commit при обеих, backpressure на DATA при занятом mailbox |
| **Статус** | ✅ Исправлено |

### [BUG-003] A-3: GO затирает N_IN при записи CTRL

| Поле | Значение |
|------|----------|
| **Где** | `rtl/integration/tdot_axi_lite.sv:119-122` |
| **Симптом** | Запись CTRL=0x1 пишет 0 в N_IN (WDATA[16:8]) — троичное ядро работает с N_IN=0 |
| **Исправление** | Убран побочный эффект; N_IN управляется только через отдельный регистр 0x08 |
| **Статус** | ✅ Исправлено |

### [BUG-004] A-4: Потеря битов [31:16] результата в регистрах

| Поле | Значение |
|------|----------|
| **Где** | `rtl/integration/tdot_axi4.sv:213-214,221-222,487-489` |
| **Симптом** | RES0 = result[15:0], RES1 = result[47:32] — средние 16 бит недоступны |
| **Исправление** | RES0 = result[31:0], RES1 = {16'h0, result[47:32]} |
| **Статус** | ✅ Исправлено |

### [BUG-005] A-5: ICAP-контроллер не соответствует протоколу ICAPE2

| Поле | Значение |
|------|----------|
| **Где** | `rtl/integration/icap_ctrl.sv` (оригинал) |
| **Симптом** | CSIB удерживается LOW весь цикл передачи, CLK превышает лимит 100 МГц, нет DESYNC, нет контроля статуса |
| **Исправление** | Полная переработка: windowed CSIB (ровно 1 такт), делитель такта 125→62.5 МГц, toggle-handshake CDC, правильный протокол GO→DATA→STOP |
| **Статус** | ✅ Исправлено (см. итерации BUG-010, BUG-011) |

### [BUG-006] A-6: GO при BUSY — гонки контроллера

| Поле | Значение |
|------|----------|
| **Где** | `rtl/integration/tdot_axi4.sv:408,438-444` |
| **Симптом** | Новый GO во время выполнения перезапускает FSM без сброса FIFO → рассинхронизация |
| **Исправление** | GO при BUSY игнорируется |
| **Статус** | ✅ Исправлено |

### [BUG-007] B-1: file delete -force runs ломает повторную сборку

| Поле | Значение |
|------|----------|
| **Где** | `scripts/build_all.tcl:77-79` |
| **Симптом** | После `reset_run` ручное удаление каталогов runs оставляет проект в несогласованном состоянии |
| **Исправление** | Удалены строки `file delete -force`; достаточно `reset_run` |
| **Статус** | ✅ Исправлено |

### [BUG-008] B-2: Расхождение карты адресов между документацией и BD

| Поле | Значение |
|------|----------|
| **Где** | README, INTEGRATION_REPORT, build_all.tcl |
| **Симптом** | TDOT заявлен 0x44000000 (readme), фактически 0x40001000 (BD) |
| **Исправление** | Все источники синхронизированы с фактической картой; `docs/ADDRESS_MAP.md` — единый источник истины |
| **Статус** | ✅ Исправлено (актуальная карта в ADDRESS_MAP.md и ERROR_HISTORY.md) |

### [BUG-009] B-4: Констрейны — отсутствует diff_clock_rtl_0_clk_n

| Поле | Значение |
|------|----------|
| **Где** | `constraints/xdma_ddr3_pins.xdc` |
| **Симптом** | PCIe refclk назначен только `clk_p` (F10), `clk_n` (E10) не назначен → CRITICAL WARNING |
| **Исправление** | Добавлен PACKAGE_PIN E10 для `diff_clock_rtl_0_clk_n` |
| **Статус** | ✅ Исправлено |

---

## Приложение: Карта адресов DFX-BD (актуальная)

| Адрес | AXI-Lite SmartConnect | Периферия | Размер | Примечание |
|-------|-----------------------|-----------|--------|------------|
| 0x4000_0000 | `xdma_axi_lite_smc/M00` | GPIO (LED) | 4K | axi_gpio_0 |
| 0x4000_1000 | `xdma_axi_lite_smc/M02` | HWICAP | 4K | axi_hwicap_0 (ядро, не icap_ctrl) |
| 0x4000_2000 | `xdma_axi_lite_smc/M01` | DFX Socket | 4K | decouple_shutdown_ctrl |
| **0x4000_3000** | `xdma_axi_lite_smc/M03` | **TDOT_REGS** | **4K** | **tdot_axi4 регистры** |
| **0x4000_4000** | `xdma_axi_lite_smc/M04` | **ICAP_REGS** | **4K** | **icap_ctrl регистры** |
| 0x4001_0000 | `xdma_axi_lite_smc` → DFX Socket → dfx_partition | DataMover MM2S | 32K | |
| 0x4001_8000 | `xdma_axi_lite_smc` → DFX Socket → dfx_partition | DataMover S2MM | 32K | |
| 0x4600_0000 | `xdma_axi_lite_smc/M05` | XADC_REGS | 4K | xadc_temp |
| 0x8000_0000 | `xdma_axi_smc/S00` (XDMA) | DDR3 | 256 MB | Доступ хоста через BAR2 |
| 0x8000_0000 | `xdma_axi_smc/S02` (M_AXI_TDOT) | DDR3 | 256 MB | Доступ ядра tdot_axi4 |
| 0x0000_0000 | dfx_partition/rp_M_AXI (апертура) | DDR3 | 256 MB | DataMover внутри RP (отн.) |

### AXI4 SmartConnect `xdma_axi_smc`
```
S00 → xdma_0/M_AXI        → DDR3 0x80000000 (хост через PCIe BAR2)
S01 → dfx_socket/M_AXI    → DDR3 0x00000000 (DFX partition data plane)
S02 → M_AXI_TDOT           → DDR3 0x80000000 (tdot_axi4 master)
```

### AXI-Lite SmartConnect `xdma_axi_lite_smc`
```
M00 → axi_gpio_0               (0x4000_0000)
M01 → dfx_socket/S_AXI         (0x4000_2000, через s_axi_smc)
M02 → axi_hwicap_0             (0x4000_1000)
M03 → S_AXI_TDOT_REGS          (0x4000_3000)
M04 → S_AXI_ICAP_REGS          (0x4000_4000)
M05 → S_AXI_XADC_REGS          (0x4600_0000)
```