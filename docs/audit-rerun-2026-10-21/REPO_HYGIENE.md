# Гигиена репозитория после удаления `upgrades\`

- Дата: 2026-10-21
- Репозиторий: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3` (flat, HEAD `496272b`, ветка `main`)
- Трекнутых файлов: 454
- Режим: **только чтение**. В плату не писали, production-файлы не менялись, ничего не удалено и не закоммичено. Единственные записи за аудит — эта папка отчёта и `pytorch_layer\__pycache__\xdma_driver.cpython-310.pyc` (побочный продукт `py_compile`, покрыт правилом `__pycache__/`).

---

## 1. Сводная таблица проверок

| № | Что проверено | Результат | Команда / как проверено |
|---|---|---|---|
| 1.1 | Был ли каталог `upgrades\` вообще в git | **Не был трекнут никогда** — ни одного коммита с этим путём | `git log --all --oneline -- upgrades` → пусто; `git log --diff-filter=D --name-only -- upgrades` → пусто |
| 1.2 | Есть ли `upgrades` в дереве HEAD | Нет (в HEAD только `constraints data dfx_block_designs docs driver pytorch_layer rtl scripts sim ternary_sw third_party tools xdma_driver_win_src_2017`) | `git ls-tree -d --name-only HEAD` |
| 1.3 | Ссылки на `upgrades` в коде/скриптах/TCL/Makefile/доках | **0 ссылок на путь**. `git grep -i upgrade` даёт 7 совпадений, все — про другое: подсказки «if IP upgrade is needed» в `block_design_top.tcl:37`, `dfx_block_designs/default.tcl:29`, `dfx_block_designs/test.tcl:29`, `scripts/xdma_ddr3_bd.tcl:52`, `scripts/xdma_ddr3_dfx_bd.tcl:38` и комментарии про «version upgrade» драйвера в `driver/build.cmd:226`, `driver/install.cmd:70-71` | `git grep -n -i -I "upgrade" -- .` |
| 1.4 | Импорты Python-модулей из `upgrades` (`csrgen`, `regs_sample_*`) | **0 совпадений** (`exit=1`) | `git grep -n -I -E "csrgen\|regs_sample" -- .` |
| 1.5 | Импорты/пути вида `upgrades/` в Python | **0 совпадений** | `git grep -n -I -E "from upgrades\|import upgrades\|upgrades[\\/]" -- .` |
| 1.6 | `scripts\build_flat.tcl` собирает RTL явными списками | **Подтверждено**: только `add_files -norecurse` с перечислением файлов — 184-188 (inlined HDL DataMover), 252-264 (RTL ядра, `device_prog.sv` на 259), 288-291 и 310 (XDC). Рекурсивного обхода каталогов нет | чтение файла, 660 строк |
| 1.7 | Нет ли в `build_flat.tcl` глобов по каталогам | Глобы только служебные: очистка старых артефактов (стр. 124), поиск `*.xpr` (в `post_bd_flat.tcl`), поиск wrapper (194/198). По `rtl/` — нет | `Select-String '\[glob' scripts\*.tcl` |
| 1.8 | `scripts\build_dfx.tcl` (DFX-путь) | Тоже явные `add_files -norecurse`, RTL-список на 309-321. `device_prog.sv` в списке отсутствует, но это **не поломка**: в `xdma_ddr3_core_top.sv:7` `DEVPROG_EN = 0` по умолчанию, а инстанс `device_prog` лежит в выключенной ветви generate (`tdot_axi4.sv:1388` / ветвь-off на 1462) | чтение + `Select-String DEVPROG_EN` |
| 1.9 | `Makefile` | Указывает только `scripts/build_dfx.tcl`, `scripts/gen_bin_mcs.tcl`; путей в `upgrades` нет | чтение Makefile |
| 1.10 | Копия `C:\A7_M2\upgrades` vs `C:\Temp\gigatool\upgrades_parked` | **Идентичны**: 53 файла / 353 016 Б в обеих, SHA256 совпадает у всех 53, «только слева» = 0, «только справа» = 0, расхождений хэшей = 0. В parked лежит на уровень глубже: `upgrades_parked\upgrades\…` | `Get-FileHash -Algorithm SHA256` по обеим копиям, сравнение множеств |
| 1.11 | Есть ли в копиях что-то, чего не было в репозитории | Репозиторная копия и parked идентичны, так что «потерь» нет. Но **весь каталог был untracked** — иных копий этих исходников не существует, единственный бэкап = `upgrades_parked` | п. 1.10 |
| 1.12 | `upgrade_stream` с готовыми логами | **5 логов, все `RESULT: PASS`**: sync DEPTH=4/16 × SHOWAHEAD=0/1 (N=2100, `stress1/stress2 PASS`) и async (в теле лога `cfg(DEPTH=32): words=48`, имя файла при этом `DEPTH_16_WR100RD63` — расхождение имени и конфигурации). В логах пути `C:/A7_M2/.../upgrades/sim/upgrade_stream/…`, время 21.10 18:55, т. е. прогоны сделаны ещё в дереве репозитория до переноса | чтение хвостов 5 логов |
| 1.13 | Инстанцируются ли модули `upgrades` в production RTL | **Нет ни одного**: `stream_fifo`, `stream_async_fifo`, `stream_width_conv`, `csr_regfile`, `event_manager`, `regs_sample_regs_pkg` → 0 совпадений в `rtl\**\*.sv` | `Select-String` по `rtl\` |
| 1.14 | Модифицированные файлы (git) | 10 шт. (см. §3) | `git status --porcelain=v1 -uall` |
| 1.15 | Untracked файлы | 18 шт. (см. §3) | `git status --porcelain=v1 -uall` |
| 1.16 | Диф `pytorch_layer\xdma_driver.py` | **Один хунк** `@@ -554,6 +554,48 @@`, +42 строки, ровно три метода + 4 константы, других правок в файле нет | `git diff -- pytorch_layer/xdma_driver.py` |
| 1.17 | Компилируется ли драйвер | **Да**: `py_compile` → `exit=0`; дополнительно `ast.parse` для 4 изменённых `.py` → все OK. Запуск на железе не производился | `python -m py_compile pytorch_layer\xdma_driver.py` (Python 3.10.0) |

---

## 2. Состав перенесённого `upgrades` (53 файла, обе копии идентичны)

| Группа | Файлов | Что это |
|---|---|---|
| `rtl\upgrade_csr` | 2 | `csr_regfile.sv`, `regs_sample_regs_pkg.sv` (сгенерированный) |
| `rtl\upgrade_events` | 1 | `event_manager.sv` |
| `rtl\upgrade_stream` | 3 | `stream_fifo.sv`, `stream_async_fifo.sv`, `stream_width_conv.sv` |
| `docs` | 5 | `README.md`, `UPGRADE-1-CONFORMANCE.md`, `UPGRADE-1-CSR-MAP.md`, `UPGRADE-2-STREAM-FIFO.md`, `UPGRADE-3-EVENT-MANAGER.md` |
| `sim\upgrade_csr` | 24 | TB + `run_xsim.ps1` + сгенерированные `regs_sample_*` (csv/md/json/dat/svh/consts.py/sv) + 10 файлов логов |
| `sim\upgrade_events` | 8 | TB + `run_xsim.ps1` + 6 логов (N8/N16: vlog/elab/sim) |
| `sim\upgrade_stream` | 8 | 2 TB + `run_xsim.ps1` + 5 логов PASS |
| `tools\csrgen` | 6 | `csrgen.py`, `check_against_current.py`, `regs_sample.json` + 2 `__pycache__\*.pyc` |

Наблюдения по составу:

- **`upgrade_stream` — единственный пакет с полным набором PASS-логов, но у него нет документа** `UPGRADE-*-STREAM` в `rtl`-уровне (док `UPGRADE-2-STREAM-FIFO.md` есть) и **нет TB для `stream_width_conv.sv`** — конвертер ширины не покрыт ни одним тестом и не упоминается в логах. Это единственный реальный пробел покрытия в архиве.
- Внутри перенесённого лежат мусорные `__pycache__\*.pyc` (2 шт.) — при восстановлении их лучше не тащить.
- Ключевой вывод: **механизмы из `upgrades` не «потерялись», они и не подключались**. Ни один модуль `upgrade_*` не инстанцирован в production RTL — их функциональность реализована непосредственно в `rtl/integration/tdot_axi4.sv` (кольцо/планировщик, `irq_pending_q`, DP-регистры, mailbox). То есть `upgrades\` — архив прототипов и стендов, а не недостающая зависимость сборки. Удаление каталога из рабочего дерева ничего не ломает и, поскольку он никогда не был трекнут, **не требует и не позволяет никакого коммита на удаление**.

---

## 3. Остаточные артефакты и их классификация

### 3.1 Моё (эта сессия)

| Файл | Статус git | Время | Комментарий |
|---|---|---|---|
| `docs/audit-hang-2026-10-21/AUDIT_DDR3_MIG.md` | `??` | 21.10 22:41 | отчёт аудита зависания, 25 096 Б |
| `docs/audit-hang-2026-10-21/AUDIT_HOST_DMA.md` | `??` | 21.10 22:41 | 21 486 Б |
| `docs/audit-hang-2026-10-21/AUDIT_RTL_FSM.md` | `??` | 21.10 22:41 | 19 830 Б |
| `docs/audit-hang-2026-10-21/SYNTHESIS.md` | `??` | 21.10 22:45 | 4 695 Б |
| `docs/audit-rerun-2026-10-21/REPO_HYGIENE.md` | `??` (новый) | 21.10 | этот отчёт |
| `docs/audit-rerun-2026-10-21/REVIEW_HOST_FIX.md` | `??` (новый) | 21.10 23:38 | **не мой файл**: появился в этой папке во время аудита, написан параллельным процессом (ревью той же правки драйвера). Я его не создавал и не правил; в отчёте он учитывается только как факт состояния дерева |
| `pytorch_layer/xdma_driver.py` | `M` | 21.10 23:01 | +42 строки: `write_config`, `engine_stalled`, `soft_reset_engine` |
| `pytorch_layer/__pycache__/xdma_driver.cpython-310.pyc` | не виден (`.gitignore: __pycache__/`) | 21.10 23:36 | побочный продукт `py_compile`, безвреден |

### 3.2 Старое / чужая работа того же дня (до этой сессии, mtime 16:04–21:25)

| Файл | Статус | Время | Суть правки |
|---|---|---|---|
| `rtl/integration/tdot_axi4.sv` | `M` | 21.10 20:33 | backpressure `dp_fifo_ready` в device_prog + watchdog `DP_WDOG_MAX=1<<22` + регистр `DP_STAT` (6'd61) |
| `scripts/obs_smi.py` | `M` | 21.10 17:11 | `--once`, `--ddr-check`, «Карта платы», XADC через `XadcMonitor`, `rr()` с `n/a` |
| `rtl/integration/device_prog.sv` | `M` | 21.10 16:39 | рукопожатие `desc_task_ready` (не теряет задачи при полном FIFO) |
| `scripts/monitor_obs.py` | `M` | 21.10 16:14 | маска 32-бит в `delta()`, база счётчиков сразу после `obs_clear` |
| `pytorch_layer/monitor_temp.py` | `M` | 21.10 16:06 | `XadcMonitor(dev=…)` — переиспользование открытого устройства |
| `scripts/build_flat.tcl` | `M` | 21.10 16:04 | `DEVPROG_EN` default 0→1, `maxThreads` после разбора `-tclargs` |
| `dfx_runtime.txt` | `M` | 21.10 21:25 | счётчик CPU-времени отчёта Vivado (`0:0:3` → `0:0:25`) — **трекнутый артефакт прогона** |
| `data/audio_model_fpga.npz` | `M` | 21.10 01:07 | бинарь модели |
| `data/audio_model_fpga.npz.json` | `M` | 21.10 01:07 | `hidden: 128 → 64` (перегенерация модели) |

### 3.3 Старый мусор пользователя (mtime 20.10 01:42 / 04:28, этой сессией не трогался)

| Файл | Статус | Примечание |
|---|---|---|
| `.gigatool/gigatool.json` | `??` | служебный файл прав доступа MultiTool |
| `origMakefile.mak` | `??` | копия старого Makefile |
| `block_design_top.tcl.bak_startup` | `??` | бэкап |
| `constraints/xdma_ddr3_pins.xdc.bak_reqp` | `??` | бэкап |
| `constraints/xdma_ddr3_pins.xdc.bak_t3_20260913_212106` | `??` | бэкап |
| `rtl/integration/spi_over_pcie.sv.bak_before_remove_stupe2` | `??` | бэкап |
| `rtl/integration/spi_over_pcie.sv.bak_bom` | `??` | бэкап |
| `rtl/integration/spi_over_pcie.sv.bak_startupe2` | `??` | бэкап |
| `rtl/integration/spi_over_pcie.sv.bak_t2_20260913_211919` | `??` | бэкап |
| `rtl/integration/xdma_ddr3_core_top.sv.bak_t2_20260913_211919` | `??` | бэкап |
| `rtl/integration/xdma_ddr3_core_top.sv.bak_t3_20260913_212106` | `??` | бэкап |
| `scripts/build_dfx.tcl.bak_20260913_223025` | `??` | бэкап |
| `scripts/xdma_ddr3_dfx_bd.tcl.bak_m06` | `??` | бэкап |
| `scripts/xdma_ddr3_dfx_bd.tcl.bak_startup` | `??` | бэкап |

Итого: 18 untracked = 4 «моих» (плюс эта папка = 5 файлов) + 14 старых (12 `.bak*` + `origMakefile.mak` + `.gigatool/gigatool.json`). Снимок `git status` сделан в 23:36; в 23:38 в моей папке отчёта появился внешний `REVIEW_HOST_FIX.md` (см. §3.1), поэтому текущее число untracked — 19. 10 modified = 1 моё (драйвер) + 9 файлов более ранней работы того же дня.

Почему бэкапы видны в статусе, хотя в `.gitignore` есть `*.bak`: правило совпадает только с именами, **оканчивающимися** на `.bak`, а здесь суффиксы `.bak_startup`, `.bak_reqp`, `.bak_t3_…` — они не игнорируются.

---

## 4. Проверка правок драйвера (`pytorch_layer\xdma_driver.py`)

- Диф — **ровно один хунк**, `@@ -554,6 +554,48 @@`; добавлены:
  - `write_config(offset, data)` (стр. 557) — запись в config-BAR `\control` (движковые регистры XDMA), Периферию писать по-прежнему нельзя (её диапазон в `\user`);
  - константы `_X2C_CTRL_RST = 0x80000000`, `_X2C_H2C0_CTRL = 0x04`, `_X2C_H2C0_STAT = 0x40`, `_X2C_H2C0_DONE = 0x48`;
  - `engine_stalled(base=0x0000, poll_s=0.5)` (стр. 570) — только чтение: канал активен (`CTRL & 1`), а `completedDescCount` не растёт;
  - `soft_reset_engine(base=0x0000)` (стр. 583) — stop + `CTRL_RST`, затем комментарий, что после reset нужна перепривязка дескрипторов вручную.
- Импорты на месте: `import os, subprocess, struct, time, threading` (стр. 38) — `struct`/`time` уже были, новых зависимостей нет.
- Компиляция: `python -m py_compile` → `exit=0`; `ast.parse` для `xdma_driver.py`, `monitor_temp.py`, `obs_smi.py`, `monitor_obs.py` → OK. На железо ничего не запускалось.
- **Оговорка по формулировке «единственное изменение production-файла за сессию»**: за *эту* сессию — да, драйвер единственный (mtime 23:01, тема совпадает с аудитом зависания). Но в рабочем дереве **всего 9 других production-файлов с правками** от более ранней работы того же дня (§3.2), поэтому «в репозитории изменён только драйвер» — неверно; верно «драйвер изменён в этой сессии, остальные — раньше».

### Найденный дефект в новой правке

`soft_reset_engine` в docstring обещает защиту: «Сейчас используется ТОЛЬКО как фолбэк за флагом `ALLOW_ENGINE_RESET` (по умолчанию False)». **Такого флага в коде нет** — `git grep ALLOW_ENGINE_RESET` находит его только в этой строке docstring (плюс внутри того же файла нет ни проверки, ни самого имени). То есть заявленный предохранитель — только текст: любой вызов метода немедленно пишет в config-BAR. Сейчас риск не реализуется лишь потому, что **метод никто не вызывает** (`git grep -E "engine_stalled|soft_reset_engine|write_config"` → попадания только внутри самого файла).

Дополнительно: `engine_stalled` блокирует поток на `poll_s = 0.5 с` и глушит `OSError/XdmaError` в `return False` — трактовка «не завис» при ошибке безопасна по направлению, но маскирует отказ доступа к config-BAR.

Независимое подтверждение: в этой же папке параллельным процессом создан `REVIEW_HOST_FIX.md` (23:38), который по сверке с `xdma_driver_win_src_2017/libxdma/reg.h` и `dma_engine.c` приходит к тому же выводу про `ALLOW_ENGINE_RESET` (флаг не существует, метод публичный, гея нет) и дополнительно указывает, что `XDMA_CTRL_RST` ни одним путём в дереве драйвера не используется, а сама правка лежит в `XdmaWinUpstream`, тогда как основные скрипты работают через `XdmaWinDma`. Эти пункты лежат вне гигиены репозитория и здесь не перепроверялись — отмечены как мнение параллельного ревью.

---

## 5. Чек-лист «что осталось грязным»

- [x] Ссылок на `upgrades` в репозитории нет (пути, импорты, TCL, Makefile, доки) — блокер снят.
- [x] `upgrades` никогда не был трекнут → удаление не создаёт «дыры» в истории; коммит на удаление не нужен.
- [x] Сборка от каталога не зависит: `build_flat.tcl` и `build_dfx.tcl` используют `add_files -norecurse` со явными списками; обхода `rtl/` глобами нет.
- [x] Копия `upgrades_parked` полная: 53/53 файла, SHA256 совпадает, потерь нет.
- [ ] Единственная копия прототипов `upgrade_*` — вне git (`C:\Temp\gigatool\upgrades_parked`). Каталог `C:\Temp` не является местом хранения: при очистке temp архив исчезнет безвозвратно.
- [ ] `soft_reset_engine`: docstring ссылается на несуществующий флаг `ALLOW_ENGINE_RESET` (строки 588-589 драйвера) — защита не реализована, а метод не вызывается ниоткуда.
- [ ] 12 бэкапов `*.bak*` + `origMakefile.mak` + `.gigatool/gigatool.json` висят untracked, часть не покрыта `*.bak` из-за суффиксов `.bak_*`.
- [ ] `dfx_runtime.txt` **трекнут**, но содержит счётчик времени прогона Vivado — шум в диффах на каждом билде.
- [ ] `data/audio_model_fpga.npz` (+`.json`: `hidden` 128 → 64) изменены — это перегенерация модели, решать осознанно: коммитить новую модель или откатить.
- [ ] 9 production-файлов с непрокоммиченными правками от 21.10 (RTL + скрипты) — самая ценная и самая рискованная часть грязи: правки `tdot_axi4.sv`/`device_prog.sv` описывают поведение прошивки на плате, но не зафиксированы.
- [ ] `build_flat.tcl` теперь имеет `DEVPROG_EN = 1` по умолчанию — на плате это уже наблюдается как «застрявшее» ядро; решение владельца о дефолте нигде не зафиксировано в коммите.
- [ ] `stream_width_conv.sv` без TB/логов; лог async назван `DEPTH_16`, а внутри `cfg(DEPTH=32)` — при восстановлении стенда конфигурацию придётся перепроверять.

## 6. Рекомендации (ничего не выполнено — только предложения)

1. **Закоммитить работу 21.10 одним-двумя осмысленными коммитами**: (а) RTL — backpressure + watchdog + `DP_STAT` (`tdot_axi4.sv`, `device_prog.sv`); (б) инструменты — `obs_smi.py`, `monitor_obs.py`, `monitor_temp.py`, `build_flat.tcl`. Без этого правки, описывающие текущее поведение прошивки, живут только в рабочем дереве.
2. **Драйвер**: либо реализовать `ALLOW_ENGINE_RESET` (модульная константа/параметр конструктора с проверкой в `soft_reset_engine`), либо убрать обещание из docstring. Коммитить вместе с отчётами аудита зависания — они объясняют, зачем метод нужен.
3. **Отчёты** `docs/audit-hang-2026-10-21/` и `docs/audit-rerun-2026-10-21/` — закоммитить как документацию аудита.
4. **`dfx_runtime.txt`**: добавить в `.gitignore` и `git rm --cached` (это отчёт прогона, а не исходник).
5. **`.gitignore`**: заменить/дополнить `*.bak` на `*.bak*` (или `*.bak_*`), чтобы 12 файлов перестали светиться в `git status`. Бэкапы один раз проверить и удалить вручную — удаление бэкапов я не делал.
6. **`data/audio_model_fpga.npz`/`.json`**: определить, какая модель канон (128 или 64 hidden), и либо закоммитить пару целиком, либо `git checkout --` обе.
7. **`upgrades_parked`**: перенести архив из `C:\Temp\gigatool` в постоянное место (например, отдельный git-репозиторий `tdot-upgrades-prototypes` или `docs/archive/upgrades-2026-10/`) — в текущем виде это единственная копия 53 файлов, включая PASS-логи `upgrade_stream`.
8. `.gigatool/gigatool.json` и `origMakefile.mak` — либо в `.gitignore`, либо удалить после проверки (не делал).

---

## Вывод

Удаление `upgrades\` безопасно и ничего не сломало: каталог никогда не был трекнут git, на него нет ни одной ссылки в коде, TCL, Makefile и документации, а обе сборочные ветки (`build_flat.tcl`, `build_dfx.tcl`) перечисляют RTL явными `add_files -norecurse`, поэтому состав каталогов на сборку не влияет. Перенесённая копия полная и побайтово идентична (53/53, SHA256), в ней есть `upgrade_stream` с 5 PASS-логами (sync DEPTH=4/16 × SHOWAHEAD=0/1, async) — это самый проработанный, но не подключённый к прошивке пакет; ни один модуль `upgrade_*` не инстанцирован в production RTL, механизмы реализованы прямо в `tdot_axi4.sv`. Правки драйвера (`write_config`/`engine_stalled`/`soft_reset_engine`) — единственное изменение *этой* сессии, компилируется чисто, но содержат дефект документации: обещанного флага `ALLOW_ENGINE_RESET` в коде нет, а сам метод пока не вызывается. Основная оставшаяся грязь — не `upgrades`, а 9 непрокоммиченных production-правок от 21.10, трекнутый `dfx_runtime.txt` и 12 бэкапов, не покрытых правилом `*.bak`.
