# Глубокий аудит кода и план исправлений

Дата: 2026-10-11. Объект: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3` (троичный FP-ускоритель TFloat48, Artix-7 XC7A200T, PCIe XDMA + DDR3 + DFX, Vivado 2025.2).

## 1. Общая оценка

Проект **зрелый**: критические дефекты раннего аудита (`ANALYSIS_AND_SPEC_FIX.md`) в текущем коде **исправлены** и подтверждены по коду:
- **A-1 (висячий клок)** — решён: клок/сброс экспортируются из BD (`clk_core_out/core_resetn_out`, `axi_aclk_out/axi_aresetn_out`), top подключает их к `u_tdot` (`xdma_ddr3_core_top.sv:215-220`).
- **A-2 (потеря AW/W)** — решён: независимые защёлки AW/W с commit при `aw_latched && w_latched && !bvalid` (`tdot_axi4.sv:237-312`), backpressure.
- **A-4 (потеря бит [31:16])** — решён: RES0=result[31:0], RES1=result[47:32] → полный 48-бит доступен (`tdot_axi4.sv:347-356`).
- **A-5 (ICAP CSIB/CLK/byte-swap)** — решён: двухфазное окно CSIB (S_PRE→S_OPEN1→S_OPEN2, UG470), делённый клок 62.5 МГц через BUFG, CDC toggle-handshake с ASYNC_REG, хост бейт-свапит LE (`icap_ctrl.sv`, `icap_load.py`).
- **A-6 (GO при BUSY)** — решён: `go_accept = go_pulse && !busy_q && !sched_en_q` (`tdot_axi4.sv:596`).
- **B-1 (file delete runs)** — Makefile/build_dfx.tcl используют reset_run; `build_all.tcl` более не главный.
- **Констрейны** — diff-пара refclk (F10/E10) назначена, lanes x4 по schematic, REQP-123 демотирован с обоснованием, MCP маскирование отключено (правило: нарушение = fatal).

Хост-софт, драйвер и DFX-слой согласованы с DFX-картой адресов (REG 0x40023000, ICAP 0x40024000, XADC 0x46000000, SPI 0x40025000, DFX sock 0x40022000).

## 2. Найденные проблемы (по срезам)

### RTL / интеграция
- **[P0] DDR3/MIG не отвечает на плате** (`DIAG_PLAN.md`): и XDMA-дескриптор, и TDOT-мастер к `0x80000000` виснут в BUSY. Маршрут BD корректен → дело в MIG-калибровке/плате. BRAM-обход (0x00000000) — временный костыль, не продукт.
- **[P1] `fifo_full` — мёртвый сигнал** (`tdot_axi4.sv:405`): объявлен, не используется; нет backpressure на read-канал при переполнении. Сейчас безопасно (FIFO_DEPTH=2·NUM_MAC), но хрупко при расширении.
- **[P1] Насыщение long-dot без флага**: `n_total > MAX_N_TOTAL` молча климпится (`tdot_axi4.sv:620-624`); completion-статус всегда `0x00` (CS_CMP2), переполнение/усечение не сигнализируется хосту.
- **[P1] Непарные адреса**: burst INCR при `data_start` не по 8-байтовой границе → частичный первый beat; хост пишет offset*8, но `data_addr` из дескриптора не проверяется на кратность. Добавить проверку/округление.
- **[P2] FLAT-top**: `icap_ctrl.sv` и SPI-over-PCIe присутствуют в дереве файлов, но инстанцированы только в DFX-варианте; в FLAT — мёртвый код.

### Арифметика (rtl/block)
- **[P1] DSP48E1 = 0 из 740** при 100% pure-LUT. `tfmul_raw` (carry-save) и `tfadd_raw` (barrel, латентность 23) целиком на LUT; при NUM_MAC=64 — ~115k LUT (85%). Троичные partial products (±1) маппятся на пре-аддер/аккумулятор DSP48E1 → освободит LUT, снимет потолок масштабируемости.
- **[P2] `tbyte_mul.sv`/`tfmac.sv`/`tfmul_kbd.sv`** — несколько параллельных реализаций умножителя; часть, вероятно, не используется в финальной сборке → кандидаты на удаление.

### Хост-софт
- **[P1] Нет on-board верификации**: `ternary_dot_layer.py` (batch>1 → NotImplementedError), `_run_fpga` обрабатывает только batch=1; проверка только на mock.
- **[P1] TOCTOU поллинг** (`xdma_driver.py:564-573`): `wait_done` — busy-poll STATUS по PCIe; нет event/IRQ-пути для одиночного dot (планировщик есть, но `dot()` его не использует).
- **[P2] Драйвер неподписан, нет инсталлятора** (README «Открытые задачи»).
- **[P2] `fpga_backend.py`**: `throughput_gflops` — теоретическая оценка, не измеренная.

### Сборка/репозиторий
- **[P2] Гигиена**: много `.bak`, `vivado*.log`, `xsim.dir`, `*.bit/.mcs/.wdb/.pdb` в корне/подкаталогах. Расширить `.gitignore`, вынести артефакты в `build/artifacts_dfx/`.
- **[P2] Расхождение карты**: `xdma_driver.py` описывает HWICAP 0x40001000/SPI/DFX-sock, но FLAT-сборка их не содержит. Нужна одна таблица-источник (`docs/ADDRESS_MAP.md`) и сверка.
- **[P2] `debug_mon.sv`** обещан в части доков, не реализован (адрес 0x47000000 зарезервирован).

### Верификация/CI
- **[P1] Нет CI**: регресс xsim (`verify_tdot_axi4.py`, `rtl_vs_arith48.py`, `verify_fpga_backend.py`) ручной. Нет edge-кейсов: разнесённые AW/W, GO при BUSY, N_IN=0/1/NUM_MAC/NUM_MAC+1, long-dot с насыщением, непарные адреса.
- **[P1] Нет DMA-теста DDR3** (ReadBlock/WriteBlock) — блокирующий пункт P2-4 из старого ТЗ.

## 3. План исправлений (приоритеты)

**P0 — работоспособность на плате (главный блок):**
1. Bring-up MIG/DDR3: проверить `mig_init_calib_complete`/`mmcm_locked` (сейчас в top — заглушки 1'b0, `xdma_ddr3_core_top.sv:305`), вывести реальные статусы MIG из BD; прогнать DMA ReadBlock/WriteBlock к 0x80000000 (`test_dma_win.py`). Критерий: dot из DDR3 == arith48 ±0.
2. Подключить `diag_axi_sniffer` реестр к хосту (S_AXI_DIAG порт, адрес 0x40007000) — для диагностики зависших транзакций.

**P1 — ресурсы, верификация, хост:**
3. DSP48-маппинг `tfmul_raw`: partial-product accumulation через пре-аддер DSP48E1; A/B-сверка bit-в-бит vs pure-LUT; цель — NUM_MAC=64 в пределах LUT-лимита.
4. Сигнализировать насыщение long-dot (completion status != 0) + проверка кратности адресов.
5. On-board регресс + CI (xsim + pytest), edge-кейсы; интеграция `ternary_dot_layer` batch>1 через планировщик.
6. Подписать драйвер + инсталлятор.

**P2 — DFX, гигиена, документация:**
7. Заменить DFX RP на троичное ядро (`tdot_axi4`+`compute_dot_par_raw`) вместо DataMover-демо; проверять hot-swap (`dfx_swap.py`).
8. Удалить/заменовать неиспользуемые модули (`tbyte_mul`, `tfmac`, `tfmul_kbd`, legacy `tdot_axi_lite`), `.bak`, артефакты; единая `docs/ADDRESS_MAP.md`.
9. Реализовать `debug_mon.sv`+порт ИЛИ убрать из доков.

**Definition of Done:** сборка одной командой (`.bit/.bin/.mcs`, WNS≥0, 0 CRITICAL); регресс зелёный; на плате — PCIe enum, LED, DMA DDR3, dot из DDR3, ICAP-перезагрузка RP; документация == железо.

## 4. Замечания (не дефекты)
- `RD_LEN_W`, `fifo_full` — intentional (будущее расширение), задокументированы в комментариях.
- REQP-123, отключённый MCP, clk50 create_clock — обоснованные решения, менять без new-аудита не стоит.
- Симуляционная арифметика верифицирована (RTL == arith48 == torch, max diff ~5e-7).
