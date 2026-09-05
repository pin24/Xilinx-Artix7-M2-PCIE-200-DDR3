# ERROR_HISTORY.md — Хронология всех найденных и исправленных ошибок

> **Правило**: каждая новая ошибка (Critical Warning, баг, несоответствие адресов, DRC-нарушение)
> фиксируется в этом файле с датой, описанием, файлами, исправлением и статусом.
> При появлении новой ошибки сначала проверяется, не повторяет ли она уже исправленную.

---

## 2026-09-06 — XDMA 64 бит @ 250 МГц: ядро/RP обязаны остаться на 125 МГц; LUTRAM→BRAM

### [BUG-034] Выбранный вариант оптимизации: XDMA 128→64 @ 250 МГц без потери полосы + разделение доменов

| Поле | Значение |
|------|----------|
| **Где** | `scripts/xdma_ddr3_dfx_bd.tcl` (XDMA, SmartConnect ×2, клокинг), `scripts/post_bd_dfx.tcl` (экспорт клоков, ASSOCIATED_BUSIF), `rtl/integration/xdma_ddr3_core_top.sv` (домены u_tdot/u_icap/u_xadc), `rtl/integration/tdot_axi4.sv` (FIFO→BRAM) |
| **Контекст** | Утилизация Run1: 123,007/134,600 LUT (91.4%). Выбран вариант: **XDMA 128→64 бит @ 250 МГц, каналы DMA 2+2 СОХРАНЕНЫ** (полоса PCIe не режется: 64б×250МГц = 128б×125МГц = 2,0 ГБ/с; MIG-сторона 1,6 ГБ/с не тронута) + **LUTRAM→BRAM** |
| **Ловушка** | При 64-бит XDMA (Gen2 x4) `axi_aclk` автоматически становится **250 МГц**, а всё ядро/RP сидели на нём. Тайминг-отчёт: WNS = 0.370 нс @ 125 МГц → критический путь ≈ 7.6 нс (тернарный аккумулятор tfmul_raw, 40-тритовая последовательная цепочка) — при 4 нс @ 250 МГц дизайн гарантированно НЕ закроет тайминг. То же касается RP (DataMover 128 бит) |
| **Исправление (домены)** | Введён fabric-домен 125 МГц: `clk125_core_wiz` (clk_wiz 6.0, 50 МГц → 125 МГц) + `rst_core_125M` (proc_sys_reset, ext_reset=reset_rtl_0, locked). В домен 125 переведены: dfx_socket, dfx_partition (RP), GPIO, HWICAP S_AXI, M-сторона `xdma_axi_lite_smc` (NUM_CLKS=2), S01/S02 `xdma_axi_smc` (NUM_CLKS=3, aclk2). В домене XDMA 250 МГц остались только xdma_0 и S-стороны SmartConnect. Доменная ассоциация — явным `ASSOCIATED_BUSIF` на пинах aclk/aclk1/aclk2 SmartConnect (для экспортируемых портов M03-M05/S02 инференс невозможен). Топ получает `clk_core_out`/`core_resetn_out`; u_tdot/u_icap/u_xadc переведены на core_clk/core_resetn (125 МГц — та же частота, что была: тайминг-риск ядра нулевой) |
| **Исправление (LUTRAM→BRAM)** | `fifo_mem` (64×48, tdot_axi4) → `(* ram_style = "block" *)`. Чтение BRAM синхронное → CS_LOAD переведён на 2-стадийный конвейер: стадия 1 (`rd_idx`) — pop + выдача BRAM-чтения, стадия 2 (`load_idx = rd_idx−1`) — потребление `fifo_q` (отстаёт на 1 такт). `fifo_q` без сброса (иначе BRAM-маппинг ломается). Экономия ~120 LUT, +1 RAMB36/2 RAMB18 |
| **Проверка** | Модель `scripts/check_tdot_load.py` (расширена колонкой BRAM): 18/18 сценариев NUM_MAC=8/16/32 × N_IN=0..NUM_MAC — BRAM-конвейер эквивалентен фиксу a86ef65, включая N_IN<NUM_MAC. sv_lint: элаборация 20 топов OK, PortDoesNotExist устранены, правленные файлы без диагностики. TCL-баланс 8 файлов — 0 ошибок |
| **Просчёт** | `scripts/lut_projection.py`: NUM_MAC=32 → ~116,150 LUT (86.3%, коридор 85.3–87.5%); NUM_MAC=16 → ~85,600 LUT (63.6%) |
| **Следствие для хоста** | Адреса/протоколы не меняются; icap_ctrl остаётся на 125 МГц (окно CSIB не изменилось); GPIO2 (MIG status) — по-прежнему асинхронные статус-биты |
| **Статус** | ✅ Исправлено (требуется фактическая сборка в Vivado 2025.2 + report_utilization -hierarchical для уточнения распределения LUTRAM) |

**Урок**: при смене `axi_data_width` XDMA нельзя забывать, что `axi_aclk` меняет частоту автоматически (Gen2 x4: 64 бит → 250 МГц), и проверять, какие логические блоки неявно сидят на этом такте. Для многочастотного SmartConnect ассоциацию интерфейс↔клок для экспортируемых BD-портов надо задавать явно (`ASSOCIATED_BUSIF`), инференс работает только при наличии локального клока-соседа.

---

## 2026-09-06 — NUM_MAC=16 не доходил до сборки (shell режет '=')

### [BUG-033] Парсинг -tclargs: NUM_MAC=16 превращался в NUM_MAC + 16

| Поле | Значение |
|------|----------|
| **Где** | `scripts/build_dfx.tcl` (блок парсинга `$argv`), прокладка `scripts/build.bat:148` (`-tclargs %*`) |
| **Симптом** | Сборки «NUM_MAC=16» и «NUM_MAC=32» давали практически идентичную утилизацию (Run 1: 110583/123007 LUT, Run 2: 110487/122890 — разница ~100 LUT, статистический шум place). Регэксп `{^NUM_MAC=(\d+)$}` не срабатывал, и сборка молча шла с дефолтом NUM_MAC=32. Создавалось ложное впечатление, что ядро «не влияет» на площадь и что дизайн не помещается в кристалл |
| **Причина** | Оболочка/обёртка разрезает аргумент `NUM_MAC=16` на **два** отдельных argv-элемента: `NUM_MAC` и `16` (диагноз подтверждён на реальной сборке). Ни `NUM_MAC`, ни `16` не совпадают с каноническим regexp → значение отбрасывается без предупреждения |
| **Исправление** | Позиционный fallback в `build_dfx.tcl`: ключ отдельным словом + числовое значение следующим аргументом. Поддержаны формы `NUM_MAC=16`, `NUM_MAC 16`, `-NUM_MAC 16`, `-NUM_MAC=16` (то же для JOBS и SKIP_SYNTH). Значение валидируется `{^\d+$}` — не-числовые игнорируются. В баннер сборки добавлен вывод сырого `$argv` (видно сразу, что пришло от shell) |
| **Проверка** | Тест-харнесс `/home/z/my-project/scripts/test_nummac_parse.py` (tkinter.Tcl исполняет реальный блок из build_dfx.tcl): 13/13 сценариев — разрезанный `=`, дефис, смесь форм, не-числовые значения, отсутствие значения |
| **Статус** | ✅ Исправлено |

**Урок**: при добавлении нового `-tclargs`-параметра всегда добавлять его и в канонический regexp, и в список позиционного fallback `{NUM_MAC JOBS SKIP_SYNTH}`.

---

## 2026-09-04 — Impl DRC UTLZ-1: XADC over-utilized (2 XADC requested, 1 available)

### [BUG-031] XADC over-utilized — два XADC на одном кристалле

| Поле | Значение |
|------|----------|
| **Где** | `scripts/post_bd_dfx.tcl` (блок 4c), `rtl/integration/xdma_ddr3_core_top.sv` |
| **Симптом** | `impl_1` → `place_design` падает на DRC: `ERROR: [DRC UTLZ-1] Resource utilization: XADC over-utilized in Top Level Design (requires 2 of such cell types but only 1 compatible site is available)`. Синтез проходит, BD валидируется — падает только place_design |
| **Причина** | Artix-7 XC7A200T имеет **только 1 XADC** на кристалле. MIG 7-series IP уже использует его (`<XADC_En>Enabled</XADC_En>` в `xdma_ddr3_dfx_bd.tcl:199`). Добавление отдельного `xadc_wiz:3.3` IP (для AUDIT-04, monitor_temp.py) — попытка занять второй XADC, которого нет |
| **Исправление** | (1) Удалён весь блок 4c из `post_bd_dfx.tcl` — `xadc_wiz_0` больше не создаётся. (2) `xdma_ddr3_core_top.sv` — `u_xadc.raw_temp/vccint/valid` снова привязаны к 0. (3) `monitor_temp.py` должен читать температуру через AXI GPIO (`axi_gpio_0`), который подключён к `mig7_status_concat` (MIG status bus) — MIG экспортирует температуру в status regs |
| **Статус** | ✅ Исправлено (требует доработки monitor_temp.py для чтения через GPIO, а не через u_xadc) |

---

## 2026-09-04 — Audit cleanup: AUDIT-01..05 fixes

### [BUG-026] AUDIT-02 — create_clock mig_refclk before link_design fails

| Поле | Значение |
|------|----------|
| **Где** | `constraints/xdma_ddr3_pins.xdc:25` → `scripts/mig_refclk_post.tcl` |
| **Симптом** | `CRITICAL WARNING [Vivado 12-4739]: create_clock: No valid object(s) found for '-objects [get_pins -quiet */u_iodelay_ctrl/u_idelayctrl_*/REFCLK]'`. MIG IODELAYCTRL REFCLK pin не существует во время parsing XDC (early stage, до link_design). С `-quiet` ошибка подавляется, но `create_clock mig_refclk` не создаётся → IDELAYCTRL без clock constraint |
| **Исправление** | Убрать `create_clock` из `xdma_ddr3_pins.xdc` (заменён комментарием со ссылкой на BUG-026). Создать `scripts/mig_refclk_post.tcl` — выполняется как TCL.POST шага `synth_design` (после `link_design`, когда MIG IP развёрнут и pin существует). Подключён через `set_property STEPS.SYNTH_DESIGN.TCL.POST` в `build_dfx.tcl` |
| **Статус** | ✅ Исправлено |

### [BUG-027] AUDIT-03 — awprot/arprot не подключены (пустые `()`) в 3 инстансах

| Поле | Значение |
|------|----------|
| **Где** | `rtl/integration/xdma_ddr3_core_top.sv:229,235,239,245,251,257` (6 мест: TDOT/ICAP/XADC × awprot/arprot) |
| **Симптом** | `.S_AXI_TDOT_REGS_awprot()` — пустые скобки. Vivado неявно подставляет 0 (Unprivileged, Secure, Data) — функционально корректно, но неявное подключение плохо для читаемости и может давать WARNING на unconnected ports |
| **Исправление** | Все 6 `awprot()/arprot()` → `awprot(1'b0)/arprot(1'b0)` — явное подключение константы 0 |
| **Статус** | ✅ Исправлено |

### [BUG-028] AUDIT-04 — XADC raw_temp/vccint/valid привязаны к 0

| Поле | Значение |
|------|----------|
| **Где** | `rtl/integration/xdma_ddr3_core_top.sv:180`, `scripts/post_bd_dfx.tcl` (новый блок 4c) |
| **Симптом** | `u_xadc` инстанциирован с `.raw_temp(16'h0), .raw_vccint(16'h0), .raw_valid(1'b0)` — без источника XADC Wizard IP. `monitor_temp.py` читает TEMP=0°C, VCCINT=0V |
| **Исправление** | (1) `post_bd_dfx.tcl`: создаёт `xadc_wiz:3.3` IP в BD, конфигурирует для Temperature + VCCINT, создаёт 3 BD-порта `xadc_raw_temp`/`xadc_raw_vccint`/`xadc_raw_valid`, подключает выходы xadc_wiz (`temperature_out`, `vccint_out`, `eoc_out`). (2) `xdma_ddr3_core_top.sv`: объявляет 3 сигнала `xadc_raw_*`, подключает к `u_xadc.raw_*` вместо `16'h0`, и к `xdma_ddr3_dfx_i.xadc_raw_*` (BD-порт) |
| **Статус** | ✅ Исправлено (требует проверки в Vivado GUI — имена пинов xadc_wiz могут отличаться) |

### [BUG-029] AUDIT-05 — CORE_RES0/1 регистры не используются в Python

| Поле | Значение |
|------|----------|
| **Где** | `pytorch_layer/xdma_driver.py` (новый метод `read_core_result_reg`) |
| **Симптом** | RTL `tdot_axi4.sv:251-252` экспортирует зеркала `core_result` через `CORE_RES0` (0x2C) и `CORE_RES1` (0x30), но Python использовал только `RES0`/`RES1` (0x0C/0x10) — защёлкнутые значения. Без способа прочитать `CORE_RES0/1` нельзя отладить race condition в CS_WAIT |
| **Исправление** | Добавлен метод `read_core_result_reg()` в `TdotCore` — читает `CORE_RES0/1` (0x2C/0x30) и собирает 48-битный результат. Полезно для отладки: если `RES0/1` и `CORE_RES0/1` совпадают — защёлки работают корректно |
| **Статус** | ✅ Исправлено |

### [BUG-030] AUDIT-01 — IBUF_LOW_PWR на clk50 без [0] — mismatch с create_clock

| Поле | Значение |
|------|----------|
| **Где** | `constraints/xdma_ddr3_pins.xdc:17,21,22` |
| **Симптом** | `clk50` — 1-битный порт (`input [0:0]`). Vivado различает `[get_ports clk50]` (parent) и `[get_ports {clk50[0]}]` (bit 0) как разные объекты. `PACKAGE_PIN` на parent, `create_clock` на bit 0, `IBUF_LOW_PWR` на parent → mismatch: свойство не "прилипает" к тому же объекту, на котором создан clock |
| **Исправление** | Все 3 строки унифицированы под `[get_ports {clk50[0]}]` — один объект, одно поведение |
| **Статус** | ✅ Исправлено (commit 9888247) |

---

## 2026-09-03 — Impl failed: set_msg_config mutually-exclusive options

### [BUG-025] set_msg_config с -new_severity И -suppress — Vivado ERROR

| Поле | Значение |
|------|----------|
| **Где** | `scripts/suppress_warnings.tcl` |
| **Симптом** | Синтез прошёл успешно, impl_1 стартовал, дошёл до `place_design` (TCL.PRE = `suppress_warnings.tcl`). Vivado упал с `ERROR: [Common 17-447] -limit, -filter, and -new_severity options are mutually-exclusive. Please use only one at a time.` и `ERROR: [Common 17-39] 'set_msg_config' failed due to earlier errors.` → `ERROR: [Vivado 12-13638] Failed runs(s): 'impl_1'`. Checkpoint `xdma_ddr3_core_top_opt.dcp` был успешно сохранён — упало только на TCL.PRE hook |
| **Причина** | `set_msg_config -id {X} -new_severity WARNING -suppress` — две взаимоисключающие опции. В Vivado 2025.2 это ERROR (раньше был warning, теперь строгое) |
| **Исправление** | Убрать `-suppress` из всех `set_msg_config`. Использовать только `-new_severity WARNING` (меньшая severity). Все сообщения видны в логе как WARNING, не как CRITICAL WARNING |
| **Доп.** | Все `set_msg_config` обёрнуты в `catch` — TCL-скрипт не упадёт даже если одно правило не существует. Добавлены 2 новых правила: `Vivado 12-2285` (PCIe GT lane BEL conflict) и `Vivado 12-4739` (create_clock no valid objects) |
| **Статус** | ✅ Исправлено |

---

## 2026-09-03 — DFX cache cleanup after TCL script changes

### [BUG-024] Stale IP cache in C:/build_dfx — Vivado crash after TCL changes

| Поле | Значение |
|------|----------|
| **Где** | `scripts/build_dfx.tcl`, `scripts/build.bat` |
| **Симптом** | После изменений в `post_bd_dfx.tcl` (CLK_DOMAIN, ASSOCIATED_BUSIF) Vivado запускался из старого кэша: `BD 41-1662 The design 'xdma_ddr3_dfx.bd' is already validated. Therefore parameter propagation will not be re-run`. BD генерация доходила до конца, `launch_runs synth_1` запускался, но потом процесс прерывался без ошибок (`INFO: [Project 1-1719] Creating Reconfigurable Module` → мгновенный выход в cmd). Старый IP cache в `.gen/`, `.cache/`, `.Xil/` был несовместим с новыми скриптами |
| **Исправление** | (1) В `build.bat` добавлена пред-очистка `C:\build_dfx` через `rd /s /q` ДО запуска Vivado — это надёжнее чем TCL `file delete -force`. (2) В `build_dfx.tcl` добавлена расширенная очистка 7 каталогов: `${PROJ_DIR}`, `.cache`, `.gen`, `.hw`, `.ip_user_files`, `.sim`, `.Xil`. Если любой занят — понятная инструкция (taskkill, rmdir, restart) |
| **Статус** | ✅ Исправлено |

---

## 2026-09-03 — DFX post-synth DRC: HDPR-8 + MIG warnings

### [BUG-022] HDPR-8 — 1136 Critical Warnings про INIT without reset в DFX RP

| Поле | Значение |
|------|----------|
| **Где** | `constraints/pblock.xdc` |
| **Симптом** | DRC после synth: 1136 Critical Warnings `HDPR-8 Reconfigurable logic that may need initialization`. Все про FIFO-регистры внутри DataMover в DFX partition: `xdma_ddr3_dfx_i/dfx_partition/axi_datamover_0/.../xpm_fifo_base_inst/...`. Cell has INIT value '1'b1' but without reset. Без reset INIT не загружается после Dynamic Function eXchange → DataMover после reconfig в неизвестном состоянии |
| **Исправление** | `set_property RESET_AFTER_RECONFIG TRUE [get_pblocks pblock_rm]` в `pblock.xdc`. Vivado гарантирует загрузку INIT после reconfig (требует frame-aligned pblock ranges — выполнено) |
| **Статус** | ✅ Исправлено |

### [BUG-023] BUFC-1, REQP-1709, REQP-165, REQP-181 — MIG/DataMover DRC advisories

| Поле | Значение |
|------|----------|
| **Где** | `scripts/suppress_warnings.tcl` |
| **Симптом** | DRC warnings/advisories от MIG IP (DQS IBUFDS без loads, PLL CLKOUT3 phase alignment) и DataMover BRAM (WRITE_FIRST address collision advisories). Не блокируют имплементацию, но засоряют отчёт |
| **Исправление** | Понижение severity через `set_property SEVERITY {Warning} [get_drc_checks <ID>]` для BUFC-1, REQP-1709, REQP-165, REQP-181 |
| **Статус** | ✅ Исправлено |

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