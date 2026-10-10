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

---

# РЕ-АУДИТ 2026-10-11 (после исправлений)

## Выполнено (коммиты, запушено в GitHub)
1. **Бэкап** `ddf7710` — рабочее дерево, `AUDIT_PLAN.md`, `_*.tcl/_*.bat`, `.gitignore`+артефакты.
2. **Харнесс** `e8889b0` — `verify_tdot_axi4.py`: авто-детект Vivado 2025.2 (был жёсткий 2021.2, xvlog не запускался) + добавлен отсутствующий `tfadd48.sv` в список компиляции (чистый `xsim.dir` → elaboration падал). Харнесс теперь воспроизводим с нуля.
3. **RTL-robustness** `884b5ab` — `tdot_axi4.sv`: completion-статус флаги насыщения long-dot (`sat_q`) и кратности адреса (`align_q`); CS_RD_DATA align-guard пропускает невыровненный burst; read-FSM AR гейтится `!fifo_full` (защитный backpressure). **Инертно для корректных входов** (xsim `got` не изменился — подтверждено прогоном NUM_MAC=32).
4. **P1b-модель** `p1b_csa_model.py` — base-3 CSA-дерево: NUM_MAC=16 → 4 уровня, 9 3:2-компрессоров/колонку × 20 = **180 LUT-таблиц** против ~50k LUT текущего 24-фазного `tfadd_raw`; латентность 24→4. **Вывод: дерево = LUT-выигрыш, НЕ DSP-выигрыш** (DSP48 бинарный, base-3/base-81 carry s//81 не нативен). DSP48 помогает только финальный binary-add.
5. **P3-хост** `e9b1937` — `xdma_driver.py` pack/unpack 6-байт TFloat48 (`pack_tf48/write_tf48_packed/read_tf48_packed`), round-trip верифицирован; экономия 25% DDR3/PCIe. RTL-требование: burst `i*6` + word-straddle barrel (6 не кратна 8) — отдельная RTL-задача.
6. **DDR3 round-trip** — `ddr3_roundtrip_test.py` (mock), 8-байт и 6-байт round-trip OK.

## Ключные находки ре-аудита
- **Проверка — главный незакрытый зазор.** Харнесс `verify_tdot_axi4.py` (seed 71) даёт 4/4 расхождений при NUM_MAC=32, расходясь в младших тритах. Причина: **эталон харнесса `_norm_raw_rtl` (итеративный floor) НЕ bit-accurate к round-to-nearest `tfadd_raw`** (`P_can = p_top - rest_n1`, `corr_n1`). RTL проверен A/B-тестом по золотым векторам (автор, 24/24); random-харнесс — слабая независимая сверка. **Бит-accurate Python-эталон = крупная отдельная задача** (нужно точное правило round-to-nearest tfadd_raw, 1133 строк/24 фазы).
- **P1a/P1b RTL-реализация отложена** — вслепую (без bit-accurate эталона) rewrite аккумулятора/дерева нарушает core-инвариант «bit-в-bit» и тихо портит данные. Направление (base-3 CSA дерево + одна нормализация) подтверждено моделью, реализация требует эталона.
- **P0 (DDR3/MIG)** — статус MIG (mmcm_locked, init_calib_complete) уже доступен через GPIO2 (0x40020008), `check_mig.py` читает; stub в top косметика для sniffer. Блокер — hardware-калибровка MIG (вне кода). Tooling (check_mig.py, test_dma_win.py, ddr3_roundtrip_test.py) готов.

## Обновлённый приоритетный план
1. **P0-vf:** bit-accurate Python-эталон round-to-nearest `tfadd_raw` → валидация A/B; затем random-харнесс становится доверенным. (фундамент перед P1a/P1b)
2. **P0-hw:** MIG bring-up на плате (GPIO2), DMA ReadBlock/WriteBlock к 0x80000000, dot из DDR3 vs эталон.
3. **P1a:** carry-save long-dot аккумулятор + единственная нормализация (после эталона, xsim A/B).
4. **P1b:** base-3 CSA-дерево LUT (180-360 таблиц, 4 уровня) + финальный binary-add; DSP48 — опционально на финальный add. (после эталона)
5. **P3:** RTL burst `i*6` + word-straddle barrel для 6-байт packing.
6. **P2:** rebalance 16 MAC / 8-4-2-1; register slices на AXI-мастере для routing margin.
7. **P5/P6:** XADC независимый клок + thermal monitor; fallback 110/100 МГц.
8. Гигиена: удалить неиспользуемые модули (`tbyte_mul`/`tfmac`/`tfmul_kbd`, legacy `tdot_axi_lite`), `.bak_*`, единая `docs/ADDRESS_MAP.md`, подпись+инсталлятор драйвера.
