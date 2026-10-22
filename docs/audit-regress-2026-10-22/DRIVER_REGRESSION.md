# Регрессионный аудит XDMA-драйвера tdot (1.2.7.0 → 1.2.7.6)

**Дата:** 2026-10-22
**Репозиторий:** `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3`
**База (рабочая версия):** `fdf6dad` (v1.2.7.0 — «sleep вместо spin в DMA wait»)
**HEAD:** `31acbfe` (v1.2.7.6 — BIT31 channel reset default OFF)
**Окно диффа:** `git diff fdf6dad..HEAD -- xdma_driver_win_src_2017/ driver/dma/`

**Ограничение исполнения (соблюдено):** запись в плату ЗАПРЕЩЕНА. Выполнен только
read-only статический анализ + `git log`. Ничего в production-файлы не внесено, ни одного
регистра/дескриптора на плате не тронуто, билды не запускались. Отчёт — этот файл.

---

## 0. Резюме (TL;DR)

| Приоритет | Находка | Файл | Суть |
|---|---|---|---|
| **HIGH** | **Double-complete race (BSOD 0x10D/UAF)** в окне «timeout-финализатор ∩ cancel» | `sys/file_io.c:1091-1119` (EvtCancelDma) + `sys/file_io.c:884-890` | Новый `pollTimeout`-путь в `EvtCancelDma` заставляет cancel финализировать `Release`+`Complete`, НО timeout-ветка `EvtIoWriteDma/ReadDma` с фикса 2026-10-21 ТОЖЕ завершает. Оба проходят гварды → двойной `WdfDmaTransactionRelease`/`WdfRequestComplete` |
| **MED-HIGH** | **Бит reset канала BIT31 = Reserved/no-op** — аппаратная часть `XDMA_EngineResetChannel` ничего не сбрасывает | `libxdma/dma_engine.c:1239-1244`, `reg.h:74` | Реальный канальный Control bit31 — Reserved (PG195 v4.x: поля 31:28 reserved). Запись no-op; фактически работает только soft-путь, который (по AUDIT_H2C_WEDGE) BUSY не снимает. Совпадает с результатом стенда (1.2.7.5/6). По умолчанию выключено — корректно |
| **MED** | **`actual >= expected` против накопительного `completedDescCount`** — ложный «успех» | `libxdma/dma_engine.c:1685` (WaitCompletion), `:558` (watchdog) | Счётчик программно никогда не сбрасывается; корректность зависит от того, сбрасывает ли его IP при EngineStart/firstDesc. На рабочем одиночном пути эмпирически сбрасывается, но сравнение нужно вести по ДЕЛЬТЕ |
| **MED** | **IOCTL `XDMA_CHANNEL_RESET` без владения txnDone/крит. секции** | `sys/file_io.c:712-720` | `XDMA_EngineResetChannel` вызывает `RtlZeroMemory` банка + `perfCtrl=0` вне владения транзакцией; защита — только sequential-очередь (хрупко: IOCTL на DMA-очереди vs poll-поток) |
| **LOW** | **Новый IOCTL 0x7 сломал обратную совместимость пользовательских буферов? (нет)** | `inc/xdma_public.h:75`, `file_io.c:688-697` | METHOD_BUFFERED, `WdfRequestRetrieveInputBuffer` — безопасно. Старый хост не ломается (новый код — только отклик). Проверка `inLen` асимметрична (`<`), а не `!=` — допустимо для buffered |
| **LOW** | **Устаревшие/противоречивые комментарии** | `dma_engine.c:819-821`, `dma_engine.h` (txnTimeout «poll-owner will NOT complete»), `WaitCompletion:1728` | Комментарий противоречит фактическому завершению в timeout-пути |
| INFO | **IP-версия = XDMA 4.2, не «PG195 v4.1»** | `scripts/xdma_ddr3_bd.tcl:116,431` | PG195 — номер документа; IP в flat BD — `xilinx.com:ip:xdma:4.2` |

---

## 1. `sys\file_io.c` — корректность владения, порядок Exit-шагов, риски

### 1.1 Дифф (1.2.7.0 → 1.2.7.6)
- `EvtIoWriteDma`/`EvtIoReadDma`: добавлен `engine->txnTimeout = FALSE` при старте
  нового переноса (`file_io.c:754`, `:912`).
- В timeout-ветке (после `EngineStop`, `file_io.c:870-883` и `:1009-1022`): вместо
  `if (!owner) return;` теперь `TraceInfo` + **продолжение**, и вызов
  `XDMA_EngineResetChannel` при `channelResetOnTimeout`.
- `EvtCancelDma` (`file_io.c:1091-1119`): добавлен разбор `pollTimeout = engine->txnTimeout`
  и переход по `ownTxn || pollTimeout`.

### 1.2 Владение `txnDone`/`isReqPending`/`txnTimeout` — штатный успешный путь — OK
Штатный успех: poll → `XDMA_EngineWaitCompletion` возвращает SUCCESS → `EngineProcessTransfer`
завершает request синхронно (`file_io.c:404`), в EvtIo* — `morePackets==FALSE` → `return`
(`file_io.c:832-833`). `txnTimeout` здесь не выставляется (только в причине success условия
`actual>=expected`). Взаимное исключение DPC/poll по CAS `txnDone` (`dma_engine.c:344-354`).
Не регрессировано.

### 1.3 Штатный timeout (без cancel) — завершается один раз, НО тянет риск из 1.4
Timeout: `WaitCompletion` → CAS `txnDone=TRUE`, `txnTimeout=TRUE`, `STATUS_TIMEOUT`
(`dma_engine.c:1726-1737`). EvtIo*: `status=TIMEOUT` → `break` → блок `:849-871`:
`owner = !txnDone = FALSE` (уже забран поллом) → НЕ делает второй CAS (корректно),
`EngineStop`, `if (channelResetOnTimeout) XDMA_EngineResetChannel` (default OFF → пропуск),
`UnmarkCancelable` → SUCCESS → `Release` + `Complete(STATUS_TIMEOUT)` — **один раз**. OK.

### 1.4 **HIGH: Double-complete race при «cancel ∩ timeout»**

**Механизм (CONFIRMED, уровне кода).** Два потока одновременно проходят свой гвард и оба
финализируют:

- Поток A — timeout-финализатор `EvtIoWriteDma/ReadDma` (`file_io.c:884-890`):
  `uc = WdfRequestUnmarkCancelable(Request)`; если `uc == STATUS_SUCCESS` → A выполняет
  `WdfDmaTransactionRelease` + `WdfRequestComplete(STATUS_TIMEOUT)` и завершает.
- Поток B — `EvtCancelDma` (`file_io.c:1091-1119`), вызван WDF из-за пользовательского cancel.

WDF гарантирует атомарность `WdfRequestUnmarkCancelable`: **ровно один** из A/B получит
`STATUS_SUCCESS`, другой — `STATUS_CANCELLED`. Рассмотрим оба исхода:

- Если A получает SUCCESS (B — CANCELLED): A идёт на `Release`+`Complete`. В B:
  `st==STATUS_CANCELLED && !ownTxn(FALSE→TRUE, т.к. txnDone уже TRUE) && !pollTimeout`.
  **`pollTimeout` всё ещё TRUE** (A не сбрасывал `txnTimeout` нигде в timeout-пути) →
  гвард не срабатывает, B идёт дальше: `ownTxn || pollTimeout` = TRUE →
  `EngineStop` + `WdfDmaTransactionRelease` + `WdfRequestComplete(STATUS_CANCELLED)`.
  → **двойной Release + двойной Complete** на один request / один engine->dmaTransaction.
- Если B получает SUCCESS (A — CANCELLED): B — единственный финализатор (A вернулся на
  `:886`). ОК-вариант — этот путь задуман корректно.

**Вывод:** когда cancel влетает в окно финализации timeout-ветки, оба пути завершают один
и тот же request/транзакцию → UAF / BugCheck 0x10D / 0xE6. Это ровно тот сценарий, что
тесты «гонка cancel∩timeout под Driver Verifier» обязаны ловить (CHANNEL_RESET_DESIGN §7 п.5).

**Первопричина:** обе ветки построены на **несовместимых предположениях**:
- Фикс 2026-10-21 (aee457e): «poll-владелец (timeout) ТЕПЕРЬ завершает request» — Jереализовано
  в сохранившихся `Release`+`Complete` timeout-ветки.
- Фикс 2026-10-22 (31acbfe): комментарий и `txnTimeout` по-прежнему утверждают «poll-owner
  will NOT complete» (`dma_engine.c:1728`, `dma_engine.h`), из-за чего `EvtCancelDma`
  финализирует при `pollTimeout` — это верно ТОЛЬКО если timeout-ветка НЕ завершает.

**Правило (что должно быть):** cancellable-flag — единственный общий примитив. Тот, кто
выиграл `UnmarkCancelable` (SUCCESS), финализирует; тот, у кого `STATUS_CANCELLED` — отдаёт
руку сопернику и **возвращается**. В `EvtCancelDma` условие
`st == STATUS_CANCELLED && !ownTxn && !pollTimeout → return` надо заменить на
`st == STATUS_CANCELLED → return` (переиспользовать БЕЗ `pollTimeout`), тогда как
`ownTxn` (факт CAS-владения) останется единственным разрешением на финализацию.
Правильный сигнал «cancel должен завершить» — это `ownTxn`, наследованный от CAS `txnDone`
под `engineLock`, а НЕ «txnTimeout установлен».

### 1.5 `packet >= XDMA_MAX_WDF_PACKETS` и `STATUS_CANCELLED` в цикле — OK
`file_io.c:813-837`: при `STATUS_CANCELLED` из WaitCompletion — `return` (владелец — DPC/cancel),
без троганий. При исчерпании пакетов (`:838-843`) — `status=STATUS_IO_TIMEOUT`, затем блок
владения. Не регрессировано (изменения 1.2.7.x касаются только timeout-хвоста).

---

## 2. `libxdma\dma_engine.c/.h`

### 2.1 `EngineProcessTransfer` — добавлено `txnTimeout=FALSE` при CAS
`dma_engine.c:347`: при успешном входе (`!already`) ставит `txnDone=TRUE` и **сбрасывает
`txnTimeout=FALSE`**. Это корректно: DPC/интеррупт-вход — легитимный владелец, никакого
timeout-флага ему не нужно. OK.

Нюанс: если CAS-владельцем является timeout-пол и затем происходит гонка с DPC, DPC
не пройдёт (txnDone уже TRUE). Владельцем остаётся timeout-путь — согласуется с §1.

### 2.2 `XDMA_EngineWaitCompletion` — `actual >= expected` на накопительном счётчике

```c
// dma_engine.c:1659                    expected = engine->numDescriptors;   // свежий — кол-во дескр. ЭТОГО переноса
// dma_engine.c:1678-1685               actual = engine->regs->completedDescCount;  // НАКОПИТЕЛЬНЫЙ
//                                      if (hwDone && actual >= expected) { EngineProcessTransfer; SUCCESS; }
```

`expected = numDescriptors` задаётся заново в каждом `XDMA_EngineProgramDma`
(`dma_engine.c:1096`). `completedDescCount` — регистр SGDMA-канала, нигде в драйвере
программно НЕ обнуляется (единственные записи `firstDescLo/Hi/Adj` — не в сам счётчик;
`EngineResetChannel` только ЧИТАЕТ его на `:1250`; `XDMA_EngineResetIdle` тоже только читает
на `:1187`).

**Вердикт по «ложному успеху»:** сравнение `>=` против потенциально-накопительного счётчика
дает ложный «успех», если счётчик НЕ сбрасывается самим IP (на записи `firstDesc`/`RUN`).
В такой ситуации первая итерация полла следующего переноса уже видит `actual >= expected` от
ПРЕДЫДУЩЕГО переноса и (при `!BUSY`) мгновенно завершает, не дожидаясь передачи.

**Почему на плате «не проявилось»:** рабочий одиночный путь (1 MiB chunk = 1 пакет) на
живом железе НЕ возвращает мгновенный «ложный успех» (данные сходятся, замеры реальные,
~10-сms переносы). Это эмпирически доказывает, что на данном битстриме счётчик
**сбрасывается** движком при (пере)старте/firstDesc. Т.е. сейчас — латентная хрупкость,
а не активный дефект штатного пути.

**Опасный сценарий (где проявляется):** multi-packet IRP (BUG-060/D-2, `file_io.c:835-837`).
На промежуточном пакете `EngineProcessTransfer` перевооружает txnDone=FALSE с `morePackets=TRUE`,
полл идёт на следующую итерацию. Если счётчик накопительный и перезапуск пакета его НЕ
обнуляет → следующий пакет мгновенно «успешен» (см. выше) → данные не переданы, а IRP
завершён. Multi-packet сейчас достигается только для IRP >8 MB или фрагментации HAL —
маловероятно при DMA_CHUNK=1 MiB.

**Корректное сравнение (рекомендация):** зафиксировать стартовое значение на старте
переноса (`startCount = completedDescCount` перед `EngineStart`, под `engineLock`), а условие
вести по **дельте**: `(actual - startCount) & mask >= expected`, где `mask` — для
переполнения 32-бит. Либо явно писать `completedDescCount` (W1C) в 0 на старте — если IP это
поддерживает. Для подтверждения «сбрасывает ли IP» нужен read-only замер: два последовательных
переноса по 1 дескриптору и чтение счётчика между ними.

### 2.3 `XDMA_EngineResetChannel` — что именно пишет, риски

```c
// dma_engine.c:1231-1274
controlW1C = RUN_BIT;                 // (1) EngineStop — правда
#if XDMA_CHANNEL_RESET_HW_BIT         // (2) HW-reset по умолчанию ВКЛ
controlW1S = XDMA_CTRL_RST;           //      пишет БИТ31 канального Control
controlW1C = RUN_BIT;
MemoryBarrier();                      //      САМОСБРАСАЕМОСТИ/WAIT НЕТ
#endif
statusRC;                             // (3) read-clear BUSY
completedDescCount;                   // (4) наблюдение (read-only)
firstDescLo/Hi = descBuffer;          // (5) re-arm
firstDescAdj = 0;
RtlZeroMemory(банк);                  // (6) зачистка 64KiB
perfCtrl = 0;                         // (7) сброс perf
MemoryBarrier();
```

**Про BIT31:** канальный Control регистр SGDMA (PG195 v4.x) — поля 31:28 **Reserved**.
Запись `controlW1S = BIT31` — это no-op на реальном IP (сам проект подтвердил на стенде:
«BIT31 = reserved/no-op на этом битстриме»). То есть **аппаратный сброс в `XDMA_EngineResetChannel`
безвреден-но-бесполезен**: он не сбрасывает ни FSM движка, ни SMC/MIG, ни BUSY. Что остаётся
функционального — soft-путь (EngineStop + read-clear + re-arm + zero-банк), а AUDIT_H2C_WEDGE
(§2.4/H3/H4) прямо доказал: soft-путь BUSY из застрявшего write-FSM НЕ снимает.

**Риск зависания внутри функции:** реестр №1 — `XDMA_EngineResetChannel` **не ждёт**
self-clear бита и не имеет timeout/retry. Она пишет W1S reserved-бит, W1C, `MemoryBarrier()` —
не блокируется. Реестр пишутся через MMIO (config BAR) — не могут зависнуть программно
(нет busy-wait по аппаратному регистру-флагу), в отличие от `WaitCompletion`. Так что
«зависание внутри ResetChannel» не вижу — она конечна. Риск не в зацикливании, а в
бесполезности HW-части + побочном `RtlZeroMemory` банка (ниже).

**`RtlZeroMemory` банка вне владения (IOCTL-путь):** см. §3.4. В timeout-пути банк чистится
до `Release` и после CAS-владения — допустимо. В IOCTL-пути — потенциально на «живой»
следующей передаче, если нарушится сериализация.

### 2.4 Поле `channelResetOnTimeout`
- Текущее default: **FALSE** (`dma_engine.c:822`). Запись TRUE — только через IOCTL
  `AUTO_ON` после валидации HW на стенде. **Это правильная и безопасная позиция.**
- Комментарий на `:819-821` («включён по умолчанию») — **устарел**, противоречит коду.
- Гонка состояния: поле читается в timeout-ветке без взятия (после `engineLock` только в
  IOCTL). BOOLEAN-чтение неделимо, но нет «грязного» сценария — наихудший случай — устаревшее
  значение на один перенос. LOW.

### 2.5 Параллели с watchdog-полем — тот же `actual >= numDescriptors`
`dma_engine.c:558` (`EvtDmaWatchdogTimer`) использует то же `hwDone && actual >= engine->numDescriptors`.
Вердикт тот же, что в §2.2 (не активен в штатном 1-пакетном пути, но хрупко).

---

## 3. `inc\xdma_public.h` — новый IOCTL 0x7

### 3.1 Код/размер/метод
```c
#define XDMA_IOCTL(i) CTL_CODE(FILE_DEVICE_UNKNOWN, i, METHOD_BUFFERED, FILE_ANY_ACCESS)  // :63
#define IOCTL_XDMA_CHANNEL_RESET XDMA_IOCTL(0x7)   // :75
typedef struct { ULONG Flags; } XDMA_CHANNEL_RESET;  // :94-97
```
- METHOD_BUFFERED — WDF копирует user-буфер в системный; **`ProbeForRead/ProbeForWrite`
  здесь не нужны** (уже делает стек буферизации). ✓
- Дубликатов кодов 0x0..0x6 нет; 0x7 уникален. ✓
- Хостовая константа python: `(0x22<<16)|(0<<14)|(0x7<<2)|0 = 0x22001C` — совпадает с
  `CTL_CODE(FILE_DEVICE_UNKNOWN,7,METHOD_BUFFERED,ANY)` = `(FILE_DEVICE_UNKNOWN<<16)|(ANY<<14)|(7<<2)|METHOD_BUFFERED`. ✓

### 3.2 Валидация входа (`file_io.c:688-697`)
```c
status = WdfRequestRetrieveInputBuffer(request, sizeof(in), (PVOID*)&in, &inLen);
if (!NT_SUCCESS(status)) break;
if (inLen < sizeof(in)) { status = STATUS_BUFFER_TOO_SMALL; break; }
```
- Проверка `inLen < sizeof(in)` (а не `!=`). Для METHOD_BUFFERED более длинный входной буфер —
  допустим (читаем первые 4 байта). ✓
- `in` — локальная структура, `WdfRequestRetrieveInputBuffer` возвращает системный буфер →
  копия в стек. Безопасно. ✓

### 3.3 Обратная совместимость
- Старый хост не шлёт 0x7 → case не выполняется → без изменений. ✓
- Новый хост на старом драйвере: получит `STATUS_NOT_SUPPORTED` из `default` — корректно. ✓

### 3.4 **MED: `XDMA_EngineResetChannel` на IOCTL-пути вне владения транзакцией**
`file_io.c:712-720`, `NOW`-флаг: вызывается `XDMA_EngineResetChannel` БЕЗ захвата `txnDone`
и БЕЗ критической секции на время операции. Защита декларируется последовательной очередью
движка («IOCTL сериализуется после in-flight DMA»). Это верно для `WdfIoQueueDispatchSequential`
в самой очереди, НО:
- poll-поток (`EvtIoWriteDma`/`EvtIoReadDma`) синхронно ждёт завершение внутри своего IRP —
  sequential-очередь не отдаст IOCTL, пока этот IRP не завершился. Т.е. на практике сериализация
  держится. Тем не менее полагаться на неё как на единственный примитив безопасного
  `RtlZeroMemory` банка/`perfCtrl=0` — хрупко: любой будущий async-путь (v1.1.33 REDUCED-ASYNC
  уже откачен, но идеи живы) сломает инвариант.
- Рекомендация: в `NOW`-ветке взять `engineLock` вокруг `XDMA_EngineResetChannel` (как это
  делают другие пер-движковые IOCTL) или добавить протокол с `txnDone`.

---

## 4. Адресация (base DDR3, смещения, 64-бит, выравнивание, BAR0/BAR2)

### 4.1 Base DDR3 и смещения — не регрессировано за окно
- `XDMA_DDR3_AXI_BASE = 0x80000000ULL` (`reg.h:59`); добавляется централизованно в
  `XDMA_EngineProgramDma` (`dma_engine.c:948-950`) только при `engine->translateAxiBase`.
- Hex-адрес для H2C/C2H одинаково (`deviceOffset += bytesTransferred` + base) —
  `dma_engine.c:938-950`. ✓
- 64-бит: `srcAddrLo/Hi`, `dstAddrLo/Hi`, `nextLo/Hi` заполняются через `LIMIT_TO_32` и
  `(LONG)(x>>32)` (`dma_engine.c:1035-1043`). ✓
- Верхняя граница DDR3: ROF-guard `endOff > base + 0x10000000 → reject` (`dma_engine.c:955-965`). ✓
- Изменений в этих строках в 1.2.7.x **нет** — узлы/смещения/LO-HI не трогались. ✓

### 4.2 BAR0/BAR2 разведение (AXI-Lite 0x40000000 vs DDR 0x80000000)
- `IdentifyBars` (`device.c:182-219`): config BAR = FindConfigBAR; `axiliteBarIdx` — не-config BAR
  с наибольшей апертурой (устройство: PF0 BAR0 = config, BAR1 = user 128MB AXI-Lite;
  либо наоборот). `userBarIdx`/`axiliteBarIdx` согласованы. Изменений нет за окно. ✓
- Engine regs: `engine->regs = configBarAddr + dir*0x1000 + ch*0x100`; `engine->sgdma = regs +
  SGDMA_BLOCK_OFFSET(0x4000)` (`dma_engine.c:725-738`); SGDMA_COMMON — конфиг + 0x6000
  (`device.c:228`). Офсеты за window не менялись. ✓

### 4.3 Выравнивание
- `alignAddr = alignLength = XDMA_MPS_BYTES = 256` по умолчанию (`dma_engine.c:875-877`),
  `DescriptorIsAligned` в Contiguous-режиме (`dma_engine.c:1065`, `:612`+). Не менялось. ✓

---

## 5. Дескрипторы/SG/MDL, лимиты, nextAdj, 125+ дескрипторов

### 5.1 Одна цепочка на перенос — ок
- `WdfDmaTransactionSetMaximumLength(..., XDMA_MAX_TRANSFER_SIZE=8MB)` → по 1 пакету
  (`file_io.c:776/928`, `dma_engine.h:32`). SG-элементы режутся на срезы `XDMA_DESC_MAX_BYTES=8192`
  (`dma_engine.c:997-1070`), строится одна связанная цепочка через `nextLo/Hi` =
  физический слот `di+1` (`:1047-1051`), последний — `STOP|COMPLETED` + (для ST) `EOP`
  (`:1052-1058`).
- `numDescriptors = di` свежий на каждый перенос (`:1096`).

### 5.2 Лимиты/банк
- Банк: `2049` дескрипторов (`dma_engine.h:47`, `dma_engine.c:85`: `2048+1`).
  Для ≤8MB худший случай = 2048 (по 4KB-page на дескриптор). Хард-клэмп `total > bank →
  clamp` + лог (`dma_engine.c:999-1014`) + `progBytes < reqBytes → лог` (`:1078-1083`). ✓
  Для 500КБ (~125-128 дескрипторов) клэмп недостижим.

### 5.3 `nextAdj`/prefetch = 0 — почему, и 125+ дескрипторов
- `firstDescAdj = 0` и `descriptor[].control &= ~(0xFF<<8)` (обнуление nextAdj[15:8])
  навязывается в `XDMA_EngineProgramDma` (`dma_engine.c:1097-1100`) — СДЕЛАННО **чтобы
  выключить multi-descriptor prefetch** (анти-ROF: сглаживает posted-write-поток к Root Port).
  Это осознанный trade-off: prefetch выключен → цепочка длиной ~125 (500КБ) выполняется
  последовательно, «фетч-дескриптор→данные→AXI-write» ×125. Это и есть условие, в котором
  наблюдается клин (см. §8, AUDIT_H2C_WEDGE §2.5/UPD).
- **Риск 125+ дескрипторов:** не переполнение банка, а вероятностная точка срабатывания
  клина: чем длиннее последовательная цепочка без prefetch, тем выше шанс потерять один
  completion/фетч/B-ответ → `BUSY=1` навсегда. Limit-проверки корректны; клин — аппаратный,
  не структурный.

---

## 6. Совместимость (IP, WDF/KMDF, регистры, Reserved-поля)

| Аспект | Факт | Вердикт |
|---|---|---|
| IP-версия | **XDMA 4.2** (`xilinx.com:ip:xdma:4.2`, `scripts/xdma_ddr3_bd.tcl:116,431`; Vivado 2025.2) | PG195 — номер PG-документа, НЕ версия. В отчётах фигурирует «PG195 v4.1» (CHANNEL_RESET_DESIGN UPD) — **примерно** тот же регмап, но точнее называть IP «XDMA 4.2 / PG195 » |
| WDF/KMDF | KMDF 1.11 (`libxdma.vcxproj:64-65`), `WindowsTargetPlatformVersion 10.0.14393.0` (Win10 1607 SDK), WDK 14393 | Не менялось за окно. ✓ |
| Регистровые смещения (`reg.h`) | engine control@0x04, status@0x40, statusRC@0x44, completedDescCount@0x48, pollModeWb@0x88; SGDMA firstDesc@0x4000+0x80; SGDMA_COMMON@0x6000 | Соответствуют XDMA 4.x hyper/simplified-регмапу; driver 1.2.7.0 работал на них. За окно не изменялись. ✓ |
| **Обращения к Reserved-полям** | `XDMA_CTRL_RST = BIT31` канального Control (`reg.h:74`) — **Reserved** по PG195 (31:28 reserved); `XDMA_EngineResetChannel` пишет его при `HW_BIT=1` | **HIGH-риск → уже смягчён default OFF в 1.2.7.6.** При `HW_BIT=1` драйвер писал в reserved бит. Leaked знания: на этом битстриме no-op, но упражнение не должно оставаться включённым без валидации |
| Другие обращения to Reserved | `perfCtrl=0`, `firstDescAdj=0`, `pollModeWb*` — документированные поля | OK |

---

## 7. Реестр подозреваемых регрессий (приоритизированный)

### HIGH
**R1 — Double Finalize (cancel ∩ timeout) → BSOD 0x10D / UAF / двойной Release.**
- Локация: `sys/file_io.c:1102` (гвард) и `:1106-1119` (выполнение) vs `:884-890` (timeout-ветка).
- Сценарий срабатывания: большой h2c → движок клинится → poll ждёт ~10s → юзер вызывает
  CancelIo параллельно с окончанием timeout-финализации. Оба проходят гварды → двойной
  `WdfDmaTransactionRelease` + двойной `WdfRequestComplete`.
- Тип: correctness / concurrency, **CONFIRMED** (код-уровень).
- Фикс: гвард `st==STATUS_CANCELLED → return` (убрать `!ownTxn && !pollTimeout`), оставить
  финализацию только по `ownTxn` (владелец CAS). Пересмотреть назначение `txnTimeout`.

### MED-HIGH
**R2 — BIT31 channel reset = reserved/no-op; «аппаратный reset» функционально не существует.**
- Локация: `libxdma/dma_engine.c:1241` (`controlW1S = XDMA_CTRL_RST`), `reg.h:74`.
- Сценарий: `channelResetOnTimeout=TRUE` или IOCTL `NOW` c `HW_BIT=1` → запись в reserved-бит;
  по факту SOFT-only → залипший BUSY не снимается → поведение как в 1.2.7.4 (клин до
  power-cycle). Не ломает штатный путь (default OFF), но даёт «ложное чувство восстановления».
- Тип: correctness / hardware-semantics, **CONFIRMED** (по регмапу + стенду + самому проекту).
- Фикс: держать OFF по умолчанию (сделано); на стенде валидировать BIT31; если no-op —
  убрать HW-путь и выбрать реальный механизм (SGDMA_COMMON reset 0x6010 / size-limit / иное).

### MED
**R3 — `actual >= expected` на накопительном `completedDescCount` (латентный ложный успех).**
- Локация: `libxdma/dma_engine.c:1685` (WaitCompletion), `:558` (watchdog).
- Сценарий: multi-packet IRP (или не-сброс счётчика IP) → следующий пакет мгновенно «успешен».
  В штатном 1-пакетном пути эмпирически не проявляется (счётчик сбрасывается IP),
  но сравнение хрупко.
- Тип: correctness (латентный), **PLAUSIBLE** (зависит от HW-сброса счётчика).
- Фикс: сравнение по дельте `(actual - startCount) & mask >= expected`; стартовый снапшот
  брать под `engineLock` до `EngineStart`.

**R4 — IOCTL `NOW` вызывает `XDMA_EngineResetChannel` вне владения txnDone.**
- Локация: `sys/file_io.c:712-720`.
- Сценарий: если сериализация sequential-очереди нарушится (будущий async-путь / событие на
  той же очереди) → `RtlZeroMemory` банка + `perfCtrl=0` под работающим программированием.
- Тип: robustness, **PLAUSIBLE**.
- Фикс: `WdfSpinLockAcquire(engineLock)` вокруг `XDMA_EngineResetChannel` в IOCTL-ветке.

### LOW
**R5 — Stale/противоречивые комментарии** (`dma_engine.c:819-821` «вкл по умолчанию» при
коде FALSE; `dma_engine.h` «poll-owner will NOT complete»; `dma_engine.c:1728`). Не влияет
на исполнение, но маскирует R1/R2.
**R6 — Проверка `inLen < sizeof(in)` вместо точного `==`** — приемлемо для METHOD_BUFFERED,
но строже было бы `!=` (+ допустимость больших буферов). LOW, не правка обязательна.

---

## 8. Что проверять на железе ПОСЛЕ разрешения записи

Порядок — от безопасного к рискованному, каждый шаг логируем в WPP (`DBG_DMA`/`DBG_IO`):

1. **Базовый round-trip**: 64 Б write+read @0x200000 (движок переиспользуется) — эталон
   рабочего пути; убедиться, что 1.2.7.6 не сломал штатный успех.
2. **Повторные переносы разного размера (1/4/64/1024/8192 дескр.)**: читать
   `completedDescCount` МЕЖДУ переносами — подтвердить/опровергнуть «сбрасывается ли счётчик».
   Это даст точный вердикт по R3 (delta-сравнение нужно или нет).
3. **A/B по BIT31 (R2, ключевое)**: на клине вызвать IOCTL `NOW` с `HW_BIT=1` и с
   `HW_BIT=0` (пересборка). Если оба не разблокируют — BIT31 no-op, убрать HW-путь в коде
   и принять решение по механизму (SGDMA_COMMON.reset 0x6010 влияет на все каналы — взвесить;
   либо size-limit h2c 4–16КБ как обход; либо валидировать «новый» документированный reset).
4. **Авто-сброс** (`AUTO_ON` + крупная запись до таймаута): проверить, что следующий 4КБ
   перенос проходит БЕЗ power-cycle (цель функции). При default OFF — сначала включить
   политику намеренно.
5. **Гонка cancel ∩ timeout (R1, критично под Driver Verifier)**: зависшая передача +
   CancelIo с повторением; убедиться в ОДИНОЧНОМ `Complete`/`Release` (без 0x10D/0xE6).
   Это прямой тест находки №1 — на текущем коде ожидается возможный двойной complete.
6. **Регрессия производительности**: подтвердить, что `RtlZeroMemory` банка (только в
   timeout-пути) не влияет на успешный путь и на MB/s h2c/c2h.
7. **64-бит адрес/выравнивание**: запись в верхние области DDR3 (base+256MB edge, ROF-guard)
   — что reject срабатывает, а за пределы апертуры передача не уходит.

---

## 9. Итоговые вердикты по пунктам ТЗ

| ТЗ | Вердикт |
|---|---|
| 1. Владение txnDone/isReqPending/txnTimeout, порядок EngineStop/Unmark/Release/Complete, double-complete, STATUS_CANCELLED, packets | **Найден HIGH double-finalize race (R1)** при cancel∩timeout; штатный успех и одиночный timeout — OK |
| 2. `XDMA_EngineWaitCompletion/EngineProcessTransfer/EngineStop/ResetIdle/ResetChannel`; `actual>=expected` на накоп. счётчике | `ResetChannel` HW-часть(BIT31)=no-op (R2); сравнение `>=` — латентный ложный успех, сравнивать по дельте (R3) |
| 3. IOCTL 0x7, корректность кодов/размеров/Probe, user-mode, обратная совместимость | коды/размеры/буферизация корректны; старый хост не ломается; IOCTL NOW вне владения txnDone (R4) |
| 4. Адресация DDR3 base/смещения/LO-HI/выравнивание/BAR0-BAR2 | не регрессировано; централизованный base 0x80000000, LO/HI корректны, ROF-guard на месте |
| 5. Дескрипторы/SG/MDL/лимиты/nextAdj/125+ | одна цепочка/перенос, банк 2049 (клэмп недостижим), nextAdj=0 (анти-ROF) — осознанно; клин 125+ — аппаратный, не структурный |
| 6. Совместимость IP/WDF/регмап/Reserved | IP=XDMA **4.2** (а не 4.1); KMDF 1.11; регмап XDMA4.x; BIT31 reserved → писака в reserved при HW_BIT=1 (R2), смягчено default OFF |
| 7. Список регрессий + что проверять на железе | §7 (R1..R6) + §8 |

---

*Отчёт подготовлен read-only. В production-файлы изменения не внесены.
Ссылки `файл:строка` даны по текущему рабочему дереву HEAD.*