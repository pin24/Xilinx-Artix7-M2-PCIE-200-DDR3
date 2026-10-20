# Аудит сборочного flow FPGA-проекта Xilinx Artix-7 (FLAT, без DFX)

Дата: 2026-10-20 · Корень: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3` · Вариант: FLAT (`build_flat.tcl`)
Режим: только чтение/анализ. Vivado НЕ запускался.

Сетевка severity:
- **P1** (сборка даёт неверный результат / тихо пропускает ошибку): 2
- **P2** (нестабильность / невоспроизводимость): 5
- **P3** (гигиена): 6

---

## P1 — сборка даёт неверный результат / тихо пропускает ошибку

### F1. FATAL-гейт flat проверяет ТОЛЬКО setup; hold и ширина импульса не проверяются; пустой набор путей трактуется как «MET»
`scripts/build_flat.tcl:330-389` (гейт 8.5), ключевая строка `build_flat.tcl:344`:
```tcl
set all_viol [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1 -slack_lesser_than 0]
```
- Проверяется только `-delay_type max` (setup). **Hold (WHS, `-delay_type min`) и WS PulseWidth/WPWS гейтом не проверяются** — прямо противоречит конвенции BUG-038 («WHS<0 → чип неработоспособен → битстрим брак», `tcl_timing_lib.tcl:82-95`). Битстрим с нарушенным hold может быть экспортирован «зелёным».
- Если `get_timing_paths` вернул пустой список (нет констрейнированных клоков, все пути в async-группах, либо дизайн без валидных клоков), ветка `else` (`build_flat.tcl:370-372`) печатает «FATAL GATE: TIMING MET ... (0 violations)» и гейт ПРОХОДИТ. Т.е. при отсутствии отчёта/путей ошибка проглатывается. «max_paths» исправлен (0→1), но «пустой отчёт» не обрабатывается.
- Правильная реализация — `scripts/check_timing_fatal.tcl` (парсит `report_timing_summary`, `print_verdict`/`is_fatal` проверяют WNS/WHS/WPWS и **возвращают exit 1, когда блок отчёта не найден**, `tcl_timing_lib.tcl:99-105`). Grep по `build_flat.tcl` подтверждает: `check_timing_fatal.tcl` **нигде не вызывается в flat-flow**; `tcl_timing_lib.tcl` подключается на `build_flat.tcl:334`, но ни одна его proc в гейте не используется (гейт inline).
- Сценарий: impl завершается, внутри группы fabric125 есть hold-нарушение (или гейт со свежесобранными async-группами получает 0 путей) → гейт печатает MET → `.bit`/`.mcs` экспортируются, CI зелёный.
- Решение: в гейте добавить проверку `get_timing_paths -delay_type min` (WHS) и `report_timing_summary` (WHS/WPWS), либо заменить inline-гейт вызовом `check_timing_fatal.tcl`/`::timing::is_fatal` и уходить в `exit 1` при пустом summary.

### F2. Риск «тихого» несоответствия NUM_MAC/ADDERS: generic через fileset — хрупкий механизм, дефолты RTL ≠ запрошенные конфиги
`scripts/build_flat.tcl:210-265` (особенно `build_flat.tcl:264`):
```tcl
set_property generic [list BUILD_ID=32'h${BUILD_ID_HEX} NUM_MAC=${NUM_MAC} ADDERS=${ADDERS}] [current_fileset]
```
- Комментарии в самом файле (`build_flat.tcl:256-263`) фиксируют долгую борьбу: NUM_MAC/ADDERS (тип `int`) Vivado ранее **не принимал** как fileset-generic, и синтез молча брал дефолты топа `#(16,4)` (`rtl/integration/xdma_ddr3_core_top.sv:5`, `rtl/block/compute_dot_par_raw.sv:43-44`). Текущая правка заявлена как «verified», но это нестандартный и хрупкий путь.
- **Дефолт build_flat — NUM_MAC=32, ADDERS=16** (`build_flat.tcl:41-42`), а дефолт RTL — **16/4**. Если generic не применится (тихая деградация), `_flat64.bat` (NUM_MAC=64) соберёт ядро **16 MAC**, и единственная разница будет только в BUILD_ID — функционально неверная прошивка «зелёной» сборки.
- **Нет подтверждения** что generic применён: ни один шаг не читает обратно `CORE_PARAMS` (регистр `0x40023000+0x64`, `tdot_axi4.sv:400`) и не сверяет его с запрошенными значениями.
- Сценарий: любой регресс/переход версии 2025.2→2025.3 меняет поведение `set_property generic` → все конфиги тихо собираются как 16/4.
- Решение: CI должен после сборки читать `CORE_PARAMS` и сверять; и/или верифицировать, что `NUM_MAC` из generic попал в netlist (контрольная точка/иерархия gen_mac[0:N-1] на синтезированном DCP).

---

## P2 — нестабильность / невоспроизводимость

### F3. pblock_flat_tdot.xdc геометрически «подогнан» под NUM_MAC=16 и переиспользуется для 32/64
`constraints/pblock_flat_tdot.xdc:10-27,37-38`; добавляется в сборку `build_flat.tcl:241-243` (PROCESSING_ORDER LATE).
- Шапка файла прямо говорит: регион `SLICE_X25Y4:SLICE_X105Y85` (6642 SLICE) посчитан по фактическому spread ядра **gen_ad[0..3]+gen_mac[0..15]** (т.е. NUM_MAC=16, ADDERS=4, ~7400 занятых клеток). `u_core` в RTL действительно содержит `gen_mac[0:NUM_MAC-1]/u_mul` + `gen_ad[0:ADDERS-1]/u_add` (`compute_dot_par_raw.sv:63-96`), путь клетки `u_tdot/u_core` корректен.
- Дефолт сборки — **NUM_MAC=32**, а `_flat64.bat` — **NUM_MAC=64** (→ ~4× MAC-блоков). Фиксированный регион на 6642 SLICE не вместит ~26k+ клеток 64-MAC ядра → placer-переполнение (overutil), экстремальная локальная конгестия, WNS-провал, либо явный place-error. Комментарий в `_flat64.bat` сам предупреждает «может не уложиться».
- Сценарий: `_flat64.bat` валится на месте/тайминге, либо (при «повезло») — сильно деградированный по таймингу битстрим из-за запихнутого в маленький регион ядра.
- Решение: размер/центр pblock делать производным от NUM_MAC/ADDERS (параметризованная генерация), либо для 32/64 использовать отдельный файл; добавить диагностику `add_cells_to_pblock` (не должен остаться пустым), не молча.

### F2 (см. выше) — несоответствие NUM_MAC=16/32/64 между RTL-дефолтом и запрошенными — риск функционального несоответствия (см. P1-2).

### F4. JOBS vs maxThreads: bat передают 8–13, но maxThreads жёстко 4; паралл. завышен на 16 ГБ
`scripts/build_flat.tcl:41-45` (дефолт JOBS=4, `set_param general.maxThreads 4` — «низкий параллелизм для малого ОЗУ»), `build_flat.tcl:293,320` (`launch_runs ... -jobs ${JOBS}`).
- `_flat16.bat` JOBS=8, `_flat32.bat` JOBS=13, `_flat64.bat` JOBS=8. Но `set_param general.maxThreads 4` **не обновляется из JOBS** → реальный потока-лимит остаётся 4, `-jobs 13` фактически не даёт 13 потоков (запущено впустую), а при случае maxThreads=4 и 13 «джобов» противоречивы.
- Комментарий «низкий параллелизм» противоречит .bat, которые ставят 8–13. На XC7A200T синтез+impl при NUM_MAC=64 и нескольких джобах легко упрут в >16 ГБ RAM → OOM.
- Решение: синхронизировать `general.maxThreads` с JOBS из tclargs; задать единый источник значений; в .bat явно выставлять JOBS разумным (4–8) для 16 ГБ.

### F5. set_clock_groups -asynchronous исключает ВСЕ междоменные пути и из closure, и из гейта — слепота по CDC
`scripts/timing_exceptions_post.tcl:45-95` (применяется как `STEPS.PLACE_DESIGN.TCL.PRE`, `build_flat.tcl:291`).
- Все домены (pcie, clk50raw, fabric125, mig, icap) объявлены взаимно асинхронными → межгрупповые пути удаляются из STA ДО гейта. Это делает `get_timing_paths` в F1 нечувствительным к межклоковым нарушениям. Правильность держится на том, что каждое пересечение действительно защищено CDC (2-FF `ASYNC_REG`, async-FIFO внутри SmartConnect).
- Если хоть одно пересечение (например, `tdot_irq` синхронизатор, `axi_aclk`↔`core_clk` loop на `xdma_ddr3_core_top.sv:218`) реально несинхронизировано, гейт его НЕ увидит — «зелёная» сборка с потенциальным метастабильностью.
- Мёртвый код: скрипт всё ещё создаёт `icap_clk` из `u_icap/u_icap_bufg` (`timing_exceptions_post.tcl:29-43`), который в flat-топе **отсутствует** (коммент: «FLAT: без icap/u_icap», топ объявляет `axi_aclk` как `logic` без инстанса). Только WARNING, но это DFX-хвост.
- Решение: оставить async-группы как есть, но в гейт добавить независимую проверку `report_clock_interactions`/`report_cdc`, чтобы не было тихих пересечений; удалить icap-блок из flat-скрипта.

### F6. Артефакты не чистятся при провале; run-директория схематично содержит .bit ещё до гейта
`scripts/build_flat.tcl:283-320` (шаг 8 генерирует .bit в run-каталог через `launch_runs -to_step write_bitstream`), затем гейт 8.5 (`build_flat.tcl:330-389`), затем экспорт 9 (`build_flat.tcl:391-405`).
- `file mkdir ${ARTIFACTS_DIR}` не удаляет старые `.bit/.mcs/.rpt`. Если новая сборка упала (synth/impl/гейт), **старые артефакты в `build/artifacts_flat/` остаются** и могут быть ошибочно приняты host-софтом/Makefile за свежие. Провал гейта = exit 1, но файлы не чищены.
- Битстрим в `m2_artix7_xdma_flat.runs/impl_1/xdma_ddr3_core_top.bit` создаётся на шаге 8 ДО гейта — при провале гейта в run-каталоге остаётся «мусорный» .bit.
- Решение: в начале уровня 9 вычищать `${ARTIFACTS_DIR}` (или строить путь с BUILD_ID/датой); сверять mtime артефактов со стартом сборки; документально запрещать использование run-каталога .bit.

### F7. Воспроизводимость: BUILD_ID зависим от git HEAD; PROJ_DIR фиксирован; RETIMING non-детерминирован
`scripts/build_flat.tcl:218-224` (`git rev-parse --short=8 HEAD` → BUILD_ID), `build_flat.tcl:32` (`PROJ_DIR "C:/build_flat"`), `build_flat.tcl:287` (`RETIMING true`), версия Vivado сверяется только WARNING (`scripts/xdma_ddr3_bd.tcl:46-53`).
- BUILD_ID меняется по каждому коммиту → «одинаковый» битстрим из одного и того же исходника, но разных коммитов, различается (регистр BUILD_ID). Вне git-дерева — `00000000`. Нет гарантии, что артефакт соответствует каталогу исходников.
- `PROJ_DIR` = `C:/build_flat` общий для ВСЕХ конфигов → два параллельных `_flat*.bat` коллизируют (очистка в начале одного снесёт проект другого). `RETIMING true` делает синтез тесно связанным с seed/жадностью и ослабляет воспроизводимость.

---

## P3 — гигиена

- **P3-1. DFX-хвосты в flat-флоу.** Шапка `build_flat.tcl:20-21` заявляет «no pblock, no partial reconfiguration», но pblock_flat_tdot.xdc **добавляется** (`build_flat.tcl:241-243`). `check_timing_fatal.tcl`, `allow_lut_overutil.tcl`, `suppress_lut_overutil.tcl`, `timing_report_analysis.tcl` НЕ задействованы в flat (grep пуст). icap_ctrl.sv / spi_over_pcie.sv остаются в дереве (осознанно, коммент `build_flat.tcl:207-208`).
- **P3-2. Кодировка/«mojibake» в `build_flat.tcl`.** Комментарии местами в искажённой кодировке («РІР‚вЂќ» вместо тире/em-dash) — `build_flat.tcl:2,110,207,237-240` и др. В комментариях синтаксису не мешает, но затрудняет ревью и, при случайном переносе искажённого байта в строку с Tcl-кодом, может сломать парсинг.
- **P3-3. Расхождение индексов/документации.** post_bd_flat называет XADC «M04» (`post_bd_flat.tcl:230`), ADDRESS_MAP — «M05» (`docs/ADDRESS_MAP.md:82`). ADDRESS_MAP.md в целом DFX-ориентирован (SPI 0x40025000, ICAP 0x40024000, DFX-сокет 0x40022000) — в flat этих регионов нет; добавленная в flat diag_bram 0x10000000 в ADDRESS_MAP отсутствует.
- **P3-4. Дублирование логики clock-groups.** Констрейнтный `constraints/timing_exceptions.tcl` (в flat **не подключается**) и `scripts/timing_exceptions_post.tcl` (используется) содержат почти одинаковую группировку клоков — риск расхождения (правят один, забывают второй).
- **P3-5. file-copy обёртки.** Glob `post_bd_flat.tcl:194` ищет `C:/build_flat/m2_artix7_xdma_flat.gen/...`, но Vivado кладёт gen в `C:/build_flat.gen` (sibling, без слэша) → копия `build/xdma_ddr3_dfx_wrapper.v` молча пропущена (там же есть fallback glob `C:/build_flat/*.gen` — тоже не совпадает). Для самой сборки не критично, но `build/xdma_ddr3_dfx_wrapper.v` может быть устаревшим/отсутствовать.
- **P3-6. `allow_lut_overutil.tcl`/`suppress_lut_overutil.tcl` не подключены.** Если при NUM_MAC=64 LUT-запрос превысит лимиты xc7a200t (~134 600 LUT), placer упадёт с ошибкой overutil (громко, но flow готов был это «разрешать» через `drc.disableLUTOverUtilError 1` — намерение не доведено до flat).

---

## Проверка по пунктам ТЗ

| # | Пункт | Результат |
|---|---|---|
| 1 | Обработка ошибок Tcl / `exit 1` | Частично: свой `exit 1` на провале synth/impl/гейт/cleanup и `catch` вокруг деструктивных вещей. **Нет** `set_msg_config -severity ERROR`; STATUS-проверка `[string first "complete" ...]`; `write_bitstream`/`write_cfgmem`/`validate_bd_design` вне try. |
| 2 | FATAL-гейт | «max_paths 0→1» исправлен, но гейт только setup (см. F1); `check_timing_fatal.tcl` не задействован; пустой отчёт проходит. |
| 3 | pblock | Путь `u_tdot/u_core` верен (подтверждено RTL). Регион жёстко под NUM_MAC=16 → для 32/64 неадекватен (F3). «pblock не найден» дал бы пустой pblock молча. |
| 4 | Тайм-исключения | false_path/multicycle: MCP по tfmul_raw БЛОКИРОВАН в комментарии (`xdma_ddr3_early.xdc:19-31` — «маскировать нельзя»); active — только set_clock_groups async (маскирует междоменные пути, см. F5). Set_max_delay на CDC — баунды. |
| 5 | NUM_MAC/ADDERS | Передаются fileset-generic (build_flat:264) при дефолтах 32/16 vs RTL 16/4; риски F1-2/F3; `_flat64` (64/2) ресурсно нереалистично с этим pblock. |
| 6 | Воспроизводимость | Чистка проекта ({PROJ_DIR}.cache/.gen/.hw/.ip_user_files/.sim/.Xil) есть; но build/artifacts и wrapper не чистятся (F6); BUILD_ID от git (F7); PROJ_DIR общий. |
| 7 | BD-адресация | Совпадает с ADDRESS_MAP: DDR3 0x80000000/256MB, BRAM 0x10000000, MK2S 0x40010000, S2MM 0x40018000, GPIO 0x40020000, TDOT 0x40023000, XADC 0x46000000. diag_bram в ADDRESS_MAP не задокументирован (P3-3). |
| 8 | DFX в flat | Нет ломающих ссылок на dfx_partition/icap/rm-модули в flat-скриптах (grep чист). Мёртвый код: icap_clk в timing_exceptions_post (F5), неиспользуемые timing-скрипты (P3-1). |
| 9 | OOC/JOBS/OOM | OOC не используется (всё flat). maxThreads=4 жёстко, JOBS из bat 8–13 → рассогласование, риск OOM на 16 ГБ (F4). |
| 10 | Артефакты | `.bit/.mcs/.rpt` без версии/даты в имени, без очистки при провале, BUILD_ID не отражается в имени файла (F6). |

---

## Рецепт чистой пересборки

Целевая конфигурация (`NUM_MAC`, `ADDERS`) по умолчанию — 16/4 (проверенная на ресурсах и pblock), что согласуется с эталонной геометрией pblock. Для 32/64 — отдельный pblock.

```bat
:: 0. Стоп всех Vivado и чистка старых состояний
taskkill /f /im vivado.exe /im vivado.bat 2>nul
rmdir /s /q C:\build_flat
rmdir /s /q C:\build_flat.cache
rmdir /s /q C:\build_flat.gen
rmdir /s /q C:\build_flat.hw
rmdir /s /q C:\build_flat.ip_user_files
rmdir /s /q C:\build_flat.sim
rmdir /s /q C:\build_flat\.Xil
rd /s /q C:\build_flat 2>nul
:: 1. Очистить СТАРЫЕ артефакты (чтобы провал не маскировался свежестью старых файлов)
del /q C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\build\artifacts_flat\*  2>nul
del /q C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\build\xdma_ddr3_dfx_wrapper.v 2>nul

:: 2. Сборка с нуля (минимальный, ресурсно-безопасный конфиг)
cd /d C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;%PATH%
vivado -mode batch -source scripts\build_flat.tcl -tclargs NUM_MAC=16 ADDERS=4 JOBS=4 -nojournal
if errorlevel 1 goto :FAIL
:: 3. НЕЗАВИСИМЫЙ гейт по таймингу (hold/WPWS + отчёт) на роутed DCP
vivado -mode batch -source scripts\check_timing_fatal.tcl -tclargs C:\build_flat\m2_artix7_xdma_flat.runs\impl_1\xdma_ddr3_core_top_route_design.dcp
if errorlevel 1 goto :FAIL
:: 4. (host) Прочитать CORE_PARAMS (0x40023000+0x64) и сверить NUM_MAC/ADDERS с запрошенными
:: 5. (host) Проверить mtime .bit/.mcs > времени старта сборки; UID != 00000000 (в git)
echo CLEAN_REBUILD_OK
goto :EOF
:FAIL
echo CLEAN_REBUILD_FAILED
exit /b 1
```

### Чего в текущем flow не хватает для гарантированного «чистого» битстрима
1. **Отсутствует независимый вызов `check_timing_fatal.tcl`** (только inline-гейт, который не видит hold/WPWS и пропускает пустой отчёт) — обязателен внешний гейт на роутed DCP.
2. **Нет очистки `build/artifacts_flat`** в начале сборки → старые артефакты маскируют провал (F6).
3. **Нет проверки применённого NUM_MAC/ADDERS** (чтение CORE_PARAMS и/или контроль gen_mac[0:N-1] на синтезированном DCP) — защита от тихого отката к дефолтам (F2).
4. **Нет DRC-гейта** перед bitstream (report_drc по ошибкам) и нет `set_msg_config -severity ERROR` — сборка полагается только на STATUS=complete.
5. **pblock для NUM_MAC=64 отсутствует** — `_flat64.bat` сейчас нереалистичен (F3).
6. **Нет сверки mtime/конфига** артефакта с исходниками (BUILD_ID вне имени файла).

---

## Счёт (итог)
- P1: 2  (`build_flat.tcl:344` гейт; `build_flat.tcl:264` generic/silent-дефолт)
- P2: 5  (`pblock_flat_tdot.xdc:37-38`; `build_flat.tcl:41-45,293,320`; `timing_exceptions_post.tcl:45-95`; `build_flat.tcl:283-389`+экспорт; `build_flat.tcl:218-224,32,287`)
- P3: 6
- Топ-5 по значимости (file:line):
  1. `scripts/build_flat.tcl:344` — гейт только setup, hold/WPWS и пустой отчёт не ловятся.
  2. `scripts/build_flat.tcl:264` — немой откат NUM_MAC/ADDERS к RTL-дефолтам 16/4 при ненадёжном fileset-generic.
  3. `constraints/pblock_flat_tdot.xdc:37-38` — регион под NUM_MAC=16, переиспользуется для 32/64.
  4. `scripts/timing_exceptions_post.tcl:82-95` — async-группы маскируют междоменные пути от closure и гейта.
  5. `scripts/build_flat.tcl:397-405` — старые артефакты не чистятся при провале; run-.bit создаётся до гейта.