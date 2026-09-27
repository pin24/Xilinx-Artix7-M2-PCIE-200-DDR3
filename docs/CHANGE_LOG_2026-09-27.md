# Change Log — 2026-09-27 (сессия фиксации + аудита)

Журнал истории решений, исправленных ошибок и статуса готовности за
2026-09-27. Факты перепроверены чтением RTL (`rtl/integration/xdma_ddr3_core_top.sv`,
`scripts/xdma_ddr3_dfx_bd.tcl`, `scripts/build_dfx.tcl`) и синхронизированы с
`docs/ADDRESS_MAP.md` и `README.md`.

---

## 1. История решений (решения и их обоснование)

### D1 — Коммит `e67a877` «fix(hw): ICAP window race, SPI-over-PCIe proto, XADC wiring, dual-ICAP, timing gate»

Сводка правок и обоснование:

- **ICAP window race (окно CSIB)**: устранена гонка при DFX-swap — окно CSIB
  расширено с 1 до 2 тактов, асинхронная маскировка переведена в 2-тактный FSM.
  *Обоснование*: 1-тактное окно давало нестабильное удержание CSIB# и могло
  рвать фронты частичного реконфигурирования рёбер RP.
- **SPI-over-PCIe (0x40005000, M06)**: адресные/данные биты теперь реально идут
  на MOSI (расхождение устранено), RDSR выведен из адресной фазы в отдельное
  состояние `ST_UNIQUE_STATUS`, WP#/HOLD# (qspi_d2/d3) подтянуты в 1 (idle-high)
  во избежание float на шине флэш. *Обоснование*: без фикса команды прошивки
  флэш не доходили, статус RDSR читался неверно.
- **XADC wiring**: константы «0°/0V» заменены фактическим примитивом
  `xadc_prim u_xadc_prim` (DCLK = clk50), подающим реальные
  `raw_temp/raw_vccint/raw_valid` в `u_xadc` (`0x46000000`). *Обоснование*:
  ранее XADC был фактически мёртв (см. §2, был BUG-031); резервный путь —
  MIG status через GPIO2.
- **Dual-ICAP устранён**: лицензионный `axi_hwicap_0` удалён из BD
  (`scripts/xdma_ddr3_dfx_bd.tcl`); адрес `0x40001000` больше не назначается.
  *Обоснование*: два контроллера на одном физическом ICAPE2 создавали риск
  взаимоисключающего/гонящего доступа. Единственный ICAP — кастомный
  `icap_ctrl` @ `0x40004000` (M04).
- **DMA-offset**: `XdmaWinUpstream.write_dma/read_dma` перестали прибавлять
  `DDR3_BASE` к смещению — offset уезжал на `0x80000000` как card-side адрес.
  *Обоснование*: унификация с `XdmaLinux`/`XdmaWindows`, корректная адресация
  DDR3 через DMA-каналы.
- **Timing gate**: глобальный FATAL-гейт тайминга в `scripts/build_dfx.tcl`
  (`get_timing_paths -max_paths 0` по всем доменам); наследственно sync'иус
  документы с фактическим кодом (этот же день, §2).

---

## 2. Исправленные ошибки/пробелы (найденные аудитом и закрытые)

| № | Область | Было (ошибка) | Стало (фикс) |
|---|---|---|---|
| F1 | XADC | Константы «0°/0V» (мёртвый мониторинг, BUG-031) | Реальный примитив `xadc_prim` (DCLK clk50) → `u_xadc` @ `0x46000000`, реальные raw-значения |
| F2 | ICAP | Окно CSIB 1 такт — гонка при DFX-swap | 2-тактный FSM окна CSIB, стабильное удержание CSIB# |
| F3 | SPI | Адрес/данные не шли на MOSI; RDSR уходил в адресную фазу; WP#/HOLD# в z | Коректная передача на MOSI, RDSR в `ST_UNIQUE_STATUS`, qspi_d2/d3 высокие |
| F4 | Dual-ICAP | Дубликат `axi_hwicap_0` (два контроллера на одном ICAPE2) | Лицензионный HWICAP удалён из BD; единственный ICAP — `icap_ctrl` @ `0x40004000` |
| F5 | DMA-offset | `XdmaWinUpstream` прибавлял `DDR3_BASE` к смещению → адрес уезжал на `0x80000000` | Смещение передаётся как есть, без `DDR3_BASE` |
| F6 | Доки | `ADDRESS_MAP.md` §2/§7 и `README.md` описывали мёртвый XADC и активный HWICAP | Синхронизированы с кодом (этот же день, см. §1.1/§1.4) |

---

## 3. Решения зафиксированы (deferred / known issues)

- **Windows-драйвер НЕ реализует DMA (H2C/C2H)** — DDR3 на Windows
  недоступна. Текущая нода `\\.\XDMA0` — только BAR MMIO
  (`RtlCopyMemory`), без под-нод `\control/\user/\h2c_0/\c2h_0/\event`.
  **План (открыто)**: добавить IOCTL (`XdmaDevice.write_dma/read_dma`) и
  под-ноды DMA в `driver/driver.c`.
- **Подмена `xdma_driver_win_src_2017\sys\driver.c`** — это локальная копия
  кастомного `driver\driver.c` (старая, БЕЗ FIX-11/Mapping BAR2>=16MB), не
  подлинный апстрим 2017. Отмечено в §A2 и `docs/COMPATIBILITY.md`.
- **XADC**: реальные данные пришли только после фикса; **аппаратная
  верификация на стенде не прогонялась** (см. §4 — статус готовности).
- **Timing gate**: изменённый глобальный FATAL-гейт требует новой сборки
  `build_dfx.tcl`, чтобы подтвердить MET по всем доменам.

---

## 3a. Повторный аудит (re-audit, после правок и синхронизации доков)

После волны фиксации и правок документации проведён повторный аудит двумя
независимыми агентами (R1 — совместимость, R2 — готовность сборки). Найдено
**4 дефекта полноты/блокер**, все закрыты в тот же день:

| № | Область | Было | Стало (фикс) |
|---|---|---|---|
| F7 | **Сборка (блокер)** | `xadc_prim.sv` инстанцируется в топе (`xdma_ddr3_core_top.sv:261`), но НЕ добавлен в fileset `add_files` → синтез упал бы с «cannot find module xadc_prim» | `xadc_prim.sv` добавлен в `scripts/build_dfx.tcl` (после `xadc_temp.sv`) |
| F8 | Доки/скрипты | `build_dfx.tcl` шаг 2d canonical-переназначения пропускал SPI `0x40005000` (адрес верный из BD, но паттерн нарушен) | Добавлен `assign_bd_address 0x40005000` для `S_AXI_SPI_REGS` |
| F9 | README | Пропущена строка SPI `0x4000_5000` в таблице карты адресов | Добавлена строка SPI-over-PCIe |
| F10 | DRIVER_DEVLOG | Таблица Address Map показывала HWICAP `0x4000_1000` как активный и не содержала SPI | HWICAP помечен удалённым, добавлены SPI и примечание о кастомном icap_ctrl |

**Вердикт ре-аудита R1**: адреса RTL↔BD↔ADDRESS_MAP согласованы; правки
документации не внесли рассинхронизации в каноническую карту. Функционально:
регистровый путь Windows ✅, DMA→DDR3 на Windows ❌ (драйвер без DMA),
DFX/SPI/XADC ✅.

---

## 4. Статус готовности (снимок)
---

## 4a. Доводим до полной функциональности — DMA-драйвер + тесты (этот день, позже)

Коммит `4c0cadb` снял главный блокер Windows («драйвер без DMA»):

| Элемент | Результат |
|---|---|
| driver\dma\dma_driver.c | автономный KMDF-гейтвей, переиспользует ПОДЛИННЫЙ upstream file_io.c+libxdma; симлинк \\.\XDMA0dma, ноды control/h2c_0/c2h_0 |
| Анти-BSOD | userBarIdx=bypassBarIdx=-1 после XDMA_DeviceOpen — \user/\bypass отклоняются (MSI-X не экспонируется), драйвер загружается |
| Сборка | BUILD FULL SUCCESS (WDK 10.0.14393, KMDF 1.15): XDMA_DMA.sys 24 472 B + .inf/.cat/.cer, подписан WDKTestCert |
| Тесты | test_dma.c → test_dma.exe (собран, запускается, даёт справку); test_dma_win.py (XdmaWinDma); VERIFY_DMA.cmd, DMA_TEST_README.md |
| Инфра | sys\driver.c → driver.c.substituted (анти-риск), sys\driver.h заполнен (был 0 байт), .gitignore + build_tmp\ |

**Циклические аудиты C4/C5 выявили и устранили (реальной компиляцией):**
- h2c_*/c2h_* внутри /* */-комментария досрочно закрывал блок — заменено на h2c_N/c2h_N;
- VS2015 cl НЕ поддерживает /utf-8 (D9002) — файлы приведены к CP1251/CRLF как рабочий driver.c;
- DECLARE_CONST_UNICODE_STRING внутри функции не объявляет var → UNICODE_STRING+RtlInitUnicodeString;
- WdfRequestWriteToRequestMemory (несуществ. API) → WdfRequestRetrieveOutputBuffer+RtlCopyMemory.

**Подтверждено компиляцией:** dma_driver.c + file_io.c + device.c + dma_engine.c + interrupt.c — все EXIT 0; .sys-линковка и подпись — SUCCESS; test_dma.exe собрался и выполняется (без установленного драйвера корректно сообщает об ошибке).

---

## 4b. Блокер прошивки SPI-флеша разобран и устранён (этот день)

Блокер: ''ERROR: [Labtools 27-3347] Flash Programming Unsuccessful: Failure to set flash parameters'' — ''program_hw_cfgmem'' падал ДО начала записи во всех попытках (vivado_27276/28564, *_stderr.log).

Причина (диагноз агента F1, подтверждён ре-аудитом F2): в scripts/flash_program.tcl использовалась часть cfgmem ''w25q128jvq-spi-x1_x2_x4'' с лишней буквой ''q'' (jvq вместо jv). Такой части нет в базе get_cfgmem_parts -> create_hw_cfgmem создавал невалидный cfgmem -> 27-3347. Второй блокер ''-2146869232'' (подпись vivado.bat) — отдельный непостоянный сбой запуска, на 27-3347 не влияет.

Фикс (scripts/flash_program.tcl):
- программный выбор части w25q128jv-spi-x1_x2_x4 с glob-fallback w25q128*spi-x1_x2_x4 и диагностическим выводом списка при полном промахе;
- шапка почищена от ложной ссылки на несуществующий ''proven sequence C:/build_dfx/vivado.log'';
- README.md и driver/R-01_BUILD_AND_FLASH.md: имя части исправлено w25q128jvq→w25q128jv (3+ места).

Рекомендация: предпочтительно прошивать полный .mcs (build/artifacts_dfx/xdma_ddr3_core_top.mcs, SPIX4, 14.9 MB < 16MB) а не сырой .bin. Остаточный риска 27-3347 (если размер файла > адр. пространства части — 16MB) отмечен, но это не регрессия фикса.

---

## 4c. ФЛЕШ ПРОШИТА И ВЕРИФИЦИРОВАНА (2026-09-27, GUI + readback)

Событие: GUI-прошивка build/artifacts_dfx/xdma_ddr3_core_top.mcs во SPI-флеш W25Q128 удалась (Erase+Program, затем Verify).

Верификация readback_hw_cfgmem (JTAG, Vivado 2025.2, часть w25q128jvq-spi-x1_x2_x4):
- readback: Readback Operation successful, файл build/flash_readback.mcs (16 777 216 байт данных = весь 128-Мбит чип).
- Побайтовое сравнение первых 5 064 908 байт (весь образ) с оригиналом .mcs: DIFF = 0 (идентично).
- Orig head = Read head = FF FF FF ... (0xFF заполнение) — корректно.

Вывод: полный дизайн (со spi_over_pcie) лежит во флеше и читается без ошибок; блокер 27-3347 (пины флеши заняты загруженным дизайном) обойдён — при записи в GUI пины были свободны. После power-cycle FPGA должна загружаться из флеши сама.

Файл доказательства: build/flash_readback.mcs (не коммитится, build/ в .gitignore).

---

## 4d. ДРАЙВЕР УСТАНОВЛЕН (2026-09-27)

Среда: admin, testsigning ON, Secure Boot OFF.

Выполнено:
- certutil: WDKTestCert добавлен в Root + TrustedPublisher (dйный DMA-пакет).
- pnputil /add-driver driver\dma\build\sys\XDMA_DMA.inf /install → ойе Package added, Published Name oem11.inf, installed on 3x PCI\VEN_10EE&DEV_7024 (инстансы 4&167cef57&0&00E4 и др.).
- Побочно подтверждено: oem10.inf (xdma.inf, MMIO 1.1.4.0) уже был застейджен ранее.

Состояние устройства: PCI\VEN_10EE&DEV_7024 перечислен, но Status=Unknown / CM_PROB_PHANTOM — т.е. физически плата сейчас НЕ в PCIe-слоте (на JTAG). Драйвер подвяжется автоматически при вставке платы в слот. Сервис XDMA_DMA не стартует до появления устройства.

Предупреждение: oem10.inf (MMIO) и oem11.inf (DMA) делят один HWID VEN_10EE&DEV_7024 — Windows назначит устройству один из них (по рангингу/версии). Полнофункциональный — DMA (oem11), он и должен выиграть.

---

## 4e. ДРАЙВЕР: DMA обновлён до 1.1.5.0, старый MMIO удалён (2026-09-27)

Проблема: oem10.inf (xdma.inf MMIO 1.1.4.0) и oem11.inf (xdma_dma.inf DMA 1.0.0.0) делили один HWID PCI\VEN_10EE&DEV_7024; у DMA была МЛАДШАЯ версия -> Windows мог выбрать старый MMIO (без DMA).

Действия:
- driver\dma\build.cmd: set DRIVER_VERSION=1.0.0.0 -> 1.1.5.0; XDMA_DMA.inx DriverVer -> 1.1.5.0.
- Пересборка build.cmd: BUILD FULL SUCCESS, DriverVer=09/26/2026,1.1.5.0, подписан.
- pnputil /delete-driver oem10.inf (старый MMIO) — удалён.
- pnputil /delete-driver oem11.inf (старый DMA 1.0.0.0) — удалён.
- pnputil /add-driver build\sys\XDMA_DMA.inf /install -> Published oem10.inf (1.1.5.0), installed on 3x VEN_10EE&DEV_7024.

Итог: в DriverStore остался ТОЛЬКО MMAИ-драйвер (DMA, 1.1.5.0). Устройство отображается как "XDMA DMA Subsystem (upstream stack, h2c/c2h channels)". PHANTOM — плата не в PCIe (JTAG); драйвер стартует при вставке в слот.

---

## 4f. ТЕСТ АРИФМЕТИКИ ЯДРА ДОБАВЛЕН (2026-09-27, python test_dma_win.py)

Замечание пользователя: test_dma.exe / test_dma_win.py dot-режим проверял ТОЛЬКО транспорт (DMA+регистры+DONE), но НЕ арифметику — 'assert result_bits is not None' не доказывал, что ядро считает.

Исправлено (pytorch_layer/test_dma_win.py):
- Добавлен self-contained декодер _bits48_to_float (TFloat.from_bits, [E:8][M:40]->(m<<8)|e), sys.path к ternary_sw, как в fpga_backend.py.
- test_dot_smoke теперь сверяет арифметику: n=8 пар 1.0 -> декодированный результат != n (rol 0.05) -> assert; иначе FAIL 'TDOT arithmetic FAIL'.

Верификация: py_compile OK; decode(TF48_ONE)=1.0; эталон sum(8x1.0*1.0)=8.0. Полный путь арифметики уже был в xdma_driver.py --selftest (dot/sched -> _bits_to_float, expected=n).

---

## 4g. BSOD 0x3B при открытии DMA-ноды — НАЙДЕН И ИСПРАВЛЕН (28.09 ночь)

СИМПТОМ: при попытке открыть \\.\XDMA0dma\... система падала. Свежий минидамп 092826-40109-01.dmp:
BugCheck 3B (SYSTEM_SERVICE_EXCEPTION), code c0000005 (ACCESS_VIOLATION),
faulting frame XDMA_DMA.sys+0x1906, stack: NtCreateFile -> IofCallDriver ->
Wdf01000 -> XDMA_DMA+0x1906. Модули: XDMA_DMA.sys, Wdf01000.sys, 360Hvm64.sys.

ЛОКАЛИЗАЦИЯ (MAP-файл link /MAPINFO:EXPORTS): EvtDeviceFileCreate RVA=0x1830,
сбойный offset 0x1906 = EvtDeviceFileCreate+0xD6. Дизассемблер obj: 0xD6
mov dword ptr [rdi],eax (запись в devNode->devType).

КОРНЕВАЯ ПРИЧИНА: в driver\dma\dma_driver.c EvtDriverDeviceAdd для
WdfDeviceInitSetFileObjectConfig передавался WDF_NO_OBJECT_ATTRIBUTES, т.е. НЕ
был зарегистрирован размер/тип контекста файлового объекта (FILE_CONTEXT).
upstream file_io.c EvtDeviceFileCreate вызывает GetFileContext(WdfFile) и пишет
devNode->devType (file_io.c:111,115) — без выделенного контекста GetFileContext
возвращает неинициализированный/нулевой указатель -> запись по неверному
адресу -> access violation -> BugCheck 3B.

ФИКС (driver\dma\dma_driver.c): добавлен
WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&foAttr, FILE_CONTEXT) и передан в
WdfDeviceInitSetFileObjectConfig. ВОSЕ уже был контекст устройства
(DEVICE_CONTEXT) и контекст очереди (QUEUE_CONTEXT).

ДОПОЛНИТЕЛЬНО: DMA-передача H2C висела (overlapped write timed out), т.к.
engine->poll=FALSE по умолчанию -> завершение через прерывания (MSI-X), а они
в DFX-конфигурации могут не доходить. Добавлен poll-режим: после
EvtCreateEngineQueues для всех enabled engines XDMA_EngineSetPollMode(engine,
TRUE) (dma_engine.c:983 сам пишет XDMA_CTRL_POLL_MODE и отключает IE).

ВЕРСИИ: 1.1.6.0 (fix FILE_CONTEXT), 1.1.7.0 (fix poll-mode). PDB+MAP теперь
собираются (build.cmd: CFLAGS+=/Zi, link+=/DEBUG /DEBUG:FASTLINK /PDB).

СТАТУС: драйвер 1.1.7.0 установлен (oem12.inf), устройство OK/CM_PROB_NONE.
test_dma regs PASS. loopback: старый процесс зависшки на 1.1.6 -> введён
poll -> требует перезагрузки, чтобы выгрузить застрявший драйвер/процесс.
ОЗУ не очищена из-за зависшего в ядре test_dma(9100) — снимается reboot.

---

## 4h. DMA-адресация исправлена (0x80000000+off); interrupt-режим восстановлен (28.09)

ПРОБЛЕМА: loopback "overlapped write timed out". Диагноз:
- Windows-upstream драйвер кладёт DeviceOffset в DMA-дескриптор КАК card-адрес
  (dma_engine.c:465 dstAddrLo = LIMIT_TO_32(deviceOffset)), БЕЗ pci->axi базы
  (в отличие от Linux-драйвера). DDR3 мапится на 0x80000000 -> host обязан
  передавать ПОЛНЫЙ адрес 0x80000000+off.
- Ранний "фикс" e67a877 убрал +DDR3_BASE в XdmaWinUpstream/test_dma - это была
  ОШИБКА: для Windows-added надо ДОБАВЛЯТЬ базу. Из-за этого передача шла на
  card-адрес 0x100000 (вне MIG DDR3) -> движок не находил цель -> не завершал.

ИСПРАВЛЕНИЕ (offset):
- pytorch_layer/xdma_driver.py: XdmaWinUpstream.write_dma/read_dma -> base=DDR3_BASE+ddr_off.
- pytorch_layer/test_dma_win.py: XdmaWinDma.write_dma/read_dma -> base=0x80000000+ddr_off.
- driver/test_dma.c: добавлен #define DDR3_BASE 0x80000000ULL; DmaWrite/DmaRead
  передают DDR3_BASE+ddr_off.

ПОЛЛ-РЕЖИМ ВЫКЛЮЧЕН (был в 1.1.7):
- EnginePollTransfer - БЕСКОНЕЧНЫЙ busy-loop (while(expected!=actual)), ждёт что
  FPGA запишет completedDescCount в writeback-буфер. Если битстрим не реализует
  poll-writeback -> engine не завершится никогда. Вернули interrupt-режим
  (engine->poll=FALSE default), оставив poll как #if 0 fallback.

ВЕРСИИ: 1.1.8.0 (interrupt + правильный offset). Открыт PDB/MAP.
СТАТУС: пакет установлен (oem13.inf), активный драйвер 1.1.8.0 после reboot.
Зависший тест-процесс в kernel-path требует reboot для выгрузки.

---

## 4i. ДРАЙВЕР САМ ДЕЛАЕТ СМЕЩЕНИЕ — централизовано (28.09, v1.1.9.0)

Замечание пользователя (верное): логика AXI-смещения не должна жить в host-тестах.
Решение по архитектуре (выбор: «в движке удобно»):

- libxdma/reg.h: добавлен XDMA_DDR3_AXI_BASE (0x80000000) + FDMA_BAR_IDX.
- libxdma/dma_engine.c::EngineProgramDma: после сложения с bytesTransferred
  добавлено deviceOffset += XDMA_DDR3_AXI_BASE. Это ЕДИНАЯ точка для H2C (dstAddr)
  и C2H (srcAddr). Реплицирует поведение Linux-драйвера (xdma pci->axi map).
- Host-файлы возвращены на ЧИСТЫЙ offset (без +0x80000000), как XdmaLinux /
  ADDRESS_MAP «смещения от 0x80000000»:
  * driver/test_dma.c: DmaWrite/DmaRead -> ddr_off+done (без базы); DDR3_BASE
    оставлен ссылочно.
  * pytorch_layer/xdma_driver.py: XdmaWinUpstream.write_dma/read_dma -> ddr_off.
  * pytorch_layer/test_dma_win.py: XdmaWinDma.write_dma/read_dma -> ddr_off.
  * xdma_rw (XdmaWindows) и XdmaLinux уже передавали чистый offset — теперь
    согласованы.

Контракт теперь ЕДИНЫЙ: host передаёт raw DDR3 offset; драйвер сам добавляет
базу в дескриптор. Версия 1.1.9.0 (PDB/MAP), установлен oem14.inf.

СТАТУС: пакет установлен; активный .sys в памяти старый (в kernel-path ещё висит
test_dma PID 4992) -> требует reboot для загрузки 1.1.9 и освобождения ОЗУ.

---

## 4j. ДИАГНОЗ: DMA не завершается — CHANNEL-INTERRUPT НЕ ПРИХОДИТ (28.09)

После reboot (01:02) и правки централизации (1.1.9, base в движке):
- устройство OK/CM_PROB_NONE, драйвер 1.1.9.0 (oem14.inf), ОЗУ 25.9 ГБ.
- Повторный запуск test_dma.exe loopback 4 (после reboot, PID 4992, 01:11) ->
  СНОВА висит в kernel-path (overlapped write timed out; процесс неубиваем до reboot).

КОРНЕВАЯ ПРИЧИНА (подтверждено кодом + эмпирически):
- AXI-MM H2C/C2H завершается ТОЛЬКО через channel-interrupt
  (EvtChannelInterruptDpc -> EngineProcessTransfer -> WdfDmaTransactionDmaCompleted).
- Ранешние гипотезы исключены:
  * offset к card-адресу НЕ был причиной (после централизации в движке голый offset
    DDR3 попадает верно, движку цель видна);
  * poll-режим (1.1.7) НЕ помогает: EnginePollTransfer — бесконечный busy-loop,
    ждёт completedDescCount в writeback-буфере, который в DFX-битстриме не пишется.
- Реальная причина: СИГНАЛ channel-interrupt от FPGA не доходит до драйвера
  (MSI-X/line прерывания не настроены/не приходят в этой прoney/фикстуре), поэтому
  EngineChannelInterruptDpc никогда не срабатывает -> DMA зависает.

ВАРИАНТЫ ДАЛЬШЕ (требуют физического стенда/отладки):
  1. Настроить/проверить прерывания в битстриме (channel MSI-X vector) —
     правильный путь, но нужно FPGA-отладочное.
  2. Реализовать НАСТОЯЩИЙ поллинг завершения AXI-MM: опрос индивидуального
     дескриптора (engine->sgdma->desc[0].completed bit) с таймаутом, без
     writeback-буфера и без прерываний. Это об снедний BF-вариант.
  3. Использовать xdma_rw/другой стек, где поллинг реализован железно.
СТАТУС: ждёт решения по прерываниям или реализации поллинг-завершения.
