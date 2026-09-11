# ERROR-FIX-LOG — журнал ошибок и исправлений (проект XDMA Artix-7 M.2)

> Каталог: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\driver`
> Сессия аудита: 2026-09-11, хост DESKTOP-27KRDOC (Win10 19041, RU locale)
> Историческая база проекта: `docs/ERROR_HISTORY.md` (BUG-001…052), `docs/worklog.md`.
> Формат записи: симптом → первопричина → исправление → файлы/строки → проверка → статус.

---

## E-01 — BSOD #1/#2: SYSTEM_THREAD_EXCEPTION_NOT_HANDLED (0x1000007E) в XDMA.sys+0x1067

| Поле | Значение |
|---|---|
| **Дата** | 2026-09-10 22:22:35 · 2026-09-11 00:55:04 |
| **Дампы** | `C:\Windows\Minidump\091026-38171-01.dmp`, `091126-44296-01.dmp` |
| **Симптом** | Bugcheck 0x1000007E, Arg1=c0000005 (AV), сбой в `XDMA.sys+0x1067`: `call qword ptr [rax+3A0h]` при `rax=0` → чтение адреса `0x3A0`. Процесс `System`, IRQL 0. Повторяемость 100 % при каждой загрузке драйвера. |
| **Первопричина** | `build.cmd` линковал драйвер с `/entry:DriverEntry`. Заглушка KMDF `FxDriverEntry` (wdfdriverentry.lib), вызывающая `WdfVersionBind`, не подтягивалась (в образе не было импортов из WDFLDR.SYS) → таблица `WdfFunctions` оставалась NULL. Первый же `WdfDriverCreate` в `DriverEntry` — переход по NULL. `0x3A0/8 = 116 = WdfDriverCreateTableIndex` (wdffuncenum.h, KMDF 1.15). |
| **Исправление** | `FIX-8`: `/entry:DriverEntry` → `/entry:FxDriverEntry` (совпадает с WDK: `WindowsDriver.KernelMode.KMDF.props`, `EntryPointSymbol=FxDriverEntry`). |
| **Файлы** | `driver/build.cmd` (строка линковки, комментарий FIX-8) |
| **Проверка** | Пересборка: импорты `WDFLDR.SYS: WdfVersionBind/Unbind/BindClass/UnbindClass`, точка входа `0x1988`; драйвер загружается, сервис RUNNING, устройство OK; две перезагрузки без сбоя. Дизасм: `dumpbin /IMPORTS`, `kd -z XDMA.sys`. |
| **Статус** | ✅ Исправлено |

## E-02 — Сборка: inf2cat не создавал каталог (22.9.10 / 22.9.7 / 22.9.6)

| Поле | Значение |
|---|---|
| **Симптом** | `inf2cat` → «Signability test failed»: (22.9.10) `xdma.sys missing from [SourceDisksFiles]`; (22.9.7) `DriverVer set to a date in the future` (UTC < локального GMT+3 между 00:00–03:00); (22.9.6) `DriverVer missing or in incorrect format` (RU-локаль заменяла `/` на `.` в `MM/dd/yyyy`). Каталог `XDMA.cat` не создавался → `pnputil` не мог установить пакет. |
| **Первопричина** | INF не содержал `[SourceDisksNames]/[SourceDisksFiles]`; дата штамповалась текущей локальной (`-d "*"`), а формат даты формировался культурозависимо. |
| **Исправление** | `XDMA.inx`: добавлены `[SourceDisksNames]/[SourceDisksFiles]` + `DiskId1`. `FIX-10` в `build.cmd`: дата = вчерашняя UTC, формат через `[Globalization.CultureInfo]::InvariantCulture`. |
| **Файлы** | `driver/XDMA.inx`, `driver/build.cmd` |
| **Проверка** | Полный лог сборки: «Signability test complete. Errors: None», `xdma.cat` создан и подписан (2337 байт). |
| **Статус** | ✅ Исправлено |

## E-03 — build.cmd: legacy sc-create-хвост конфликтовал с PnP-установкой

| Поле | Значение |
|---|---|
| **Симптом** | `build.cmd` в конце копировал `XDMA.sys` в `System32\drivers` и создавал/запускал legacy-сервис (`sc create/start`), из-за чего в системе оставалась вторая копия драйвера вне DriverStore и «залипший» сервис; `pnputil`-обновление версий ломалось. |
| **Исправление** | `FIX-9`: хвост удалён, установка — только через PnP (`install.cmd`/`pnputil`). |
| **Файлы** | `driver/build.cmd` |
| **Проверка** | Повторная сборка не создаёт сервис/копию в System32; установка идёт через DriverStore (`oem10.inf`). |
| **Статус** | ✅ Исправлено |

## E-04 — BSOD #3: WHEA_UNCORRECTABLE_ERROR (0x124) — фатальная ошибка PCIe при тесте DDR3

| Поле | Значение |
|---|---|
| **Дата** | 2026-09-11 05:09:28 (`091126-39734-01.dmp`) |
| **Симптом** | 0x124, Arg1=4 (PCI Express Error). Стек: `pci!ExpressRootPortAerInterruptRoutine → nt!WheaReportHwError → KeBugCheckEx`. Кадров `XDMA.sys` в стеке нет. Случилось во время полного прогона `test_xdma.exe` (тест DDR3). |
| **Первопричина** | `driver.c` без проверки принимал ВТОРОЙ memory-BAR как «окно DDR3» и маппил его. В DFX-сборке второй BAR — это 64-КБ таблица MSI-X (`pf0_msix_cap_table_bir = BAR_3:2`), а DDR3 доступна только через DMA (docs/ADDRESS_MAP.md §1.2). Запись/чтение теста DDR3 попадали в MSI-X BAR → неподдерживаемая транзакция → Completer Abort → фатальный AER → bugcheck 0x124. Измерено через IOCTL: BAR0=0x100000 (1 МБ), второй BAR=0x10000 (64 КБ). |
| **Исправление** | `FIX-11` (driver.c): второй BAR принимается как DDR3-окно только при размере ≥ 16 МБ (`DDR3_MIN_WINDOW_BYTES`); иначе не маппится (Bar2Length=0) и DDR3-запросы сразу возвращают `STATUS_DEVICE_NOT_CONNECTED` без обращения к железу; добавлена диагностика `DbgPrint`. `FIX-12` (test_xdma.c): предполётный опрос BAR через `IOCTL_XDMA_GET_BAR_INFO`; тест DDR3 → `SKIP`, если DDR3-окна нет; тест XADC → `SKIP`, если адрес 0x46000000 вне BAR0; счётчик SKIP в сводке. |
| **Файлы** | `driver/driver.c` (EvtDevicePrepareHardware), `driver/test_xdma.c` (QueryBarInfo, main) |
| **Проверка** | Пересборка v1.1.4.0, установка (`oem10.inf`), `test_xdma.exe ddr3` → `SKIP`, EXIT 0, BSOD нет, устройство OK, число минидампов не изменилось (3). |
| **Статус** | ✅ Исправлено (софтверная причина устранена; см. R-01 — на стороне FPGA остаётся несоответствие битстрима) |

## E-05 — emulate_test.py / edge_cases.py: устаревшая карта адресов

| Поле | Значение |
|---|---|
| **Симптом** | Python-эмуляторы драйвера использовали ЛЕГАСИ-карту: TDOT=`0x40001000`, ICAP=`0x40002000`, «BAR2 = 256 МБ DDR3». Каноническая DFX-карта: HWICAP=`0x40001000`, DFX socket=`0x40002000`, TDOT=`0x40003000`, ICAP=`0x40004000`; MMIO-моста к DDR3 нет. Эмуляция валидировала несуществующую конфигурацию. |
| **Исправление** | Обновлены константы и декодеры обеих моделей (6 регионов AXI-Lite + DDR3 DMA-окно), тест `[BAR2_DDR3]` → `[DDR3_DMA]`, сняты устаревшие комментарии (в т.ч. «RTL BUG: GO overwrites N_IN» — BUG-003 давно исправлен). |
| **Файлы** | `driver/emulate_test.py`, `driver/edge_cases.py` |
| **Проверка** | До: тесты проходили на старой карте. После: `emulate_test.py` → 6 PASS/0 FAIL, `edge_cases.py` → 6 PASS/0 FAIL на канонической карте; `py_compile` OK. |
| **Статус** | ✅ Исправлено |

## E-06 — install.cmd / uninstall.cmd: разбор `pnputil` ломался на локализованной Windows

| Поле | Значение |
|---|---|
| **Симптом** | Скрипты искали в выводе `pnputil /enum-drivers` английские метки `Published Name:` / `Original Name:`. На русской Windows метки — «Опубликованное имя:» / «Исходное имя:» → шаг удаления старого пакета молча ничего не делал, обновление версий драйвера не работало (старый `oemNN.inf` оставался). |
| **Проверка (факт)** | Вывод `pnputil /enum-drivers` на этой машине — полностью на русском. |
| **Исправление** | `FIX-14`: сопоставление только по ASCII-шаблонам (`(oem\d+\.inf)` — published; `xdma\.inf` — original). В `uninstall.cmd` дополнительно добавлено удаление копии `System32\drivers\XDMA.sys` и нормализована нумерация шагов. |
| **Файлы** | `driver/install.cmd`, `driver/uninstall.cmd` |
| **Проверка** | Новый код выполнен вручную на этой машине: корректно найден и удалён застейдженный `oem10.inf` (1.1.3.0) перед установкой 1.1.4.0. |
| **Статус** | ✅ Исправлено |

## E-07 — monitor_temp.py: «0.00 °C» выдавалось за измерение при недоступном XADC

| Поле | Значение |
|---|---|
| **Симптом** | При `raw=0, valid=0` (BUG-031: XADC занят MIG) монитор печатал `0.00 °C / 0.000 V` как обычные данные. Ложные показания. |
| **Исправление** | `FIX-13`: при `valid=0` отсчёт помечается `INVALID (BUG-031)` и выводится `--` (в CSV — пустые поля); если все отсчёты INVALID — предупреждение и код возврата 3; флаг `--allow-invalid` снимает ошибку. |
| **Файлы** | `pytorch_layer/monitor_temp.py` |
| **Проверка** | `py_compile` OK; логика INVALID/exit-code проверена чтением кода; на железе XADC недоступен (SKIP в test_xdma). |
| **Статус** | ✅ Исправлено |

## E-08 — xdma_driver.py: шапка противоречила канонической карте

| Поле | Значение |
|---|---|
| **Симптом** | В шапке модуля: «BAR0 = AXI-Lite … BAR2 = DDR3» — противоречит §1.2 ADDRESS_MAP (в DFX второй BAR занят MSI-X, DDR3 = DMA-only). |
| **Исправление** | Шапка приведена к канонической карте (AXI-Lite = регистры; DDR3 = DMA-каналы h2c/c2h; FIX-11). |
| **Файлы** | `pytorch_layer/xdma_driver.py` |
| **Проверка** | `py_compile` OK; текст согласован с ADDRESS_MAP.md и driver.c. |
| **Статус** | ✅ Исправлено |

## E-09 — (отложено, сторона FPGA) Битстрим на плате не соответствует текущим скриптам

| Поле | Значение |
|---|---|
| **Симптом** | Измерено на железе: BAR0 = 1 МБ, тогда как `scripts/build_dfx.tcl` задаёт `pf0_bar0_size {128}` (128 МБ). Следствия: XADC @0x46000000 недостижим; записи в AXI-Lite (GPIO_TRI, TDOT_N_IN) не залипают (читаются reset/err-значения). |
| **Вердикт** | Не дефект кода: на плате загружен устаревший/иной битстрим. Требуется пересборка в Vivado 2025.2 и перепрошивка (вне области этой правки, требует подтверждения — см. RISK_REGISTER R-01). |
| **Статус** | ⏳ Отложено (требуется действие на стороне FPGA) |

---

## E-10 — Отсутствовали вспомогательные скрипты флоу (Makefile/README ссылались на несуществующие файлы)

| Поле | Значение |
|---|---|
| **Симптом** | `Makefile` цели `artifacts`/`bitstream` указывали на `scripts/gen_bin_mcs.tcl` и `scripts/gen_bitstream.tcl` — обоих файлов не существует; README упоминал `scripts/build.bat` и `scripts/rtl_lint.py` — тоже отсутствуют. Документированный флоу был частично неработоспособен. |
| **Первопричина** | Скрипты-помощники не были закоммичены (вероятно, потеряны при переносе проекта). |
| **Исправление** | Созданы `scripts/gen_bin_mcs.tcl` (ре-экспорт `.bit/.bin/.mcs` + partial из готового `impl_1`, без пересинтеза — цель `make artifacts`) и `scripts/flash_program.tcl` (прошивка SPI-флеша, проверенная последовательность). `Makefile`: `GEN_BITSTREAM` указывает на мастер-скрипт `build_dfx.tcl` (полная пересборка). `README.md`: таблица скриптов и раздел верификации приведены в соответствие с фактическими файлами. |
| **Файлы** | `scripts/gen_bin_mcs.tcl` (новый), `scripts/flash_program.tcl` (новый), `Makefile`, `README.md` |
| **Проверка** | `make build` — проven-путь (build_dfx.tcl); новые скрипты повторяют уже работающий код шага 9 того же скрипта; полный прогон новых целей не выполнялся (многочасовая сборка) — отмечено в R-06. |
| **Статус** | ✅ Исправлено |

---

## E-11 — Плавающий сбой запуска Vivado: «Unknown error occured while verifying the digital signature» (0x80096010)

| Поле | Значение |
|---|---|
| **Симптом** | `make build` → Vivado печатает баннер и падает: `Unknown error occured while verifying the digital signature. Error Code: -2146869232` (= `0x80096010`, TRUST_E_BAD_DIGEST). Платформа/аргументы при этом корректны. |
| **Диагностика** | Лог `Microsoft-Windows-CAPI2/Operational` показал WinVerifyTrust от `vivado.exe` на `C:\AMDDesignTools\2025.2\Vivado\lib\win64.o\xv_netlist.dll` → `TRUSTERROR_STEP_FINAL_OBJPROV` = 0x80096010. При этом `Get-AuthenticodeSignature` даёт **Valid** (подпись AMD, действ. до 2028-02-20; метка времени DigiCert 2025-11-15), а `HashMismatch` по `lib\win64.o` — **0 из 187**. Повторные запуски: 22:46 и 22:49 — сбой; 22:53 и 22:54 — успех (проверки `-> 0`, `TINY_OK`, exit 0). Сбой **плавающий**. |
| **Первопричина (наиболее вероятная)** | Вмешательство антивируса **360 Total Security** (`QHActiveDefense`/`QHSafeTray.exe`, процесс виден в событиях CAPI2) в проверку подписи/чтение файлов; усугубляется «холодным» кэшем цепочки сертификатов. AMD описывает родственные случаи как таймаут проверки подписи (adaptivesupport AR 57386 / offline-темы). |
| **Исправление/митигация** | (1) Добавить в **360 Total Security** исключения: `C:\AMDDesignTools` и `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3` (или временно отключить защиту на время сборки). (2) Просто **повторить** запуск — при повторном прогоне проверка проходит. (3) Держать доступ в интернет (построение цепочки сертификатов), обновить корневые сертификаты Windows. (4) Диагностика: `scripts/check_vivado_signatures.ps1`. |
| **Проверка** | `vivado.bat -mode batch -source <tiny.tcl>` → `TINY_OK`, exit 0 (2026-09-11 22:54); два прогона подряд — успешно. |
| **Статус** | ⚙️ Среда (AD/AV): митигировано; при повторе сбоя — добавить исключения AV |

---

## Отклонённые / снятые гипотезы

| Гипотеза | Как проверена | Вывод |
|---|---|---|
| Баг границ буфера в `EvtIoRead/EvtIoWrite` (PAGE_FAULT_IN_NONPAGED_AREA) | Ревизия кода: проверки `barOffset >= BarNLength || bufferLen > BarLength - barOffset`; тест 0x80000000 при Bar2Length=0 → `STATUS_DEVICE_NOT_CONNECTED` | Не подтверждена: память ядра не повреждается |
| Неисправность слота PCIe/M.2 или платы | Устройство стабильно перечисляется, конфиг-пространство читается, AER-ошибка возникает строго при обращении к BAR2 | Отклонена (на текущем этапе) |
| Конфликт двух XADC | Ранее закрыто проектом (BUG-031, `XADC_En=Off`) | Отклонена |
| Проблема в KMDF-версии/подписи | Драйвер загружается, импорты корректны, подпись принимается (testsigning on) | Отклонена |
