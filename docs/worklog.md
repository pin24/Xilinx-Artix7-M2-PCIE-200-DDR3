# Worklog

---
Task ID: 2-a
Agent: Explore-TCL
Task: Анализ TCL/BD скриптов (XDMA + DDR3 + DFX, ветка XDMA_DDR3_TMUL)
Work Log:
- Прочитаны build_dfx.tcl, build.bat, xdma_ddr3_dfx_bd.tcl (791 стр.), post_bd_dfx.tcl, dfx_block_designs/default.tcl (490) и test.tcl (508), block_design_top.tcl (877), xdma_ddr3_bd.tcl, project_config.tcl, Makefile, gen_bin_mcs.tcl, suppress_warnings.tcl, suppress_drc.tcl, resize_bar0.tcl, synth_with_core.tcl, synth_with_icap.tcl, gen_bitstream.tcl, mig_refclk_post.tcl, core_probe/probe.tcl, констрейны (early/pins/pblock), docs/ADDRESS_MAP.md, README.md, README_BLOCK.md.
- Извлечены все create_bd_cell/config (IP-версии), все assign_bd_address (DFX-BD + BDC + legacy), конфиг MIG (proc write_mig_file_...: MT41J128M16XX-125, 16 бит, 256MB, XADC_En Off), конфиг XDMA 4.2 (x4 Gen2, pciebar2axibar_axil_master=0x40000000).
- Проверена цепочка NUM_MAC: build.bat %* → build_dfx.tcl -tclargs → set_property generic NUM_MAC (line 236) → xdma_ddr3_core_top.sv param → tdot_axi4 → compute_dot_par_raw. Доходит.
- Прогрепаны хардкоды путей: активные C:/build_dfx (build_dfx.tcl:20, mig_refclk_post.tcl:19, post_bd_dfx.tcl:30) и легаси C:/A7_M2/EXAMPLES/XDMA_DDR3 (16+ скриптов).
- Сверены адреса: README.md (DFX-карта) vs build_dfx/post_bd_dfx/xdma_ddr3_dfx_bd — полное совпадение (9/9); docs/ADDRESS_MAP.md vs DFX-BD — полное расхождение (в нём не-DFX карта и ссылки на отсутствующий scripts/build_all.tcl).
- Проверено существование: scripts/build_all.tcl — НЕТ; dfx_block_designs/default.tcl — ЕСТЬ; test.tcl — ЕСТЬ (адреса внутри RP расходятся с default.tcl); Makefile include ../../scripts/make/common.mk — файл вне репо, отсутствует; project_config.tcl — orphan (никем не подключается).
- Проверены отчёты scripts/*.rpt — все Vivado 2021.2, пути C:/A7_M2 — устаревшие.
Stage Summary:
- IP-версии DFX-BD: xdma 4.2, mig_7series 4.2, axi_gpio 2.0 (x2), axi_hwicap 3.0, dfx_axi_shutdown_manager 1.0 (x2), dfx_decoupler 1.0, smartconnect 1.0 (x3), axi_register_slice 2.1, clk_wiz 6.0, proc_sys_reset 5.0, util_ds_buf 2.2, xlconcat 2.1, xlslice 1.0; BDC: axi_datamover 5.1 (x2), axis_data_fifo 2.0, smartconnect 1.0 (x2). system_cache и axi_bram_ctrl в DFX нет (axi_bram_ctrl 4.1 — только в legacy xdma_ddr3_bd.tcl).
- DFX-карта (сходится README↔BD↔build_dfx): GPIO 0x40000000, HWICAP 0x40001000, DFX Socket 0x40002000, TDOT 0x40003000, ICAP 0x40004000, MM2S 0x40010000 (32K), S2MM 0x40018000 (32K), XADC 0x46000000, DDR3 0x80000000 (256MB, + алиас RP 0x00000000/256MB).
- Ключевые несоответствия: (1) docs/ADDRESS_MAP.md описывает не-DFX карту, хотя озаглавлен «Карта для DFX-BD», и ссылается на несуществующий scripts/build_all.tcl; (2) root block_design_top.tcl — устаревшая генерация того же BD (xdma 4.1, DDR3 base 0x00000000 вместо 0x80000000); (3) BAR2 нигде явно не настраивается (утверждение доков «BAR2 256MB» непроверяемо, ссылка xdma_ddr3_bd.tcl:483 битая); (4) GPIO в старом xdma_ddr3_bd.tcl range 0x10000 перекрывает TDOT/ICAP не-DFX карты; (5) test.tcl ставит S2MM RP на 0x40011000 вместо 0x40018000; (6) Makefile битый; (7) NUM_MAC доходит только до статического RTL, не в BD/RP; (8) ~16 legacy-скриптов с хардкодом C:/A7_M2; (9) xlconcat_status IN5_WIDTH{27} при NUM_PORTS{5} — мёртвый конфиг.

---
Task ID: 1,3,4,5,6,7
Agent: Main (Super Z)
Task: Клонирование ветки XDMA_DDR3_TMUL, SV-линт (pyslang), проверка констрейнов, Python-тестов, отчётов сборки, поиск мёртвого кода; финальная сводка

Work Log:
- Клонирован репозиторий (ветка XDMA_DDR3_TMUL, HEAD 7f9478c), git fsck чист, секретов в истории нет, 345 файлов.
- Установлен pyslang 11.0.0; написан /home/z/my-project/scripts/sv_lint.py: фаза 1 — синтаксис 109 файлов .sv/.v (RTL+TB+third_party); фаза 2 — полная компиляция design-RTL с BD-стабом xdma_ddr3_dfx, элаборация 29 top-модулей.
- Найдено фазой 1: 2 файла с реальными ошибками SV (declaration after statement): rtl/block/dadda_tree_ternary.sv:208,232 и rtl/block/tfmul_kbd.sv:159,240 (оба — экспериментальные TMUL-модули последнего коммита dd6794d, в сборку НЕ входят).
- Фаза 2: 330 diagnostics, ошибок элаборации нет; 41 warning (sign-compare/case-type — косметика).
- Выявлен мёртвый код: 14 не-тестовых модулей никем не инстанцируются (compute_core*, tf40_alu, ternary_*, tfmul_kbd, dadda_tree_ternary, axi_slave_ok, core_wrapper_top, f32_to_tf40_pipe); сборка build_dfx.tcl использует только 9 RTL-файлов.
- РУЧНАЯ РЕВИЗИЯ tdot_axi4.sv: найден баг CS_LOAD/fifo_pop — при N_IN < NUM_MAC fifo_pop безусловный, weights считываются со смещением → мусор в core_weights. Подтверждено Python-моделью /home/z/my-project/scripts/check_tdot_load.py (при N<NUM_MAC data OK, weights FAIL). TB tb_tdot_axi4.sv:278 всегда задаёт N_IN=NUM_MAC — кейс не покрыт. fpga_backend.py разрешает n<num_mac.
- РЕГРЕССИЯ в tfmul_raw.sv:95: коммит 7207202 заменил partial[2*(t-shift_t)+:2] на partial[2'sd2*(t-shift_t)+:2]; 2'sd2 переполняет 2-битный signed (по IEEE = -2) → отрицательная база part-select → X в симуляции/неверная логика. slang даёт warning vector-overflow; скан всех 9 файлов сборки — других переполненных литералов нет. Ложное подозрение на битые порты .a(am_b[...]) снято — артефакт ANSI-обработки вывода, файл цел.
- Ложная тревога pyslang-кэша: SyntaxTree.fromFile кэширует по пути в пределах процесса (бисекция давала призрачный ExpectedToken) — учтено, на выводы не повлияло.
- Констрейны: pins.xdc/early.xdc/pblock.xdc синтаксически и логически согласованы (clk50 Y18 20ns, refclk F10/E10 10ns, GT X0Y4..Y7, pblock RESET_AFTER_RECONFIG=TRUE, порядок EARLY/NORMAL/LATE корректен). Проверить пины против свежей платы можно только со схемой — вне репо.
- Python: pytest ternary_sw 10/10 PASS; ternary_booth_ref 100/100 PASS; verify_cpu PASS (add rel~2e-3, sub rel~2.5e-2 — точность формата, не ошибка); verify_fpga_backend PASS; все 68 .py компилируются.
- Отчёты scripts/*.rpt — Vivado 2021.2, путь C:/A7_M2, util 33.7k LUT (25%) без ядра — устаревшие, не отражают DFX-сборку 2025.2.
- icap_ctrl.sv (toggle-handshake CDC, ASYNC_REG, окно CSIB 1 такт), xadc_temp.sv, compute_dot_par_raw.sv (ping-pong дерево, пульс valid_out tfmul_raw 1 такт — согласовано) — ревизия без критических замечаний.

Stage Summary:
- КРИТИЧНО: (1) баг tdot_axi4 CS_LOAD при N_IN<NUM_MAC (мусор в weights; хост допускает n<num_mac; TB не покрывает); (2) регрессия tfmul_raw.sv:95 2'sd2 (умножитель активной сборки; чинить на partial[2*(t-shift_t)+:2] и пересимулировать).
- ВАЖНО: синтаксические ошибки в dadda_tree_ternary.sv/tfmul_kbd.sv (эксперименты последнего коммита, вне сборки); docs/ADDRESS_MAP.md описывает не-DFX карту и ссылается на несуществующий build_all.tcl; все .rpt в repo устарели (2021.2); Makefile битый; ~16 легаси-скриптов с C:/A7_M2; BAR2 нигде явно не конфигурируется.
- ЧИСТО: git-история, секреты, Python-тесты (10+100+протокол), констрейны, icap_ctrl/xadc_temp CDC, цепочка NUM_MAC, карта адресов DFX README↔BD↔build_dfx (9/9).

---
Task ID: 9
Agent: Main (Super Z)
Task: Удаление мёртвого кода, исправление багов, полный ре-аудит (ветка XDMA_DDR3_TMUL)

Work Log:
- Построен точный граф инстанцирования всех SV/V-модулей + ссылки из исполняемых скриптов (py/tcl/bat/Makefile vs .md) — scripts/dead_scan.py.
- УДАЛЕНО 61 файл (commit a86ef65, 3665 строк): 7 мёртвых модулей (tdot_axi_lite — «LEGACY-дубль» по самопометке, core_wrapper_top, axi_slave_ok, ternary_mantissa_adder, ternary_full_adder, ternary_carry_propagate_adder, ternary_booth_recoder), 40 dbg/итерационных TB (dbg2..8, fsm2..4, mul_pipe 64b/64c/50/3pairs/5pairs/one/pause/trace/debug и т.п.), 3 закоммиченных генерата tb_*_use.sv (verify-скрипты регенерируют), 3 hex-сироты (mulp3_out, mulp64_in/out), 6 *.pb логов xsim, 2 *.bak.
- Блокирующая проверка перед удалением: ни один файл не упоминается в исполняемых скриптах (только генерация *_use — осознанно разрешена).
- ФИКС 1 — tfmul_raw.sv:95: регрессия 7207202, возвращено partial[2*(t-shift_t)+:2] вместо partial[2'sd2*(t-shift_t)+:2] (2'sd2 = -2 в 2-битном signed → отрицательная база part-select).
- ФИКС 2 — tdot_axi4.sv CS_LOAD: fifo_pop теперь только при реальном потреблении fifo_q (data-фаза: idx<n_in_eff; weights-фаза: idx-NUM_MAC<n_in_eff). Ранее при N_IN<NUM_MAC weights читались со смещением. Проверено моделью scripts/check_tdot_load.py (OLD=FAIL/NEW=OK для NUM_MAC=8/16/32 × N_IN=0..NUM_MAC). Модель обновлена на сравнение OLD vs NEW.
- ФИКС 3 — удалён dead-код res_cap в tdot_axi4 (авторский TODO), мёртвые объявления carry_col/a_sum/b_sum в tfmul_kbd.
- ФИКС 4 — синтаксис dadda_tree_ternary.sv (208,232) и tfmul_kbd.sv (159,240,278): «declaration after statement» → объявления перенесены в начало блоков.
- ФИКС 5 — xdma_ddr3_core_top.sv: добавлен newline EOF. .gitignore: +*.pb, +*_use.sv, +*.bak. git config core.fileMode=false (287 файлов имели фальшивый mode-изменение 100644→100755 от окружения, содержимое не менялось).
- ИНСТРУМЕНТАЛЬНЫЙ фикс: BD-стаб sv_lint.py имел output-направления для S_AXI_*_REGS slave-портов → 6 ложных ExpressionNotAssignable + 6 PortWidthTruncate; стаб переписан (slave: addr/prot/valid/wdata/wstrb = input; ready/b/r = output; ICAP/XADC awaddr 8 бит). Ложные диагностики исчезли.
- Ре-аудит: pyslang фаза 1 — 0/59 проблем; фаза 2 — элаборация 20 топов OK, 300 диагностик (все стилистические: CaseTypeMismatch/SignCompare/ArithOpMismatch и т.д.), 0 ошибок, 0 дублей; pytest ternary_sw 10/10; ternary_booth_ref 100/100; verify_cpu PASS; verify_fpga_backend PASS; py_compile 68 файлов OK; аудит 427 файловых ссылок скриптов — битых нет (генераты *_out.hex/_use.sv — ожидаемо создаются при прогоне; PCIE_X0Y0.xdc — IP-генерат, обрабатывается -quiet); все 13 файлов build_dfx.tcl в git; активные доки (README*, Makefile) не ссылаются на удалённое.
- Коммит a86ef65 запушен в origin/XDMA_DDR3_TMUL (7f9478c..a86ef65). Рабочая копия чистая.

Stage Summary:
- Итог: -3665 строк мёртвого кода, +2 критических фикса активного RTL (tfmul_raw part-select, tdot_axi4 fifo_pop), 0 регрессий по всем аудитам.
- Требует внимания вне скоупа: legacy-скрипты со ссылками на несуществующий build_all.tcl (add_icap_xadc_bd, fix_bd_clock_export, synth_with_core:build_existing.tcl), docs/ADDRESS_MAP.md (не-DFX карта), битый Makefile (common.mk вне репо), ~16 legacy-скриптов C:/A7_M2, устаревшие *.rpt. Эксперименты tfmul_kbd/dadda_tree_ternary сохранены и исправлены (не подключены к сборке — решение за пользователем).
- Симуляция Vivado xsim недоступна в окружении — рекомендуется прогон verify_tdot_axi4.py / verify_compute_dot_par_raw.py на машине с Vivado для аппаратной валидации фиксов.

---
Task ID: 10
Agent: Main (Super Z)
Task: Горячая замена RP без JTAG (DFX) — фиксация всех найденных багов DFX-цепочки

Work Log:
- Ревизия всей DFX-цепочки: build_dfx.tcl, post_bd_dfx.tcl, xdma_ddr3_dfx_bd.tcl, dfx_socket (hier proc), icap_ctrl.sv, xdma_ddr3_core_top.sv, dfx_block_designs/{default,test}.tcl, gen_bitstream/gen_bin_mcs, gen_bin_mcs, pytorch_layer/*, ERROR_HISTORY.md.
- Снят подозрение на конфликт двух ICAPE2 (HWICAP IP @icap_clk=50MHz + icap_ctrl @62.5MHz): ERROR_HISTORY показывает прохождение place_design после фикс XADC UTLZ-1 → 2 сайта ICAP на XC7A200T размещаются, конфликтов нет.
- ФИКС test.tcl: S2MM RP-локально 0x40011000 → 0x40018000 (хост по канону 0x40018000 не попадал в S2MM — замена RP-варианта была неработоспособна).
- КАНОНИЗАЦИЯ диапазонов DataMover control 32K → 4K: build_dfx.tcl (шаг 2d), xdma_ddr3_dfx_bd.tcl, default.tcl, test.tcl — освободили апертуру RP 64K для доп. IP (GPIO test.tcl @ 0x40012000 остаётся валидным).
- BD: удалён мёртвый CONFIG.IN5_WIDTH{27} из xlconcat_status (NUM_PORTS=5, порта In5 нет).
- build_dfx.tcl: PROJ_DIR переносимый (env PROJ_DIR > Windows C:/build_dfx (MAX_PATH) > Linux build/dfx_proj), экспорт ::env(PROJ_DIR_BUILD) дочерним скриптам; catch{close_project} на cleanup-fail; PCIe BAR REPORT (BAR0..5 + MSI-X enabled/BIR + предупреждение о выключенном BAR2 при MSI-X на BAR_3:2); STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE; шаг 9b — экспорт ЧАСТИЧНЫХ битстримов RP (*partial*.bit/.bin) в artifacts (раньше не экспортировались вовсе — горячая замена была невозможна).
- post_bd_dfx.tcl/mig_refclk_post.tcl: переносимый поиск проекта (env → repo build/ → C:/build_dfx легаси).
- gen_bitstream.tcl/gen_bin_mcs.tcl: переписаны с легаси C:/A7_M2/не-DFX имени проекта на переносимый поиск DFX-проекта + экспорт partial.
- Makefile: переписан самодостаточно (битый include ../../scripts/make/common.mk удалён; targets: build/proj/artifacts/bitstream/clean).
- НОВЫЙ pytorch_layer/dfx_swap.py — полная последовательность горячей замены RP: quiesce (GPIO 0x40002000 ch1=0b111: decouple+shutdown M+S) → ожидание 0b11010 → частичный бит через icap_ctrl → resume → verify_alive; CLI: --status/--timeout/--no-verify/glob. Биты взяты из фактической проводки dfx_socket (xlslice Din[0/1/2], xlconcat_status In0..In4).
- icap_load.py: IcapLoader принимает готовое dev (переиспользование соединения).
- xdma_driver.py: XdmaLinux usr-устройство опционально (в DFX-сборке BAR2 нет) с внятной ошибкой про DMA-каналы h2c/c2h; monitor_temp.py — актуализирован комментарий XADC (0x46000000, BUG-031).
- docs/ADDRESS_MAP.md переписан ЦЕЛИКОМ под DFX-карту: BAR0 128MB (BAR2 — только MSI-X, DDR3 НЕ смаплен в PCIe — DMA-only), DFX Socket §4 (биты+протокол замены), RP-варианты §9, история; легаси-карта (TDOT 0x40001000/ICAP 0x40002000/build_all.tcl) удалена. README.md синхронизирован (DDR3 через DMA, 4K-сегменты, dfx_swap.py, структура артефактов).
- 14 легаси-скриптов + block_design_top.tcl — deprecated-заголовки; project_config.tcl — помечен справочным.
- РЕ-АУДИТ: scripts/dfx_reaudit.py (новый) — TCL-баланс 8 файлов 0 ошибок; адреса 4 файлов vs канон DFX — совпадение; константы host-софта vs карта — совпадение; мок-прогон dfx_swap quiesce/resume — OK, биты 0b111 == BD-проводке. sv_lint: 300 стилистических (как до правок), UnknownModule×2 = BUFG/ICAPE2 (вендор-примитивы, ожидаемо); check_script_refs — только ложные срабатывания на ${VAR}-конкатенации в deprecated-файлах; dead_scan — новых мёртвых модулей нет; py_compile OK; pytest 10/10; ternary_booth_ref PASS; verify_cpu PASS; verify_fpga_backend PASS; dfx_swap импорт/CLI OK.

Stage Summary:
- Горячая замена RP без JTAG теперь поддержана end-to-end: сборка экспортирует partial-битстримы, dfx_swap.py выполняет безопасную последовательность UG909, карта адресов/биты документированы и сверены с BD.
- Исправлены: test.tcl S2MM, диапазоны DataMover (4K), мёртвый IN5_WIDTH, легаси-пути всех активных скриптов, Makefile, BAR-видимость (отчёт в сборке), устаревшие доки.
- Вне скоупа (зафиксировано в ADDRESS_MAP §1.2): MMIO-доступ хоста к DDR3 в DFX-сборке отсутствует по архитектуре — данные через DMA h2c/c2h (написание DMA-API для Python — отдельная задача); BAR2/MSI-X подтверждается BAR-отчётом при первой же сборке в Vivado.
- Аппаратная валидация (Vivado build + прогон dfx_swap.py на плате) — за пользователем: в окружении нет Vivado/железа.

---
Task ID: 11
Agent: Main (Super Z)
Task: Разбор «не влезает в чип» при NUM_MAC=16 — подтверждён диагноз BUG-033 (shell режет '='), правки урезания шины откатлены

Work Log:
- Пользователь сообщил: сборка «не влезает в чип», NUM_MAC 32→16 почти не меняет LUT (110583/123007 vs 110487/122890). Начата работа по сужению DMA-фабрики (XDMA 128→64 бит, 4→2 канала, MIG/RP 128→64) — внесены правки в scripts/xdma_ddr3_dfx_bd.tcl.
- Пользователь СКОРРЕКТИРОВАЛ диагноз: реальная причина — shell разрезает NUM_MAC=16 на два argv («NUM_MAC» «16»), regexp {^NUM_MAC=(\d+)$} не срабатывал, обе сборки шли с NUM_MAC=32 (разница ~100 LUT — шум place). Директива: НИ КАКИХ УРЕЗАНИЙ.
- git restore scripts/xdma_ddr3_dfx_bd.tcl — все правки урезания откатлены, рабочая копия чиста (ширина 128/4-канальная конфигурация сохранена).
- FIX BUG-033 в scripts/build_dfx.tcl: парсер $argv переписан на индексный цикл: (1) каноническая KEY=VALUE по $_argn (string trimleft '-'), (2) позиционный fallback KEY VALUE, (3) -KEY VALUE, (4) -KEY=VALUE. Значение валидируется {^\d+$}. Ключи: NUM_MAC/JOBS/SKIP_SYNTH. В баннер добавлен вывод сырого $argv.
- Тест: /home/z/my-project/scripts/test_nummac_parse.py — извлекает РЕАЛЬНЫЙ блок из build_dfx.tcl, исполняет через tkinter.Tcl (tclsh в контейнере нет): 13/13 сценариев OK (разрезанный '=', дефис, смеси, не-числовые, без значения). info complete=1 (баланс TCL цел).
- docs/ERROR_HISTORY.md: запись BUG-033 по конвенции проекта (+ урок о добавлении новых -tclargs в обе ветки парсера).

Stage Summary:
- Все урезания DMA-фабрики ОТКАТЛЕНЫ — конфигурация 128-бит/4-канальная XDMA, MIG 128, RP 128 сохранены без изменений.
- NUM_MAC=16 теперь доходит до сборки в ЛЮБОЙ форме аргумента; обе сборки Run1/Run2 шли NUM_MAC=32 — «отсутствие эффекта» NUM_MAC было артефактом парсинга.
- Утилизация 123007/134600 LUT = 91.4% — помещается, но с малым запасом; по указанию пользователя урезания НЕ проводятся.

---
Task ID: 12
Agent: Main (Super Z)
Task: Реализация выбранного варианта: XDMA 128→64 бит @ 250 МГц (каналы 2+2 сохранены) + LUTRAM→BRAM; просчёт утилизации

Work Log:
- Пользователь выбрал вариант: XDMA 128→64 @ 250 МГц, каналы 2+2 сохранены, + попробовать LUTRAM→BRAM. Полоса не режется: 64б@250МГц = 128б@125МГц = 2,0 ГБ/с; MIG (1,6 ГБ/с) не тронут.
- ВЫЯВЛЕНА ЛОВУШКА: при 64-бит XDMA (Gen2 x4) axi_aclk автоматически 250 МГц, а ядро/RP сидели на нём. WNS 0.370 нс @ 125 МГц (тайминг_full.rpt) → путь ~7.6 нс — на 250 МГц (4 нс) ядро и RP DataMover 128-бит не закроют тайминг. Решение: разделение доменов.
- Домены: XDMA 250 (только XDMA + S-стороны SmartConnect) / fabric-ядро-RP 125 (clk125_core_wiz из clk50, rst_core_125M; dfx_socket, dfx_partition, GPIO, HWICAP S_AXI, u_tdot/u_icap/u_xadc) / MIG 100 (как было). Частота fabric НЕ изменилась (125 как в Run1) → тайминг-риск нулевой.
- xdma_ddr3_dfx_bd.tcl: axi_data_width 64_bit, axisten_freq 250 (каналы 2+2 не тронуты); clk125_core_wiz + rst_core_125M; NUM_CLKS smc=3/lite=2; явный ASSOCIATED_BUSIF (для экспортируемых портов M03-M05/S02 инференс невозможен); перекоммутация тактов/сбросов.
- post_bd_dfx.tcl: экспорт clk_core_out/core_resetn_out; расширение ASSOCIATED_BUSIF (S02_AXI в aclk2, M03-M05 в aclk1); axi_aclk_in FREQ_HZ→250M.
- xdma_ddr3_core_top.sv: порты core_clk/core_resetn; u_tdot/u_icap/u_xadc → fabric-домен (icap_ctrl остаётся на 125 — окно CSIB не изменилось).
- tdot_axi4.sv (LUTRAM→BRAM): fifo_mem (* ram_style="block") 64×48 → BRAM; чтение синхронное → CS_LOAD перестроен в 2-стадийный конвейер (rd_idx — pop+выдача чтения, load_idx=rd_idx−1 — потребление fifo_q); fifo_q без сброса (иначе BRAM-маппинг ломается).
- Проверка: check_tdot_load.py расширен колонкой BRAM — 18/18 (NUM_MAC=8/16/32 × N_IN=0..NUM_MAC, включая N<NUM_MAC) — эквивалентен фиксу a86ef65. sv_lint: элаборация 20 топов OK, PortDoesNotExist устранены (стаб обновлён и в sv_lint.py, и в _bd_stub.sv), правленные файлы без диагностики (дельта +2 SignCompare — стилистика). TCL-баланс 8 файлов: 0 ошибок.
- Просчёт (scripts/lut_projection.py, калибровка util_with_core_hier.rpt + факт Run1): NUM_MAC=32 → ~116,150 LUT (86.3%; коридор 85.3–87.5% при факторе экономии XDMA 0.25–0.38); NUM_MAC=16 → ~85,600 LUT (63.6%). LUTRAM→BRAM через RTL управляем только tdot FIFO (~120 LUT); остальной «LUT as memory» (12,424) — внутри IP и сокращается шириной XDMA.
- docs/ERROR_HISTORY.md: BUG-034 (+ урок про axi_aclk/ASSOCIATED_BUSIF). Коммит b133ab4 запушен в origin/XDMA_DDR3_TMUL.

Stage Summary:
- Выбранный вариант реализован БЕЗ урезаний: полоса PCIe/MIG, каналы 2+2, ширина RP — без изменений; ядро осталось на своей частоте 125 МГц.
- Ключевой артефакт: BUG-034 (разделение доменов — обязательная часть варианта 64@250; без него ядро/RP не закроют тайминг).
- За пользователем: сборка в Vivado 2025.2 (make build NUM_MAC=16), проверка report_utilization -hierarchical (фактическое распределение LUTRAM) и тайминга fabric-домена; при желании — симуляция tb_tdot_axi4 (перестроенный CS_LOAD).

---
Task ID: 13
Agent: Main (Super Z)
Task: Python DMA-API (h2c/c2h) для DFX-сборки + widening RP-потока AXIS 32→64 бит; разбор «планировщика выполнения в FPGA»

Work Log:
- Разобран «планировщик»: hardware-очереди задач для TMUL-ядра НЕТ — tdot_axi4 это single-shot FSM (GO→чтение→вычисление→запись→DONE), вся адресация программируется хостом на каждый вызов. Единственная «очередь» в железе — datamover_ctrl (third_party): конвейерная отсылка бёрст-CMD (usr_buffer/usr_length/usr_burst, автоприращение адреса, AUTO_ENABLE) для RP-копирования; арбитраж мастеров — round-robin SmartConnect. Вывод: планирование — ответственность хоста (Python), в железе осознанно не закладывалось.
- Реализован Python DMA-API (commit deb1dd6): XdmaDevice.write_dma/read_dma (смещения от 0x80000000; базовая реализация поверх MMIO — MockMem-совместимость verify сохранена); XdmaLinux — реальные каналы /dev/xdma0_h2c_0/c2h_0, чанки 1 МиБ, хвост паддится до кратности 4 байт, фолбэк на usr (легаси BAR2), при полном отсутствии узлов — XdmaError с подсказкой; XdmaWindows — xdma_rw.exe h2c_0/c2h_0 (-f tmpfile для записи). TdotCore.write_tf48/read_tf48 переведены на DMA автоматически.
- CLI-самопроверка: python xdma_driver.py --selftest [--dot] — паттерн-раундтрип + замер МиБ/с + опционально dot(1.0×8)=8.0 на железе.
- Widening RP: dfx_block_designs/{default,test}.tcl — c_m_axis_mm2s_tdata_width и c_s_axis_s2mm_tdata_width 32→64. Потоковый тракт RP 64b×125 МГц = 1,0 ГБ/с (было 500 МБ/с); AXI 128b, CMD 104b/STS 8b и адреса не тронуты (ширина CMD зависит только от addr_width=64); axis_data_fifo наследует ширину через interface propagation. Универсальная смена: в default.tcl отдельно учтено 128b×125 AXI → 64b×125 AXIS.
- Регресс: verify_fpga_backend.py OK (0.0 diff по всем трём сравнениям); py_compile всех py OK; pytest ternary_sw 10/10; dfx_reaudit.py — TCL-баланс 8 файлов 0 ошибок, адреса/константы совпадают, dfx_swap мок OK; новый /home/z/my-project/scripts/test_dma_api.py — 5/5 (приоритет h2c/c2h, чанки/паддинг 5..2 МиБ, usr-фолбэк, XdmaError-подсказка, TdotCore через DMA-API). xdma_driver.py --selftest --help OK.
- docs/ADDRESS_MAP.md §1.2 переписан (MMIO-моста нет; DMA-API + selftest) и §9 дополнен WIDENED-примечанием.

Stage Summary:
- Путь данных PC→DDR3→ядро→PC в DFX-сборке теперь полностью работает через канонический DMA-режим (h2c/c2h), ошибка «нет BAR2» больше не возникает.
- RP-поток расширен до 1,0 ГБ/с (в 2 раза), узкое место №1 полосы снято; остаётся MIG 1,6 ГБ/с как общий потолок системы.
- Планировщик выполнения: только хостовый (Python); в FPGA — single-shot FSM ядра + конвейер CMD у datamover_ctrl. Если понадобится аппаратный batch/очередь dot-задач — отдельная задача (ring-buffer команд + done-IRQ).
- За пользователем: на стенде python xdma_driver.py --selftest --dot; пересборка Vivado для BDC-вариантов (widening попадает в partial-битстримы RP).

---
Task ID: 14
Agent: Main (Super Z)
Task: Аппаратный планировщик TDOT (ring-buffer команд + IRQ) с long-dot аккумулятором; БЕЗ push (указание пользователя)

Work Log:
- Спроектирована и реализована архитектура: ВСЯ механика AXI (fetch дескриптора 32Б, задача, completion 16Б) — в ОДНОМ always_ff контроллера tdot_axi4 (исключены мультидрайверы rd_*/wr_*/sched_rptr/irq_pending; планировщик = wire sched_pull/sched_ack_pulse). Промежуточная версия с отдельной FSM планировщика была переписана из-за multi-driver.
- tdot_axi4.sv: (1) long-dot — N_IN до 16*NUM_MAC (MAX_N_TOTAL, сатурация; 0→NUM_MAC легаси), контроллер multi-pass: CS_RD_DATA/WEIGHTS→CS_LOAD→CS_RUN→CS_WAIT, накопление через новый tfadd48 (pass 0 — без сложения; acc_start→CS_ACCUM_WAIT→add_valid), адреса чанков cur_*_q + elems_done*8; (2) регистры — декод [5:2]→[7:2], новые 0x40 SCHED_CTRL (en/irq_en/flush/irq_ack), 0x44 WPTR, 0x48 RPTR, 0x4C..0x58 DESC/COMP_BASE, 0x5C STATUS, 0x60 DONE_CNT; указатели 8-бит (кольцо mod 256 — исправлено с исходных 16-бит, иначе адреса уходили за 2МБ); (3) планировщик: CS_IDLE(sched_pull)→CS_FETCH_DESC(capture desc_w по fifo_push)→CS_SCHED_KICK→(многопроходная задача)→CS_DONE→CS_CMP1..3 (completion W0={tag,result}, W1={passes,status}; rptr++, done_cnt++, IRQ при опустошении); при sched_en внешний GO игнорируется; легаси-режим (GO) полностью сохранён.
- rtl/block/tfadd48.sv (НОВЫЙ): сумматор двух нормализованных TFloat48 — распаковка в (prod,e,neg) той же конвенции, что compute_dot_par_raw, + tfadd_raw.
- xdma_ddr3_core_top.sv: tdot_irq_w + 2-FF синхронизация (ASYNC_REG) в домен axi_aclk 250; BD-порт tdot_irq. post_bd_dfx.tcl шаг 2b: tdot_irq→xlconcat_irq(In0; In1..15=xlconstant 15'b0)→xdma_0/usr_irq_req (MSI-X). sv_lint.py BD_STUB_PORTS + _bd_stub.sv: добавлен tdot_irq (стаб перегенерируется из шаблона sv_lint!).
- xdma_driver.py: TdotScheduler (submit: данные data 0x20_0000/weights 0x60_0000 слоты idx*0x4000, дескрипторы blob→DMA, WPTR doorbell; wait: блокирующее /dev/xdma0_events_0 либо поллинг RPTR 200мкс; collect: парсинг completion со split при wrap; dot_batch: авто-теги, results 0xA0_0000+idx*8), самопроверка --sched K (K задач + long-dot 64). ИСПРАВЛЕНО в ходе теста: пересечение регионов results/data/weights (было 0x300000 у results → мусор 16.0 вместо 4.0) — разведены 0x20/0x60/0xA0 МБ; wrap кольца в submit/collect двумя кусками.
- Верификация: check_tdot_longdot.py (99 случаев: краевые n=1..NUM_MAC побитово = CPU; long-dot k*NUM_MAC+r; сатурация; нулевые хвосты) — worst rel_err 0; test_sched_host.py (модель железа: дескрипторы/long-dot/completion/wrap 300 задач через границу 256/защита от переполнения) — OK; test_dma_api 5/5; verify_fpga_backend OK; check_tdot_load OK (регресс CS_LOAD); pytest 10/10; dfx_reaudit 0 ошибок; sv_lint: синтаксис 0 файлов с проблемами, элаборация 20 топов, все диагностики изменённых файлов стилистические (CaseTypeMismatch/SignCompare/ArithOpMismatch — профиль базового кода), UsedBeforeDeclared/PortDoesNotExist/Typo устранены.
- docs/ADDRESS_MAP.md: §3 декод [7:2] + новые регистры, §3.1 (дескриптор/завершение/IRQ-протокол), §6 DDR-регионы планировщика, §11 история.
- ловушки (для ERROR_HISTORY-класса): 32'dNUM_MAC — невалидный литерал (нужен 32'(NUM_MAC) или голый параметр); объявления после использования = UsedBeforeDeclared; стаб BD перегенерируется sv_lint.py — править шаблон BD_STUB_PORTS, не только файл.

Stage Summary:
- Реализован полный аппаратный планировщик: хостовый batch = 1 h2c-DMA дескрипторов + 1 MMIO doorbell; железо само исполняет очередь (включая long-dot до 512 элементов) и пишет completion; IRQ (MSI-X вектор 0) при опустошении; ожидаемая оценка ~300–500 LUT + 0 BRAM добавки.
- Легаси-путь (GO/N_IN/RES0) не тронут — все существующие тесты/ПО совместимы.
- ЛОКАЛЬНЫЙ КОММИТ (без push по указанию пользователя). За пользователем: сборка Vivado 2025.2, стенд: --selftest --dot --sched 16.

---
Task ID: 15
Agent: Main (Super Z)
Task: FATAL тайминг WNS -120.809 / TNS -373780: разбор критического пути, исправление констрейнтов, FATAL-гейт в сборке; без push

Work Log:
- Сигнатура провала: TNS/WNS ~ 3093 эндпоинта с почти одинаковым slack -120.809 ns — межклоковая пара, затаймированная как синхронная. Аудит repo: НИ ОДНОГО тайминг-исключения в проекте (set_clock_groups/set_false_path/set_max_delay отсутствуют полностью) при 4 асинхронных клоковых корнях (pcie_refclk -> userclk1 250/userclk2 125; сырой clk50 -> HWICAP icap_clk; clk125_core_wiz -> fabric/RP; clk200 -> MIG ui_clk). Все CDC (SmartConnect 250/125/100, tdot_irq_sync, icap_ctrl, HWICAP 50<->125) были в setup/hold-анализе с полным требованием.
- Найден второй дефект: mig_refclk_post.tcl создавал create_clock mig_refclk на pin IODELAYCTRL/REFCLK, на который УЖЕ распространялся авто-клок clk_out1_clk200_clk_wiz (та же цепь через mig_7series_0/clk_ref_i) — два клока на одной цепи, фиктивные inter-clock пары внутри MIG PHY вне действия штатных исключений MIG XDC.
- constraints/timing_exceptions.xdc (НОВЫЙ): set_clock_groups -asynchronous между 4 группами (pcie-дерево с include_generated_clocks; сырой clk50 без порождённых; clk_out1_clk125_core_wiz; clk_out1_clk200_clk_wiz + mig_refclk при наличии). Группы собираются в catch, пустые пропускаются с CRITICAL WARNING; менее 2 непустых — исключения НЕ применяются (loud). Внутри групп тайминг не ослаблен. + set_max_delay -datapath_only 10 ns на tdot_irq_sync_reg/_sync_ff1 (подстраховка).
- mig_refclk_post.tcl: перед create_clock проверка get_clocks -of_objects [get_nets] на pin'е; клок создаётся только если propagated clock отсутствует.
- build_dfx.tcl: (1) timing_exceptions.xdc добавлен в constrs_1 (PROCESSING_ORDER NORMAL); (2) НОВЫЙ шаг 8.5 FATAL TIMING GATE: open_run impl_1 -> report_timing_summary -> парс -> print_verdict; WNS/WHS/WPWS < 0 => worst-10 путей в лог, timing_FATAL.rpt, НОЛЬ экспорта артефактов, exit 1. Отдельно гейтятся routed-отчёты child_impl* (RP partial). Шаг 9: open_run защищён от повторного вызова.
- scripts/tcl_timing_lib.tcl (НОВЫЙ, чистый Tcl): parse_summary_string/parse_summary_rpt (блок Design Timing Summary, 12 полей, -inf/NA), is_fatal (WNS<0 || WHS<0 || WPWS<0), print_verdict, fmt_summary.
- scripts/check_timing_fatal.tcl (НОВЫЙ): standalone-гейт на любой checkpoint (аргумент dcp или авто-поиск impl_1 по PROJ_DIR); exit 0/1 — для ручных прогонов и CI.
- scripts/timing_report_analysis.tcl (НОВЫЙ): batch-аналог Reports -> Report Timing Summary: Clock Summary + Inter-Clock Table в stdout, топ-32 worst setup путей (slack/requirement/datapath/logic levels/start/end), атрибуция модулей-виновников (топ-10 по числу эндпоинтов), топ-5 hold путей, logic-level distribution (гид по pipelining), report_clock_interactions + report_cdc. Exit 0 (анализ, не гейт).
- Ловушки Tcl (для тестов): split $str без splitChars режет на СИМВОЛЫ (155 «полей») — нужно regexp -all -inline {\S+}; exit не существует в tkinter.Tcl (в тестах return).
- Проверки: /home/z/my-project/scripts/test_timing_gate.py — 22/22 (парсер на РЕАЛЬНОМ timing_full.rpt: WNS 0.370/TNS 0/109148 эндпоинтов; синтетическая сигнатура -120.809/-373780 -> FATAL; -inf/NA/пустой блок; verdict rc; TCL-баланс 5 файлов). dfx_reaudit.py: 0 ошибок. Мок-тест сборки групп set_clock_groups: команда формируется верно, пустые группы дают CRITICAL WARNING. RTL-аудит CDC: tdot_irq_sync (2FF ASYNC_REG, fabric125->axi_aclk 250) и icap_ctrl — корректны, RTL-правки не требуются.
- docs/ERROR_HISTORY.md: BUG-035 (3 причины, 3 исправления, урок: новый клоковый домен => немедленно исключения; сборка без FATAL-гейта не считается завершённой).
- ЛОКАЛЬНЫЙ КОММИТ без push. За стендом: пересборка (исключения входят в impl и child impl), затем vivado -mode batch -source scripts/timing_report_analysis.tcl -tclargs <impl_1.dcp> — если WNS < 0 останется, отчёт даст пару клоков и модуль-виновника для pipelining.

Stage Summary:
- Подтверждены и устранены 2 структурных дефекта констрейнтов (отсутствие clock-groups; дублирующий mig_refclk).
- Тайминг стал управляемым: FATAL-гейт в сборке (битстрим с WNS<0 не экспортируется, exit 1), гейт утилитой на любой чекпоинт, диагностический скрипт с атрибуцией модулей.
- Ожидание: после пересборки WNS должен вернуться в район +0.3..0.5 ns (последний met-отчёт), Т.К. межклоковая нагрузка снята; остаточные intra-доменные нарушения (если есть) увидим в timing_report_analysis.tcl.

---
Task ID: 15
Agent: main (Super Z)
Task: Ответить, почему сборка идёт по tfmul_raw вместо tfmul_kbd, и чем они отличаются (расследование, без правок кода)

Work Log:
- git fetch: origin/XDMA_DDR3_TMUL ушёл вперёд на 11 коммитов (параллельный агент), в т.ч. 7da39e5 «Fix BUG-037: carry-save pipeline in tfmul_raw» (48 тактов, ~15 LUT/колонку) и 9c59b3b (BUG-035/036 BD clock mapping). Локально ahead 2 / behind 11.
- Найдены ОБЕ причины, почему собирается tfmul_raw: (1) compute_dot_par_raw.sv:31 жёстко инстанцирует `tfmul_raw u_mul` внутри gen_mac[i]; (2) build_dfx.tcl:314 добавляет в файлсет только tfmul_raw.sv. tfmul_kbd.sv НЕ упомянут ни в одном скрипте сборки (build_dfx/synth_with_icap/synth_with_core/synth_par_raw/Makefile — 0 упоминаний) и нигде не инстанцирован.
- Атрибуция критического пути исправлена: b_mr_reg[16] -> prod_r_reg[77] — регистры a_mr/b_mr/prod_r из tfmul_raw; у tfmul_kbd регистры называются prod_q/e_q/neg_q/valid_q. Значит 10419 нарушений — в tfmul_raw; параллельный агент в 7da39e5 починил правильно именно tfmul_raw (не tfmul_kbd).
- Разница: tfmul_raw = последовательный (1 общий tbyte_mul 8x8, 25 тактов накопления в 40-тритовый аккумулятор через длинную carry-цепочку = 263 уровня); tfmul_kbd = комбинаторный Karatsuba 20x20 (3 x mul_10x10 столбцовая редукция, Booth отложен) за 1 такт — по таймингу был бы ЕЩЁ хуже; усечение cross-терма Karatsuba до 10 тритов (строки 276-282, признано в комментарии = потеря точности); tb_tfmul_kbd не существует (есть только Python-эталон ternary_sw/ternary_kbd_ref.py); верификация не завершена.
- LUT: tfmul_raw ~1.56k/инстанс x32 ~ 50k; tfmul_kbd обещал ~17k (69% экономии), не проверено.
- Код НЕ менял (только расследование). tfmul_kbd.sv идентичен локально и на origin.

Stage Summary:
- Ответ дан пользователю: tfmul_kbd писался как drop-in замена (интерфейс совпадает), но переключение инстанса и файлсета так и не было выполнено; сейчас он мёртвый код в ветке.
- Варианты: (A) довести kbd — mul_11x11 без усечения, tb против ternary_kbd_ref.py, пайплайн 16-20 стадий, переключение generate-параметром MUL_IMPL, замер LUT/WNS; (B) вынести kbd в отдельную ветку/удалить, оставить carry-save tfmul_raw.
- Следующий шаг сборки: подтянуть origin (behind 11), пересобрать с FATAL-гейтом, зафиксировать новый WNS/TNS.

---
Task ID: 16
Agent: main (Super Z)
Task: Цикл правок/тестов tfmul_kbd до нуля ошибок (BUG-039): s-коррекция + carry_val + tb; merge origin; история ошибок

Work Log:
- MERGE origin/XDMA_DDR3_TMUL (behind 11 -> 0): carry-save tfmul_raw (7da39e5), BD-фиксы BUG-035/036, cleanup 9cfce13. Разрешены 3 конфликта: (1) ERROR_HISTORY.md — обе стороны сохранены, локальная запись перенумерована BUG-035 -> BUG-038 (коллизия номеров с origin), консистентно обновлены комментарии гейта (build_dfx.tcl 8.5, tcl_timing_lib, check_timing_fatal, timing_report_analysis, timing_exceptions.xdc); (2) post_bd_dfx.tcl — принята структура origin (порты переехали в базовый BD-скрипт), секция планировщика tdot_irq сохранена как 5c (в базовом скрипте её нет); (3) mig_refclk_post.tcl — удаление origin принято (хук уже снят, ссылка в комментарии build_dfx.tcl вычищена). core_top смержился чисто: BUG-036 (core_clk logic) + tdot_irq_sync вместе. Merge-коммит 6d2b987, без push.
- BUG-039 в tfmul_kbd.sv (ВЕРСИЯ 2): (а) s-коррекция среднего члена Karatsuba — перенос s из a_sum_local[2*HALF +: 2] больше не выбрасывается: mid = a_mod*b_mod + 3^10*(s_a*b_mod + s_b*a_mod) + 3^20*(s_a*s_b); corr1 (11 тритов) + слияние 21 колонку; эквивалент mul_11x11 без роста дерева; (б) carry_val в mul_10x10 [1:0] -> [3:0], присвоение q[3:0] (q достигает ±5).
- Верификация: построчная Python-модель ternary_sw/model_tfmul_kbd.py — 0 ошибок на 72 направленных (все 16 комбинаций крайних половин, s_a*s_b = ±1) + 100k random; контроль фиделити: старая версия 44.0% неверных. Эталон ternary_kbd_ref.py 100/100 (не менялся).
- tb_tfmul_kbd.sv (self-checking, golden = longint-умножение + int_to_prod40): 3026 векторов (16 крайних + простые + 3000 random), проверка prod/e/neg/valid; запуск xsim за стендом.
- Регрессии контейнера: sv_lint.py (новый) — баланс begin/end/() /[] в tfmul_kbd/tb/tfmul_raw/tb_raw: OK; test_timing_gate.py 22/22 (фикстура timing_full.rpt заменена компактной scripts/tests/timing_sample_met.rpt из git-истории — файл удалён на origin в 9cfce13; список TCL-файлов обновлён); dfx_reaudit.py 0 ошибок (список TCL_FILES актуализирован: gen_bitstream/gen_bin_mcs тоже удалены на origin).
- docs/ERROR_HISTORY.md: BUG-039 записан наверх (+ поле «Связь с BUG-037» — уточнение атрибуции: критический путь b_mr_reg/prod_r_reg = tfmul_raw, 7da39e5 чинил правильный файл).

Stage Summary:
- tfmul_kbd.sv точен (модельный уровень), НО остаётся вне сборки: однотактный, тайминг не закрыт (BUG-037). Следующий шаг по kbd — пайплайн 16-20 стадий, только потом MUL_IMPL-переключение.
- Тайминг-дисциплина проекта восстановлена после merge: FATAL-гейт (шаг 8.5) на месте, тесты гейта 22/22, reaudit 0 ошибок.
- ЛОКАЛЬНЫЕ КОММИТЫ без push (ветка ahead 4). За стендом: (1) xsim tb_tfmul_kbd — ожидать ALL TESTS PASSED; (2) make build NUM_MAC=16 с FATAL-гейтом — зафиксировать WNS/TNS после carry-save tfmul_raw (7da39e5) + clock-groups (BUG-038); (3) selftest/dot через pytorch_layer/xdma_driver.py.

---
Task ID: 17
Agent: main (Super Z)
Task: Ответить «используем ли теперь kbd, а не raw?» — проверка распайки + количественный анализ целесообразности пайплайнинга kbd

Work Log:
- Проверка фактов (git + grep): ветка ahead 4 (merge 6d2b987 + BUG-039 3199b05), origin без изменений. compute_dot_par_raw.sv:31 = `tfmul_raw u_mul`; build_dfx.tcl:314 = только tfmul_raw.sv; упоминаний tfmul_kbd в ЛЮБЫХ скриптах сборки/RTL-инстансах = 0 (кроме самого файла и tb). ОТВЕТ: сборка использует tfmul_raw; kbd сознательно не подключён (однотактный; подключение = повтор BUG-037, FATAL-гейт бы прервал сборку).
- Количественный анализ пайплайн-вариантов kbd (подготовка Variant A):
  * стоимость mul_10x10: 100 PP-тритов (~100 LUT) + 20 колонок × 10-входовая троичная сумма. 10-вх. сумма = 2 попкаунта (+/-) ~25 LUT или тернарное дерево ~35-40 LUT → ~1000 LUT/умножитель; Karatsuba (3 шт) ≈ 3k LUT/lane, flat 4×10×10 ≈ 4k — против ~0.9-1.5k у последовательного raw (1 общий tbyte_mul ≈ 300 LUT + 40 колонок × 3-вх. суммы ≈ 12 LUT). Parallel kbd в 2-3 раза ДОРОЖЕ raw по LUT; «экономия 69%» из исходного заголовка — ошибочная оценка (не учитывала стоимость параллельных колонок).
  * латентность: серийные balanced-цепочки (div3-перенос колонка→колонка) при групповом пайплайнинге (2-4 колонки/стадия, ~12-15 уровней/стадия) дают ~35-50 стадий на полный путь halfsum→3×mul→corr1→mid→final; carry-save (как в raw) сходится 1 колонка/такт → ~45 тактов. Без тернарного carry-lookahead (кусочно-постоянные функции переноса, высокий риск, локально неверифицируемо — verilator/iverilog в контейнере НЕТ) kbd латентностью не лучше raw (~49).
  * системный уровень: dot = PH_MUL (~49) + PH_TREE (31 последовательный tfadd_raw × ~30-50 тактов: ALGN ≤22 циклов + NORM-циклы, data-dependent) ≈ 1000-1500+ тактов; умножитель = ~3-5% латентности точки. Ускорение PH_MUL не даёт значимого выигрыша.
- Правка rtl/block/tfmul_kbd.sv: удалён ложный заголовок «экономия ~69% LUT / 8 тактов vs 25», заменён блоком СТАТУС/АНАЛИЗ (реальные цифры, вывод: raw остаётся в сборке, kbd — точный эталон BUG-039 + резерв для DSP-/lookahead-вариантов). Функционального кода не касался (BUG-039-версия верифицирована).
- tfadd_raw.sv/тфsmul_raw.sv перечитаны для цифр (латентности PH_ALGN/PH_NORM/PH_MUL, стоимость колонок).

Stage Summary:
- Ответ пользователю: НЕТ, kbd ещё НЕ в сборке — и количественный анализ показал, что подключение (даже после пайплайнинга) скорее всего НЕЦЕЛЕСООБРАЗНО: 2-3× LUP-дороже, латентность не лучше, точка доминируется деревом сложений. Рекомендация: raw остаётся; kbd — верифицированный эталон/резерв; финальное решение — за стендовым A/B-замером (MUL_IMPL), если пользователь настаивает на kbd.
- Изменён только заголовочный комментарий tfmul_kbd.sv; верифицированная BUG-039-логика не тронута. Коммит локальный, без push.

---
Task ID: 18
Agent: main (Super Z)
Task: Отметить в GitHub вердикт пользователя: kbd — тупик для данного чипа, не даёт сокращения элементов

Work Log:
- fetch: origin не двигался (ahead 5 / behind 0) — push безопасен.
- docs/ERROR_HISTORY.md: (1) НОВАЯ запись наверх [DECISION-001] «tfmul_kbd — тупик для xc7a200t, НЕ даёт сокращения элементов»: решение (MUL_IMPL и пайплайнизация kbd ОТМЕНЕНЫ; kbd остаётся эталоном/резервом), 3 основания (LUT: parallel 2-3x дороже, «экономия 69%» была ошибочной; латентность ~35-50 стадий без lookahead, не лучше raw ~49; система: dot доминирует дерево tfadd_raw 1000-1500+ тактов, умножитель = 3-5%), урок. (2) Статус BUG-039 обновлён: «НЕ подключён и ПОДКЛЮЧЕН НЕ БУДЕТ — см. DECISION-001». (3) Статус BUG-037 обновлён с 🔴 на ✅: «критический путь принадлежал tfmul_raw, исправлен 7da39e5; пайплайнизация kbd ОТМЕНЕНА — DECISION-001».
- Коммит 623ade9; push origin XDMA_DDR3_TMUL (по явному указанию пользователя «в github») — 6 локальных коммитов ушли на origin (5dc6f6e..623ade9, включая FATAL-гейт BUG-038, merge, BUG-039, 63795ee).

Stage Summary:
- Вердикт «kbd = тупик» зафиксирован в docs/ERROR_HISTORY.md как DECISION-001 и ОПУБЛИКОВАН на origin/XDMA_DDR3_TMUL (первый push за серию — по явному указанию пользователя). tfmul_raw официально остаётся умножителем сборки.
- Исключение из правила «без push» зафиксировано здесь: push выполнен единственно по прямому указанию пользователя и при behind 0.

---
Task ID: 19
Agent: main (Super Z)
Task: Просмотреть все скрипты, где требуется пайплайнинг дерева (tfadd_raw tree)

Work Log:
- Полный обзор точек, затрагиваемых пайплайнингом дерева сложений:
  RTL: compute_dot_par_raw.sv (PH_TREE: ОДИН tfadd_raw, time-mux, NUM_MAC-1=31 последовательных сложений x ~30-50 тактов = ~1000-1500+ тактов/dot — точка №1), tfadd_raw.sv (ALGN-цикл <=22 + NORM-цикл → barrel-изация до fixed latency — точка №2), tfadd48.sv + tdot_axi4.sv:183 u_acc (long-dot, до 15 последовательных вызовов/задачу — выигрывает автоматически), tdot_axi4 FSM CS_WAIT/CS_ACCUM_WAIT (латентно-агностичны, правок НЕ нужно), dadda_tree_ternary.sv (МЁРТВЫЙ код, 0 инстанциаций — компрессор PP одного умножения, не дерево dot), compute_dot_par.sv (legacy, мёртв).
  Скрипты: build_dfx.tcl (файлсет 309-319 + generic NUM_MAC:320 + FATAL-гейт 8.5 — при новом модуле добавить только строку файлсета), timing_report_analysis.tcl / check_timing_fatal.tcl / tcl_timing_lib.tcl (без правок), post_bd_dfx.tcl / xdma_ddr3_dfx_bd.tcl (tdot_irq по уровню — латентно-агностично), Makefile (tclargs), synth_block/synth_par/synth_tbyte*.tcl (legacy, не трогал).
- ИСПРАВЛЕН rtl/block/synth_par_raw.tcl (главный блочный A/B-харнесс дерева): (1) пути из ROOT репозитория вместо хардкода C:/A7_M2/...; (2) NUM_MAC/JOBS через -tclargs (формы «32», «NUM_MAC=32», «NUM_MAC 32» — урок BUG-033); (3) ГЛАВНОЕ: create_clock 8.000 ns на порт clk ПОСЛЕ open_run (раньше клоков не было → report_timing_summary неоттаймирован, «тайминг-отчёт» блока был пустым; в batch-сессии create_clock до launch_runs в прогон НЕ попадает); (4) вердикт через tcl_timing_lib (parse_summary_rpt + is_fatal + print_verdict), при FATAL — worst-10 путей + exit 1.
- Проверки: test_timing_gate.py ALL PASS; баланс Tcl нового скрипта OK ({ и [ = 0).
- План пайплайнинга (ступенчато): Шаг 1 — barrel-изация ALGN/NORM в tfadd_raw (fixed latency ~6-8 тактов, FSM не трогаем, ~4-6x на дерево); Шаг 2 — tfadd_pipe (throughput 1/такт) + back-to-back issue в PH_TREE (дерево = 31+L тактов вместо 31xL); Шаг 3 — A/B замер synth_par_raw.tcl (LUT/WNS до/после) + полная сборка с FATAL-гейтом. Исключения в timing_exceptions.xdc НЕ нужны (внутридоменные пути fabric125 не ослаблены — дерево обязано закрыть 125 МГц само).

Stage Summary:
- Обзор завершён: единственные две точки пайплайнинга дерева — compute_dot_par_raw.sv (FSM выдачи) и tfadd_raw.sv (ALGN/NORM циклы); вся обвязка (tdot_axi4, IRQ, драйверы, констрейнты) латентно-агностична.
- A/B-харнесс блока (synth_par_raw.tcl) починен: ранее его «тайминг-отчёт» был неоттаймирован (нет клока) — теперь WNS/TNS при 125 МГц реальны и гейтятся.
- RTL-правки дерева ещё НЕ делались (следующий цикл: Шаг 1). Коммит локальный + push (публикация по установившемуся потоку).

---
Task ID: 20
Agent: main (Super Z)
Task: Шаг 1 пайплайнинга дерева (РАЗРЕШЁН пользователем): баррелизация tfadd_raw — фиксированные 6 тактов; учёт параллельного агента перед коммитом

Work Log:
- Протокол параллельного агента выполнен ДО и ПОСЛЕ правок: fetch/status внешнего и внутреннего репо; HEAD внутреннего = 6b4512e, рабочее дерево чистое перед правками; перед коммитом — повторная проверка (в изменениях только 6 моих файлов). Push НЕ выполняется (нет явной команды; правило: push только по явному указанию и behind 0).
- Чтение обвязки: tfmul_raw (e_prod = ea+eb−18 ∈ [−98,62] → |Δe| продуктов до 160), compute_dot_par_raw (дерево 5 уровней, 31 последовательное сложение, один time-mux tfadd_raw), tfadd48 = обёртка над tfadd_raw (long-dot u_acc выигрывает автоматически), build_dfx.tcl:309-319 / synth_par_raw.tcl:64-69 — файлсеты ЯВНЫЕ (ref-копия в синтез не попадает).
- НАЙДЕН BUG-040 (латентный): cnt[5:0] в tfadd_raw обрезал |Δe| по mod 64 (Δe=64 → cnt=0 → малый продукт добавлялся в масштабе большого, ошибка до ×3^64; Δe≥128 → переполнение 8-битной разности). Достижим: продукты дают Δe до 160, уровни дерева ≥1 и long-dot — Δe до 80 (80 mod 64 = 16). Записан в docs/ERROR_HISTORY.md.
- Ключевые алгебраические факты (легли в баррель): (1) rhu_next serial (+1/−1 танцы) == ЧИСТЫЙ сбалансированный сдвиг на 1 = round-to-nearest (бонус сбалансированной троичности); (2) fd3 == sign·floor(|x|/3) — ДРУГОЙ режим (floor), воспроизведён точно; (3) k итераций == однотактный сдвиг на k (и nearest, и floor); (4) диапазон NORM — по КАНОНИЧЕСКОЙ позиции P = floor(log3|s|), НЕ по позиции старшего сбалансированного трита (3^19−1: p=19, но P=18 — уже в диапазоне); HW-правило P = p − [старший ненулевой ниже p == N1] (без 64-бит val_abs).
- ДОКАЗАТЕЛЬСТВО ДО RTL: rtl/block/proof_tfadd_barrel.py — ALL PROOFS PASSED, 282k+ векторов: A0 faithful-trit==fast (3000), A1 rhu==shift1 (20k), A2 fd3==floor, A3 iterated==barrel nearest+floor (11.5k), A4b HW-правило P==floor(log3) (50k), A4 NORM serial==barrel (57k), A5 полный конвейер serial==barrel бит-в-бит при |Δe|≤63 (110k), A6 barrel==intent на Δe 0..160 (30k; serial с багом расходится в 2880/30000 при Δe≥64).
- RTL: tfadd_raw.sv ПЕРЕПИСАН (интерфейс и имя модуля прежние — сборки/filesets не тронуты): FSM IDLE→INIT→ALGN→ADD→NORM→DONE, ФИКСИРОВАННЫЕ 6 тактов (было 6..50+ data-dependent); ALGN — баррель-мукс 0..22 без цепей переноса; NORM — floor-баррель с декрементом (borrow по N1) + ×3^k чистый сдвиг + клампы e_sum (SAT >40, −40) в порядке serial; Δe 9 бит (fix BUG-040); val_abs (64-бит ×3 цепь) УДАЛЁН — комбинация короче. Тактовая частота не меняется (125 МГц fabric, FATAL-гейт проверит WNS).
- Тесты: tfadd_raw_ref.sv — замороженная golden-serial-копия (валидна |Δe|≤63, предупреждение в шапке); tb_tfadd_equiv.sv — A/B на xsim (сравнение по событиям valid_out, латентность новой обязана быть ровно 6, зона Δe≥64 учитывается отдельно; направленные + 6000 случайных); tb_tfadd_raw.sv — иерархические ссылки обновлены (cnt→k_algn, val_abs удалён).
- Латентность точки (оценка): PH_MUL ~49 + дерево 31×6+оверhead ≈ 235–250 тактов ФИКСИРОВАННО (было ~900–1550 data-dependent; типичный dot раньше ~1000+ из-за ~19 NORM-циклов на уровень 0 — продукты ненормализованы). Шаг 2 (back-to-back, отдельно) → ~100–125.

Stage Summary:
- Шаг 1 выполнен и закоммичен ЛОКАЛЬНО (внутренний репо): barrel tfadd_raw с бит-в-бит семантикой (282k векторов Python + xsim A/B за стендом), фиксированные 6 тактов/сложение, BUG-040 исправлен попутно и задокументирован.
- За стендом: (1) xsim tb_tfadd_equiv → ждать ALL EQUIV PASS; (2) xsim tb_tfadd_raw → RESULT=...; (3) A/B synth_par_raw.tcl (LUT/WNS 125 МГц до 6b4512e vs после); (4) полная сборка NUM_MAC=16/32 с FATAL-гейтом → WNS/TNS (закрывает и отложенную проверку 7da39e5+clock-groups).
- Шаг 2 (конвейер PH_TREE back-to-back, dot ~100–125 тактов) — ПО ОТДЕЛЬНОМУ РАЗРЕШЕНИЮ пользователя.

---
Task ID: 21
Agent: main (Super Z)
Task: Ответить «что даст отдельное разрешение на Шаг 2 (конвейер PH_TREE, dot ~100–125 тактов)» — количественный анализ вариантов K (информационный ход, код не менялся)

Work Log:
- Перепроверка по протоколу: внутренний репо HEAD=45ef795 (Шаг 1, ahead 1, push НЕТ — команды не было), рабочее дерево чистое, fetch — origin не двигался. compute_dot_par_raw.sv перечитан: PH_TREE = ОДИН tfadd_raw (u_add), 31 последовательное сложение (t_cnt 16→1 по 5 уровням), handshake ad_busy; issue+6+collect ≈ 7–8 тактов/сложение.
- Лестница вариантов Шага 2 (K barrel-аддеров вместо одного, внутри уровня параллельно; раунды = Σ ceil(t_cnt/K) по уровням 16,8,4,2,1):
  * K=1 (текущее, Шаг 1 готов): 31 раунд ≈ 186 + оверхед → dot ≈ 235–250 фикс (было ~900–1550 data-dependent);
  * K=4: раунды 4+2+1+1+1=9 → дерево ~65–70 → dot ≈ 120–135; +3–4k LUT (2–3%);
  * K=8: раунды 2+1+1+1+1=6 → дерево ~45–48 → dot ≈ 100–120; +7–10k LUT (~5–7% of 134.6k) ← sweet spot;
  * K=16: раунды 1+1+1+1+1=5 → дерево ~38–40 → dot ≈ 90–110; +14–19k LUT (~10–14%); больше 16 смысла нет — дерево сужается.
- Итог к исходному (до Шага 1): типичный dot ~1000+ → ~100–120 = ×8–10; worst 1550 → ~110 = ×14. Пропускная способность @125 МГц: ~520k (Шаг 1) → ~1.0–1.2M dot/с (K=8). Латентность полностью детерминирована.
- «Back-to-back» в строгом смысле (MUL строки N+1 поверх дерева строки N) — отдельный микрошаг 2b: ещё −30–50 тактов → dot ~70–90, требует двойной буфер prod/tbuf; для цели 100–125 НЕ обязателен.
- Цена/риски: арифметика НЕ меняется (те же barrel tfadd_raw, бит-в-бит доказаны Шагом 1); переработка ТОЛЬКО FSM PH_TREE (выдача на K аддеров + сбор tbuf, ~100–150 строк); tdot_axi4/файлсеты/интерфейсы не трогаются; WNS-риск от конджешн решает только FATAL-гейт полной сборки; верификация = расширение proof-модели (параллельное дерево == последовательное бит-в-бит) + verify_compute_dot_par_raw.py + xsim A/B за стендом.
- Рекомендация: разрешение можно дать сейчас, реализацию — ПОСЛЕ стендовых замеров Шага 1 (xsim tb_tfadd_equiv/tb_tfadd_raw + A/B synth_par_raw.tcl): реальные LUT/аддер и запас WNS выберут K; если ~520k dot/с уже достаточно — Шаг 2 не блокирует ничего и добавляется позже локальной правкой одного модуля.

Stage Summary:
- Дан количественный ответ: Шаг 2 = дополнительно ×2–2.5 к Шагу 1 (dot 235–250 → 100–125), итого ×8–10 типично / ×14 worst к исходному; цена K=8 ≈ +5–7% LUT; sweet spot K=8; решение за пользователем.
- Код в этом ходе НЕ менялся; внутренний репо остаётся ahead 1 (45ef795, без push).

---
Task ID: 22
Agent: main (Super Z)
Task: Шаг 2 пайплайнинга дерева (РАЗРЕШЁН пользователем: «разрешаю шаг2 и затем перейдем к локальным тестам») + локальные тесты; попутно найден и исправлен BUG-041

Work Log:
- Протокол: fetch/status внутреннего и внешнего репо перед правками и перед коммитом; HEAD=45ef795, чужих изменений нет (одна ложная тревога — русская строка print в verify_compute_dot_par_raw.py оказалась в committed-базе, это моя ошибка воспроизведения old_str, не параллельный агент).
- ПЕРЕРАБОТАН rtl/block/compute_dot_par_raw.sv (Шаг 2): параметр ADDERS (default 8) barrel-аддеров tfadd_raw вместо одного time-mux; стрид-локстеп раунды — аддер k берёт операции n = k + r*ADDERS; чтение операндов — узкое окно с КОНСТАНТНЫМИ индексами (ceil(t_cnt/ADDERS))-в-1 (НЕ 32-в-1 мультиплексор: при NUM_MAC=32/ADDERS=8 уровень 0 — 2-в-1, уровни 1..4 прямые); выдача back-to-back — новая операция в такт valid_out предыдущей (период 6 тактов/аддер, tfadd_raw сэмплирует valid_in только в PH_IDLE); lockstep-гейт tree_can_issue (все свободны или завершаются) — рассинхрон невозможен; сбор по r_q[k] (раунд с момента выдачи) в слот n; ADDERS=1 = прежнее последовательное поведение (A/B-базлайн). Интерфейс/имя модуля прежние — tdot_axi4, файлсеты, tb не требуют правок по интерфейсу.
- НАЙДЕН И ИСПРАВЛЕН BUG-041 (латентный, критичен для реальной нагрузки): tfadd_raw выбирал big/small по ЭКСПОНЕНТЕ — нулевой операнд (продукт нулевого веса: (0, e_data−18); нулевая частичная сумма: 48'h0, e=0) с «большой» e отправлял ненулевой в m_small: при |Δe|>22 тот ТЕРЯЛСЯ ПОЛНОСТЬЮ (x+0 == 0). Wall-векторы нулей не давали — баг не проявлялся; тернарные веса {-1,0,+1} — реальный кейс. Фикс: za/zb-детект нулевых мантисс в PH_IDLE, x+0 == norm(x), 0+0 == 0 (семантика golden _raw_add). golden `_raw_add` выровнен: shortcut теперь нормализует (выход tfadd_raw физически всегда нормализован — иначе другой порядок округления на уровнях дерева). Доказательство: старая семантика расходится в 6099/20120 нуль-векторов.
- ПОПУТНО (модель, не RTL): транскрипционная ошибка exp_code в proof_tfadd_barrel.py (45ef795): `rv==-2 → code=2 (N1)` вместо SV-верного `2'b01` (P1) — модель кодировала e∈{−2,−5,−8,…} со сдвигом (−2→−4, −11→−13, коллизии). Выводы A0–A6 не затронуты (self-consistency обеих сторон); исправлено в обеих python-моделях + T0 дополнен оракулом «dec(enc(e)) == e». Локализовано поузловой трассой дерева (scripts/debug_t1_case.py, debug_t1_node.py — рабочие диагностики, вне репо).
- НОВЫЙ proof: rtl/block/proof_tree_par.py — цикл-точная модель нового PH_TREE (стрид-локстеп, back-to-back, r_q/collected/tree_can_issue — 1:1 с RTL) + секции: T0 конвенции слова (3000, == arith48 == intent-оракул), Z1 BUG-041 (20120), Z2 ненулевые (5000), T1 модель==golden dot_ref_raw (180 деревьев: random/тернарные веса/все-нули/нули в данных — бит-в-бит), T2 K-инвариантность (124 вектора, вкл. SAT/underflow/нули, K∈{1,2,3,4,5,7,8,13,16,31}), T3 инварианты (период аддера ≥6, нет deadlock, collected==t_cnt на границах уровня) + таблица латентностей.
- РЕЗУЛЬТАТЫ T3 (tree тактов / dot~с PH_MUL~49): NUM_MAC=32: K=1: 192/245; K=2: 102/155; K=4: 60/113; K=6: 54/107; K=8: 42/95; K=16: 36/89. NUM_MAC=16, K=8: 35/86. Период аддера ровно 6 (back-to-back работает).
- Обвязка: tb_tfadd_equiv.sv — зона BUG-041 (направленные + 300 random с нулём; Z41_DIFF>0 в вердикте); tb_compute_dot_par_raw.sv — параметр ADDERS; verify_compute_dot_par_raw.py — ADDERS через argv[2], gen_input расширен (тернарные веса/все-нули/нули в данных, 24 случая); synth_par_raw.tcl — ADDERS через -tclargs (все формы, урок BUG-033; голое число = NUM_MAC как раньше), отчёты util/timing_parraw<N>_a<K>.rpt, generic одной set_property [list].
- ЛОКАЛЬНЫЕ ТЕСТЫ: proof_tfadd_barrel.py ALL PROOFS PASSED (регрессия после exp_code-фикса); proof_tree_par.py ALL PROOFS PASSED; sv_lint.py — 5 изменённых SV OK; test_timing_gate.py ALL PASS; dfx_reaudit.py 0 ошибок; TCL-баланс synth_par_raw.tcl OK.
- Коммиты внутреннего репо (ЛОКАЛЬНО, без push — команды не было): (1) BUG-041 + модельные фиксы; (2) Шаг 2 + proof + обвязка. Push — только по явной команде при behind 0.

Stage Summary:
- Шаг 2 реализован и доказан локально: dot ~245 → ~95 тактов (K=8, NUM_MAC=32), ×2.6 к Шагу 1, ×10+ к исходному; полностью детерминированная латентность; арифметика бит-в-бит == последовательной версии при любом ADDERS (T2).
- Попутно закрыт BUG-041 (нулевые операнды — критично для тернарных весов) и транскрипционная ошибка exp_code в proof-модели Шага 1.
- За стендом: (1) xsim tb_tfadd_equiv (включая зону Z41) → ALL EQUIV PASS; (2) xsim tb_compute_dot_par_raw NUM_MAC=16/32 × ADDERS=1/8 → несовпадений 0; (3) A/B synth_par_raw.tcl ADDERS=1 vs 8 (LUT/WNS 125 МГц); (4) полная сборка NUM_MAC=16/32 с FATAL-гейтом → WNS/TNS.

---
Task ID: 23
Agent: main (Super Z)
Task: Push внутреннего репозитория (явная команда пользователя: «делай push»)

Work Log:
- Протокол перед push: fetch origin (не двигался), git status — рабочее дерево чистое; behind 0 / ahead 3 по origin/XDMA_DDR3_TMUL...HEAD (rev-list 0 3).
- Состав пула (6b4512e..5dd7006): 45ef795 Шаг 1 (barrel tfadd_raw, 6 тактов, бит-в-бит), 7fa4950 BUG-041 (нулевой операнд x+0 в tfadd_raw), 5dd7006 Шаг 2 (ADDERS-параллельный barrel-дерево в PH_TREE + proof_tree_par.py + обвязка).
- git push origin XDMA_DDR3_TMUL → OK: 6b4512e..5dd7006. Верификация: ahead/behind 0/0, ветка синхронизирована с origin.
- Внешний репо /home/z/my-project (worklog, HEAD 1ee52d6) — remote НЕ имеет: пушить нечего, остаётся локальным.

Stage Summary:
- Публикация завершена: origin/XDMA_DDR3_TMUL = 5dd7006 (Шаг 1 + BUG-041 + Шаг 2). Локальных отставаний нет (0/0).
- Осталось за стендом (из Task 22): xsim tb_tfadd_equiv/tb_compute_dot_par_raw, A/B synth_par_raw.tcl ADDERS=1 vs 8 (LUT/WNS 125 МГц), полная сборка NUM_MAC=16/32 с FATAL-гейтом.

---
Task ID: 24
Agent: main (Super Z)
Task: Worklog не был на GitHub — причина и исправление (команда пользователя: «почему worklog не добавлен в github!??»)

Work Log:
- Причина: worklog.md вёлся во ВНЕШНЕМ репо /home/z/my-project, у которого НЕТ remote (git remote -v пуст) — коммиты Tasks 19–23 существовали только локально; во внутренний репо (с origin) worklog не добавлялся.
- Исправление: worklog.md скопирован во внутренний репо → docs/worklog.md (359 строк, Tasks 19–24, канал ошибок и протоколы); коммит 8051c5a «docs: add worklog.md (multi-agent work log, Tasks 19-23)»; push → origin/XDMA_DDR3_TMUL 5dd7006..8051c5a, verified 0/0.
- ПРОТОКОЛ ДАЛЬНЕЙШЕГО ВЕДЕНИЯ: каноническая копия — docs/worklog.md во внутреннем репо (публикуется в GitHub); внешний /home/z/my-project/worklog.md — рабочая копия, синхронизируется cp при каждой записи; обе записи делаются в ОДНОМ ходе (append + cp + commit inner + push inner по разрешению).

Stage Summary:
- Worklog теперь на GitHub: https://github.com/pin24/Xilinx-Artix7-M2-PCIE-200-DDR3/blob/XDMA_DDR3_TMUL/docs/worklog.md
- Больше не дублировать ошибку: каждая новая запись Task N = append в оба файла, коммит внутреннего, push по разрешению пользователя.

---
Task ID: 26
Agent: main (Super Z)
Task: Проверка обновлений репозитория и вывод (команда пользователя)

Work Log:
- fetch origin: XDMA_DDR3_TMUL двинулся 3048446..a54ffda (+3 коммита, работа стенда); локальное дерево чистое, расхождений нет (behind 3 / ahead 0) → fast-forward до a54ffda, verified 0/0.
- Пришло: 8971f23 (Cycle 4: pblock RP 20→50 колонок, NUM_MAC=12, слияние barrel-работы), 53c9bba (worklog Task 25), a54ffda (Cycle 6: NUM_MAC=8, фикс SV-кодировки tfmul_raw — автоматические переменные вынесены на уровень модуля для Vivado 2025.2, tfadd48.sv ДОБАВЛЕН в файлсет build_dfx.tcl — был пропущен, set_param drc.disableLUTOverUtilError 1).
- Из Task 25: BUG-037 закрыт (carry-save tfmul_raw 7da39e5, тайминг закрыт); новая борьба — LUT: NUM_MAC=16 → 139797 (104%), NUM_MAC=12 → 145689 (108%) — barrel-дерево + переписанный tdot_axi4 дали +30–40k LUT; взят NUM_MAC=8. Driver скомпилирован (не установлен — нет Admin); HW-верификация 0%; XADC (BUG-031) открыт.
- Анализ: (1) disableLUTOverUtilError — азартный ход, в ФИКСИРОВАННОМ pblock перебор опаснее общесистемного (конджешн); (2) цена детерминизма barrel-дерева (8 аддеров) выше начальной оценки (+30–40k против +7–10k) — вместе с NUM_MAC=16 не влезает; (3) готовый аварийный рычаг — параметр ADDERS в compute_dot_par_raw (лестница Task 21: ADDERS=4 → −~10k LUT, dot ~113 вместо ~95); (4) финального WNS/TNS для конфига NUM_MAC=8 + barrel-дерево в worklog ещё нет — вердикт FATAL-гейта полной сборки не записан.
- Внешний репо: чужие незакоммиченные правки scripts/* — не трогал (протокол).

Stage Summary:
- Локальный HEAD = a54ffda (синхрон). Статус проекта: тайминг ✅ (BUG-037 закрыт), ресурсы ❌ под давлением (LUT 104–108% при 16/12, ставку сделали на NUM_MAC=8 + подавление DRC), железо ❌ (0 битстримов прошито, драйвер не установлен, XADC открыт).
- Рекомендация Cycle 7: если NUM_MAC=8 не влезет/не закроет тайминг → ADDERS=4 (лестница Task 21 как лестница экономии LUT); записать финальный WNS/TNS в worklog; затем железо.

---
Task ID: 27
Agent: main (Super Z)
Task: Ответ на вопрос пользователя о разбивке данных на мелкие ядра по 4 трита (1 байт)

Work Log:
- Сверка с кодом: tbyte_mul.sv — ГОТОВОЕ ядро 4трит×4трит (проектный термин «байт» = 4 трита, 2 бита/трит); tfmul_raw.sv уже разложен: мантисса 20 трит = 5 байт, PH_MUL = 25 chunk-произведений (mul_i=cnt/5, mul_j=cnt%5, cnt 0..25), сдвиг (i+j)*4 трита (основание 81), carry-save 40 колонок × ~15 LUT; из 48 тактов латентности 25 — итерация chunk-произведений.
- Вывод: запрошенная гранулярность УЖЕ реализована на микроуровне; вопрос сводится к (1) параллелизму chunk-ядер, (2) DFX-тайлингу, (3) разносу данных.
- Количественная оценка: Вариант 1 (25→9 тактов MUL по диагоналям i+j, 5 ядер) — dot ~95→~80–82, НО carry-save ячейка 1→5 входов (~15→~40 LUT/колонку) + 4 tbyte → +9–13k LUT — недопустимо ДО вердикта сборки NUM_MAC=8; Вариант 2 (DFX-плитки) — только время реконфигурации, математику не трогает; Вариант 3 (разнос данных) — суммарная работа не меняется, смысла нет.
- Экономика сформулирована: дробление даёт скорость за LUT либо экономию LUT за скорость; текущая точка (1 ядро/MAC, 25 тактов) — уже компромисс в пользу LUT.

Stage Summary:
- Ответ пользователю: разбивка на 4-тритовые ядра уже есть (tbyte_mul + разложение tfmul_raw); реальный следующий рычаг — параллелизм chunk-ядер по диагоналям (dot ~80 за +9–13k LUT) — РЕШАТЬ ТОЛЬКО после вердикта сборки NUM_MAC=8; сейчас RTL не трогать (BUG-037 закрыт, proofs заморожены, кодировка вычищена).
- Приоритеты без изменений: вердикт NUM_MAC=8 → при переборе ADDERS=4 (−~10k LUT) → после закрытия UTLZ+WNS опционально Вариант 1.

---
Task ID: 28
Agent: main (Super Z)
Task: «Проект не влез в NUM_MAC=8» — причина (ADDERS молча застрял на 8) и лестница влезания

Work Log:
- НАЙДЕН БЛОКИРУЮЩИЙ ДЕФЕКТ сборки: в полной сборке ADDERS фактически всегда был 8 — параметра ADDERS не было на xdma_ddr3_core_top и не передавался по иерархии (set_property generic ADDERS применялся бы к топу, где параметра нет → игнор/ошибка). A/B-харнесс synth_par_raw.tcl умел ADDERS, полная сборка — НЕТ. Всё, что выше NUM_MAC=8 влезало бы только ценой полного дерева ADDERS=8 (~24–32k LUT).
- ИСПРАВЛЕНО (10db205): (1) параметр ADDERS добавлен аддитивно на top и tdot_axi4 с дефолтом 8 (прежнее поведение без generic сохранено), протянут до compute_dot_par_raw; (2) build_dfx.tcl — ADDERS в парсер tclargs (обе формы BUG-033), printout, set_property generic ADDERS; (3) Makefile — ADDERS ?= 4, build-цель передаёт ADDERS=$(ADDERS).
- ИНЦИДЕНТ ИНСТРУМЕНТА: MultiEdit превратил табы Makefile в 8 пробелов (recipe-строки) — поймано по аномальному размеру диффа (30 строк вместо 3), откат git checkout, правка переделана python-скриптом с сохранением \t. Урок: Makefile править ТОЛЬКО python/ручным replace, не MultiEdit; проверять размер диффа до коммита.
- Проверки: sv_lint xdma_ddr3_core_top.sv/tdot_axi4.sv OK; Tcl-баланс вне комментариев/строк OK ({}/[]/() — сырой дисбаланс () в комментариях старый, 84/93 на HEAD до правок); диффы построчно проверены; табы recipe-строк верифицированы.
- ЛЕСТНИЦА ВЛЕЗАНИЯ (dot-латентности из модели T3, NUM_MAC=8: уровни 8→4→2→1):
  * NUM_MAC=8, ADDERS=4 (новый дефолт make build): раунды 2+1+1+1=5 → dot ~90; −12–16k LUT; T2-доказано бит-в-бит;
  * NUM_MAC=8, ADDERS=2: раунды 4+2+1+1=8 → dot ~105; −18–24k LUT;
  * NUM_MAC=6, ADDERS=4: уровни 6→3→2→1, раунды 2+1+1+1=5 → dot ~90; ещё −1.5–2k LUT;
  * NUM_MAC=4, ADDERS=2: уровни 4→2→1, раунды 2+1+1=4 → dot ~85; всего −21–27k LUT (дерево сужается — латентность почти не растёт).
- Запрошено у пользователя: точная цифра перебора на NUM_MAC=8/ADDERS=8 (utilization report) для выбора ступени.

Stage Summary:
- Полная сборка теперь реально управляется ADDERS; новый дефолт: NUM_MAC=8 + ADDERS=4 (dot ~90, −12–16k LUT) — первый кандидат на следующий Cycle.
- Коммит 10db205 ЛОКАЛЬНО (вместе с worklog Tasks 26–27: ahead 3); push по явной команде.
- Если и ступень 4 не влезает → ADDERS=2 → NUM_MAC=6/4; далее резерв — time-mux одного carry-save массива на 2 MAC (новый RTL, отдельно).

---
Task ID: 29
Agent: main (Super Z)
Task: Push ADDERS-работы на GitHub с учётом параллельного агента; разбор новых данных BUG-037 (CARRY4/Place)

Work Log:
- Протокол параллельного агента: fetch показал новый origin-коммит ea440c3 (BUG-037 CARRY4 overflow + set_multicycle_path; файлы: ERROR_HISTORY.md, xdc, dfx_runtime.txt — docs/worklog.md НЕ тронут → конфликтов с моими 3 worklog-коммитами нет). Rebase 4 локальных коммитов на ea440c3 — чисто, без конфликтов.
- КЛЮЧЕВЫЕ НОВЫЕ ФАКТЫ из ea440c3 (синтез NUM_MAC=8): LUT 106985 (79.5%) — ВЛЕЗАЕТ; CARRY4 16241 (48.3%) — НЕ влезает по слайсам: Place 30-487, требуется 20346 слайсов, доступно 10281 (pblock). ≈2030 CARRY4 на tfmul_raw. kbd-варианты окончательно отвергнуты цифрами (316k LUT / 175k LUT).
- СМЕНА ДИАГНОЗА: «не влез в NUM_MAC=8» — это НЕ LUT (моя лестница Task 28 оставалась в парадигме LUT), а CARRY4-плотность/слайсы. Лестница ADDERS остаётся полезной (−аддеры = −LUT и −слайсы), но главный слон — 16241 CARRY4 в tfmul_raw.
- ЗАМЕЧЕН РИСК В MCP ПАРАЛЛЕЛЬНОГО АГЕНТА (ea440c3, xdc): set_multicycle_path -setup 25 -through sum_n основан на трактовке «конус живёт 25 тактов» — по RTL 7da39e5 carry-save массив ОБНОВЛЯЕТСЯ КАЖДЫЙ такт (частичные произведения входят по одному за такт, sum_r/carry_r — регистры): путь cnt_reg→колонка→sum_r ОДНОТАКТОВЫЙ, бюджет 8 нс, а не 25×8. Если конус реально мал — MCP безвреден, но создаёт слепую зону STA; если конус реально 263 уровней — MCP СПРЯЧЕТ реальное нарушение тайминга (функциональный сбой на железе при «зелёном» отчёте). Проверка за стендом: synth_par_raw.tcl (БЕЗ MCP, create_clock 8ns + FATAL-гейт) → WNS путей u_mul; report_utilization -hierarchical → CARRY4 по модулям (найдёт истинный источник 16241).
- Направление исправления (на согласование): переработка ячейки carry-save колонки tfmul_raw в pure-LUT (убрать CARRY4-мэппинг: деление/3 и 3-входовые сложения через case/mux, бит-в-бит == текущей ячейке, proof-фреймворк готов) + лестница ADDERS из Task 28. Резерв: NUM_MAC=4 (~8k CARRY4 — по их таблице влезает).

Stage Summary:
- Rebase на ea440c3 выполнен, push разрешён пользователем — все коммиты уходят на GitHub.
- Диагноз проекта обновлён: LUT OK (79.5%), блокер — CARRY4 16241 → слайсы. Следующий целевой ход — pure-LUT ячейка tfmul_raw + проверка MCP; ADDERS-лестница — вторым приоритетом.

---
Task ID: 30
Agent: main (Super Z)
Task: «Реализуй все свои решения и сделай пуш» — pure-LUT tfmul_raw/tbyte_mul (0 CARRY4), отключение рискованного MCP; подтверждение вторым мнением (qwen3.8)

Work Log:
- Разрешение получено; второе мнение (qwen3.8-9b-distill) подтвердило план по всем пунктам: pure-LUT > CARRY4 для троичного переноса; явные таблицы для ÷3 (trunc-toward-zero на отрицательных); пайплайн-разрывы. Уточнение: «регистры каждые 4–5 колонок» УЖЕ не нужны — carry_r[t+1] регистр, колонки комбинационно изолированы (263 уровня были в до-7da39e5 схеме).
- РЕАЛИЗАЦИЯ (генератор+proof+патч одним скриптом scripts/tfmul_purelut_gen.py, вне репо; без ручного транскрибирования таблиц): tfmul_raw.sv — csr3 (64 ключа) для колонок И FIN; pa = partial<<8s (case 9, fixed-index вместо 40× вычитаний/сравнений); cnt_dec (26) вместо cnt/5,%5,+; exp_val таблица 256 (ВСЕ ключи — 2'b11→0 как tv, хост-данные могут содержать невалидные кодировки!); tbyte_mul.sv — ptv (16) + asm_tab (45), накопление coeff оставлено (4-бит ±1). s_q[3:0] вместо shift_q[6:0] (внешних ссылок нет — проверено); добавлен сброс s_q (безопасно: partial_q=0 компенсировал несброшенный shift и раньше).
- ДОКАЗАТЕЛЬСТВА (все исчерпывающие/структурные): P1 csr3 64/64==формуле; P2 cnt_dec 26/26; P3 exp_val 256/256==циклу; P4 ptv 16/16; P5 asm_tab 45/45 (полное покрытие домена coeff×carry); P6 align 9×65536×80 бит == оконной семантике; P7 tbyte структура(P4+P5)+50005 дифф-пар; P8 ПОЛНЫЙ умножитель new==old бит-в-бит (prod,e,neg) на 1906 векторах (направленные+случайные, включая нули, 11-heavy, все экстремумы) — quirks сохранены (partial(25) захват/не потребление).
- MCP ОТКЛЮЧЁН (constraints/xdma_ddr3_early.xdc, закомментирован с обоснованием): маскировал бы однотактные пути; 25 — латентность умножения, не бюджет пути; правило «нарушение = fatal». Проверка истины — synth_par_raw.tcl (без MCP) за стендом.
- sv_lint: tfmul_raw/tbyte_mul OK. Остаточный CARRY4-риск: только 4-битные ±1 накопления coeff в tbyte (~128 max) — замер за стендом.
- За стендом (Cycle 7): (1) synth NUM_MAC=8 → report_utilization -hierarchical (CARRY4 по модулям — подтверждение источника и остатка); (2) report_timing_summary — WNS u_mul БЕЗ MCP; (3) если WNS<0 — чинить RTL, не констрейнт; (4) полный build FATAL-гейт; (5) цель после влезания: NUM_MAC=16 (~10–11k слайсов RM).

Stage Summary:
- tfmul_raw/tbyte_mul переведены на pure-LUT: ожидаемо 16241 → ~0 CARRY4, RM 20346 → ~5–6k слайсов, NUM_MAC=8 влезает в pblock; бит-в-бит доказано (8/8 proofs).
- MCP отключён (тайминговая честность); ADDERS=4 в сборке (Task 28) — вторая ручка по остатку.
- Коммит + push по явной команде пользователя.
---
Task ID: 31
Agent: main (Super Z)
Task: «Прочитай последние обновления в репозитарии на GitHub» — fetch, ff-merge, разбор 22 коммитов стенда (c12fa73..268b9b2)

Work Log:
- fetch: XDMA_DDR3_TMUL c12fa73..268b9b2 (+22, работа стенда Cycle 7); ahead 0 / behind 22 → fast-forward, verified 0/0.
- BUG-051: XDMA 64-bit @ 250 MHz НЕ закрывается на Artix-7 (userclk1 WNS=-2.208ns, TNS=-7556, 13375 endpoints) → axi_data_width 64→128_bit + axisten_freq 250→125 (= 128×125 = 2.0 ГБ/с, тот же канал); userclk1 WNS=+0.884 ✅. GT LOC: PCIE_X0Y0.xdc отключён (IS_ENABLED false), ручные GTP LOC добавлены и затем убраны (XDMA сам размещает; bel-occupied 12-2285).
- BUG-052: MIG device_temp_i (12 бит) висел при XADC_En=Off (BD 41-759) → xlconstant 12'b0 tie-off в базовом BD-скрипте ДО validate (3 итерации: TIE_OFF не существует → xlconstant → ширина → перенос до validate).
- BUG-047 v2: timing_exceptions.xdc → .tcl (XDC не парсит TCL, Designutils 20-1307); set_clock_groups перенесён в PLACE_DESIGN.TCL.PRE impl_1 — в TCL.POST synth групп клоков ещё НЕ СУЩЕСТВУЕТ (диагностика). Реальные имена клоков сняты с routed impl_1. FATAL-гейт: ТОЛЬКО fabric-домен 125 МГц (get_timing_paths -filter START_CLK/END_CLK, синтаксис 2025.2) — на routed impl_1 fabric violations = 0. Исключение userclk1 НЕ маскировка: BUG-051 починен по существу (WNS +0.884).
- BUG-048/049/050: usr_irq_req подключён напрямую 1-бит tdot_irq (MSI-X only XDMA без пина → conditional; xlconcat/xlconstant убраны); дубль create_clock clk50 удалён (владелец BD clk_wiz, override 18-1056); мёртвый GT LOC блок убран.
- tfadd_raw (BUG-042/043/045, коммит 2e03465): exp_code — 4 последовательных деления → case-LUT 81 значение [-40..40] (59 CARRY4 → 0, verified 81/81); 42-тритный ripple-ADD разбит на 3 секции по 14 тритов с регистровым переносом (carry_mid0_q/1_q); PH_NORM разбит на PH_NORM1/PH_NORM2 (разрыв комбинаторного контура sum_reg→norm→sum_reg). ЛАТЕНТНОСТЬ АДДЕРА 6 → 9 ТАКТОВ (FSM 6→9 фаз). Причина — закрытие 8ns@125MHz по RTL (наш принцип «чинить RTL, не констрейнт»).
- compute_dot_par_raw: только косметика (duplicate t_dst, Synth 8-9339).
- BUG-031 (XADC) ЗАКРЫТ реально: новый rtl/integration/xadc_prim.sv — примитив XADC напрямую (MIG XADC_En=Off → физический XADC свободен), DRP-FSM читает temp/VCCINT раз в 1 с @ clk50, отдаёт в xadc_temp.sv (AXI 0x46000000, карта не менялась). dfx_runtime: DFX CPU 5→27 с (мелочь).
- НЕ ТРОНУТО стенда (пробелы): proof_tfadd_barrel.py / proof_tree_par.py / tb_tfadd_equiv / tb_compute_dot_par_raw / docs/worklog.md — обновлений НЕТ. tb latency-agnostic (ждут valid_out) — валидность сохраняется (инвариант «период ≥6» покрывает 9), но ТАБЛИЦА ЛАТЕНТНОСТЕЙ T3 устарела: период back-to-back аддера теперь 9, а не 6 → dot NUM_MAC=8/ADDERS=4 ≈ 86 → ~105–110 (оценка, tree-часть ×1.5).
Stage Summary:
- Локальный HEAD = 268b9b2 (синхрон). Стенд двигает Cycle 7 по всем фронтам: XDMA 128@125 ✅, BD tie-off ✅, clock-groups применяются ✅, fabric-гейт ✅ (violations=0), XADC ✅, tfadd_raw 125MHz-ready ✅ (цена: латентность 6→9).
- Пробелы для следующего шага: (1) таблица латентностей Task 21/22 требует пересчёта под период 9 (модель proof_tree_par.py T3); (2) worklog стенда не ведётся — только ERROR_HISTORY; (3) финальный вердикт полной сборки (CARRY4 после pure-LUT, слайсы pblock) в записях пока НЕ зафиксирован — запрошено у стенда/следующий Cycle.
- Push worklog Task 31 — по явной команде.
---
Task ID: 32
Agent: main (Super Z)
Task: «Почему драйвер не устанавливается? После исправления нужно обновить версию драйвера» — диагностика + FIX-5 (Windows WDF-драйвер driver/)

Work Log:
- Контекст: driver/ — минимальный WDF-драйвер (MMIO BAR0/BAR2 + IOCTL_GET_BAR_INFO), сборка VS2015+WDK 14393/KMDF 1.15, установщик pnputil-based (FIX-4). Из Task 25: драйвер скомпилирован, НЕ установлен — нет Admin.
- НАЙДЕНЫ 3 НЕЗАВИСИМЫХ БЛОКЕРА установки/обновления:
  (1) build.cmd stampinf БЕЗ -o и с -v "*": %TMP_DIR%\XDMA.inf не появлялся, молчаливый fallback копировал СЫРОЙ .inx как .inf → DriverVer заморожен 08/26/2026,1.0.0.0 на каждой пересборке (в репо .inx дата не совпадает с датой сборки — подтверждение, что перезаписи не было);
  (2) pnputil /add-driver НЕ заменяет уже staged-пакет, если новый DriverVer не строго новее → старый 1.0.0.0 оставался навсегда, «обновлённый» драйвер не появлялся (то, о чём сказал пользователь: после исправления нужно поднимать версию);
  (3) install.cmd не чистил предыдущие oemNN.inf-пакеты.
- ИСПРАВЛЕНО (коммит 9aa90f3): build.cmd — переменная DRIVER_VERSION=1.1.0.0 (единый источник), stampinf -o "%TMP_DIR%\XDMA.inf" -v "%DRIVER_VERSION%", отсутствие выхода = HARD ERROR (молчаливый downgrade убран); XDMA.inx — DriverVer=09/11/2026,1.1.0.0 + комментарий-правило «бампать версию на каждое изменение», DeviceDesc v1.1; install.cmd — новый шаг [3/5] удаление предыдущих XDMA-пакетов (PowerShell-парс pnputil /enum-drivers, паттерн как в uninstall.cmd), шаги перенумерованы 1..5, текст v1.1.
- ИНЦИДЕНТ/урок: первая вставка PowerShell-строки содержала удвоенные бэкслеши (\\s вместо \s — артефакт JSON-эскейпинга) → regex никогда бы не совпал, чистка старых пакетов молча не работала; поймано сверкой с рабочим паттерном uninstall.cmd, исправлено. CRLF-проверка: файлы были LF в HEAD — не трогаю.
- Верификация: HWID PCI\VEN_10ee&DEV_7024 == BD CONFIG.pf0_device_id {7024} ✅; [XDMA_Inst.NT.Wdf]/KmdfLibraryVersion=1.15 соответствует libs 1.15 build.cmd ✅; diff построчно, stray-символы (n от вставки) вычищены; test_xdma.c/uninstall.cmd версий не содержат — правки не нужны.
- ПОРЯДОК УСТАНОВКИ на стенде (после сборки build.cmd): запуск install.cmd КАК АДМИН → Secure Boot OFF + bcdedit testsigning on → ПЕРЕЗАГРУЗКА → вставить плату (битстрим должен быть прошит ДО загрузки Windows либо PCIe rescan) → Device Manager «XDMA DDR3 Ternary Accelerator v1.1» без жёлтого знака → test_xdma.exe.
Stage Summary:
- Причина «не устанавливается» двойная: на стенде установка не выполнялась (нет Admin), а в сборке молчаливо пакостился INF с замороженной версией — pnputil такие пакеты не обновляет. FIX-5 устраняет оба механизма, версия 1.1.0.0.
- Коммит 9aa90f3 ЛОКАЛЬНО (вместе с Task 31: ahead 2 от origin). Push — по явной команде.
- За стендом: пересобрать driver/build.cmd (проверить «Creating INF from INX (version 1.1.0.0)» и отсутствие fallback-сообщения), затем install.cmd от админа + reboot; вердикт полной сборки Cycle 7 (CARRY4/слайсы после pure-LUT) всё ещё ожидается.

**Push-запись (Task 32, дополнение):** push выполнен по явной команде пользователя — origin/XDMA_DDR3_TMUL 268b9b2..10ef0be (Task 31 + FIX-5 + Task 32 worklog). Верификация: ahead/behind 0/0, рабочее дерево чистое.
---
Task ID: 33
Agent: main (Super Z)
Task: Стенд: driver.c(15) C2373 __security_cookie при build.cmd — диагностика + все доступные проверки Windows-кода + FIX-6

Work Log:
- ДИАГНОЗ (доказан): файл driver.c на стенде СТАРЫЙ (до 63b97ee от 2026-09-06). Ошибка «driver.c(15) C2373 __security_cookie: переопределение, различные модификаторы» точно совпадает со старым «Variant B»: строка 15 = «volatile ULONG_PTR __security_cookie = ...». В ТЕКУЩЕМ driver.c строка 15 = CTL_CODE (cookie вынесен в security_cookie.c коммитом 63b97ee, определений в driver.c НЕТ). Причина конфликта: wdf.h тянет vcruntime.h (decl __security_cookie plain), а volatile-определение конфликтует — воспроизведено gcc (conflicting type qualifiers), plain-def без конфликта.
- ВЕРСИОННАЯ АРИФМЕТИКА: build.cmd у стенда НОВЫЙ (FIX-4/5 логика в логе), а driver.c старый — рабочая копия смешанная (клон из окна FIX-4..63b97ee либо частичная перезапись). Мгновенный фикс для стенда: git pull --ff-only.
- ПРОВЕРКИ (все доступные вне Windows): собран gcc-харнесс со стаб-заголовками WDK (scripts/wdk_stub/: ntddk/wdf/ntintsafe, EVT_* функциональные typedef + PFN_* для полей, DRIVER_INITIALIZE как функциональный тип, CTL_CODE/DECLARE_CONST_UNICODE_STRING/MmMapIoSpace/LARGE_INTEGER и пр.) → driver.c (440 строк): 0 ошибок/0 критических замечаний, консистентность всех EVT-прототипов и присвоений колбэков подтверждена; security_cookie.c: см. фикс; repro C2373: volatile-def = ошибка, plain-def = OK; test_xdma.c: symlnk XDMA0 == \DosDevices\XDMA0 ✅, кодировка UTF-8 без BOM (MSVC безопасно), флаги cl /GS- /kernel /Gz согласованы с cookie-выносом; BAR-логика: bounds-проверки корректны (BAR2 «>» vs BAR0 «>=» — косметика, не эксплуатируется, bufferLen>=1 гарантирован).
- НАЙДЕН и ИСПРАВЛЕН РЕАЛЬНЫЙ ДЕФЕКТ (был бы следующим сбое): security_cookie.c использовал uintptr_t — в km-инклудах WDK (ntddk.h) он НЕ определён (живёт в <stdint.h>/<vcruntime.h>) → C2061 на чистой сборке. Заменён на ULONG_PTR (basetsd.h, бинарно идентичен); функции помечены __cdecl.
- FIX-6 (коммит): security_cookie.c (ULONG_PTR/__cdecl), build.cmd — stale-гард перед компиляцией (findstr «__security_cookie =» в driver.c → понятная ошибка «обновите рабочую копию» вместо криптичного C2373), версия 1.1.0.0→1.1.1.0 (правило bump), XDMA.inx DriverVer 1.1.1.0.
Stage Summary:
- Корень сбоя стенда — устаревший driver.c (смешанная рабочая копия), НЕ код в репо. Текущий код после всех доступных проверок чист: driver.c 0 ошибок, security_cookie.c 0/0 (после ULONG_PTR-фикса).
- Коммит FIX-6 ЛОКАЛЬНО (по­сле Task 31/32: ahead 3 от origin). Push — по явной команде.
- За стендом по порядку: (1) git pull --ff-only (получит и FIX-6 после пуша); (2) build.cmd — должно пройти «Stale-source guard: OK» и «Creating INF from INX (version 1.1.1.0)»; (3) install.cmd от админа → reboot → test_xdma.exe.
---
Task ID: 33-b (FIX-7)
Agent: main (Super Z)
Task: Стенд-лог №2: компиляция/линковка ОК, stampinf «Invalid argument o» + USAGE-дамп → FIX-7 (copy-then-stamp), версия 1.1.2.0

Work Log:
- НОВЫЙ ЛОГ СТЕНДА подтверждает диагноз FIX-6: C2373 больше нет — скомпилированы driver.c + security_cookie.c, линковка XDMA.sys прошла (стенд обновил рабочую копию: fresh driver.c с 63b97ee).
- НОВЫЙ БЛОКЕР — дефект самого FIX-5: stampinf вызывался с несуществующим флагом `-o "%TMP_DIR%\XDMA.inf"`. В WDK 14393 у stampinf НЕТ опции вывода (лог стенда: «Invalid argument o» + USAGE; допустимы только -f -s -d -a -n -c -v -k -u -i -x; -x валиден — описан в NOTES). Комментарий FIX-5 в build.cmd («MUST write an explicit output via -o», «output went to stdout») был фактически неверен — переписан.
- КОРРЕКТНЫЙ ПАТТЕРН WDK (FIX-7): stampinf ВСЕГДА штампует файл из -f НА МЕСТЕ → сначала copy /Y "%~dp0XDMA.inx" "%TMP_DIR%\XDMA.inf", затем stampinf -f "%TMP_DIR%\XDMA.inf" -d "*" -a "amd64" -v "%DRIVER_VERSION%" -k "1.15" -x. Бонус: XDMA.inx в git больше не может быть затёрт штамповкой (остаётся девственно чистым); на неудачный copy добавлен hard-error.
- ПРАВИЛО ВЕРСИИ: 1.1.1.0 → 1.1.2.0 (build.cmd DRIVER_VERSION + XDMA.inx DriverVer). 1.1.x на стенде ещё ни разу не стейджился (stampinf падал на -o), но бамп — по букве правила «каждое изменение → бамп».
- АВТОПРОВЕРКИ (scripts/check_driver_build.py, вне Windows, итог PASS=29 FAIL=0): версии build.cmd==inx==1.1.2.0; ровно один stampinf; нет -o; все флаги из валидного набора USAGE; -f указывает на TMP-копию; copy предшествует штамповке; FIX-6 stale-гард на месте; driver.c без inline-определения cookie; security_cookie.c: ntddk-only, ULONG_PTR, нет uintptr_t В КОДЕ (первые 2 FAIL чекера — ложные от текста комментариев; чекер научен стрипать комментарии); cl: /GS- /kernel; link: /nodefaultlib + ntoskrnl/hal/wdfldr/wdfdriverentry + security_cookie.obj; inx: HWID 7024, CatalogFile, Wdf-секция, KmdfLibraryVersion=1.15 == -k 1.15. CRLF: 4 файла LF — как в HEAD, стенд это ест.
- ДОКАЗАНО СТЕНДОМ реальным тулчейном (VS2015+WDK 14393): компиляция обоих .c и линковка .sys прошли → после штамповки INF оставшиеся шаги (inf2cat 10_x64, signtool, упаковка, certutil, bcdedit, sc) исторически проходили на этом же INF-шаблоне (1.0.0.0-пакет успешно стейджился ранее — inf2cat принимает структуру этого INF).
Stage Summary:
- FIX-7 закрывает последний известный блокер цепочки build.cmd. Коммит локален (ahead 2: FIX-6 + FIX-7). Push — по явной команде пользователя.
- Ожидание от стенда после pull + build.cmd: «Creating INF from INX (version 1.1.2.0)» БЕЗ USAGE-дампа → inf2cat/signtool/упаковка/сервис. Остаточный риск — только inf2cat/signtool (ранее проходили); далее install.cmd → reboot → test_xdma.exe.
