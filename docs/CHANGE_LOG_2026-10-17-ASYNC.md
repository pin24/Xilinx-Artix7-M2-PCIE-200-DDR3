# CHANGE LOG — 2026-10-17 (PLAN-3 P3: редуцированный async-завершение DMA)

Каталог: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3` (main).

## 1. Решение по объёму

Проектирование (3 агента + старший ревьюер) подтвердило:
- Железо XDMA на движке имеет ОДИН набор `sgdma->firstDescLo/Hi/Adj` и ведёт ОДНУ desc-цепочку. Запуск второй транзакции на одном движке **физически невозможен** (второй `Execute` перезапишет firstDesc поверх активной цепочки).
- Поэтому полный исходный P3 (пул `dmaTxPool` + `descBufferPool` + перевод очередей в `WdfIoQueueDispatchParallel` + спинлок на firstDesc) **не даёт реального параллелизма** на одном движке, а лишь микро-перекрытие подготовки дескрипторов при высоком риске повторного BSOD 0x10D (общий `txnDone/isReqPending/numDescriptors/progDmaCalls` снова становится общим для перекрывающихся запросов).
- Принят **редуцированный вариант**: перевод завершения на асинхронный `WdfDmaTransactionSetTransferCompleteCallback` при НЕизменённой очереди `WdfIoQueueDispatchSequential`. Очередь сама не запустит следующий запрос, пока текущий request не completed (в DPC/callback), поэтому гонки за общее состояние нет, спинлок и пул не нужны. Выигрыш: поток очереди перестаёт блокироваться в `KeStallExecutionProcessor`-poll (`XDMA_EngineWaitCompletion`).

Пул `descBufferPool`/`dmaTxPool` (P1+P2) остаётся в коде как PREP-ONLY, в этом шаге НЕ задействуется.

## 2. Реализация

Файлы изменены: `libxdma\dma_engine.h`, `libxdma\dma_engine.c`, `sys\file_io.c`.

### libxdma\dma_engine.h
- В `XDMA_ENGINE` добавлены поля watchdog: `WDFTIMER watchdogTimer; ULONG watchdogCount; ULONG watchdogBudget;` (комментарий REDUCED-ASYNC).
- Добавлен контекст таймера `DMA_WATCHDOG_CTX { XDMA_ENGINE* engine; }` + `WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DMA_WATCHDOG_CTX, GetDmaWatchdogContext)` (родитель таймера — WDFDEVICE, движок передаётся через контекст).
- Добавлен прототип `VOID EvtTransferCompleteCb(IN WDFDMATRANSACTION, IN WDFDEVICE, IN WDFCONTEXT, IN WDF_DMA_DIRECTION, IN DMA_COMPLETION_STATUS)`.

### libxdma\dma_engine.c
- `EngineProcessTransfer`, успешная ветка (`XDMA_ENGINE_STOPPED_OK`): оставлен вызов `WdfDmaTransactionDmaCompleted` (он инициирует CB при возврате TRUE); **убраны** `WdfRequestUnmarkCancelable` / `WdfDmaTransactionRelease` / `WdfRequestCompleteWithInformation` — завершение переехало в `EvtTransferCompleteCb`. Error-ветка (`default`) и `isReqPending`/очистка буферов не изменены.
- Новый `EvtTransferCompleteCb` (не static): `UnmarkCancelable` (если `STATUS_CANCELLED` — return, отдают cancel-пути) → C2H `XDMA_EngineResetIdle` перед Complete → `WdfDmaTransactionRelease` → `WdfRequestCompleteWithInformation`. `bytes` читаются до Release.
- Новый `static EvtDmaWatchdogTimer`: если `txnDone`/`!isReqPending` — выход без переармирования; иначе проверка `hwDone` (стиль `XDMA_EngineWaitCompletion`: `statusRC` read-clear + `completedDescCount>=numDescriptors`) → при готовности вызывает `EngineProcessTransfer`; при исчерпании бюджета — timeout-ветка (см. REVIEW-FIX); иначе пере-арм на 10 мс.
- `EngineCreate`: создание `WdfTimerCreate` (parent = WDFDEVICE, контекст `DMA_WATCHDOG_CTX`), `watchdogBudget=1000`, `watchdogCount=0`.

### sys\file_io.c
- `EvtIoWriteDma` / `EvtIoReadDma`: после `WdfDmaTransactionInitializeUsingRequest` + `SetMaximumLength` регистрируется `WdfDmaTransactionSetTransferCompleteCallback(..., EvtTransferCompleteCb, queue->engine)` (ДО Execute); удалён блокирующий `XDMA_EngineWaitCompletion`; после успешного `Execute` стартует watchdog (колеблется `watchdogCount=budget`, `WdfTimerStart`), затем `return` — поток очереди не блокируется.
- C2H `ResetIdle` перед Execute сохранён; второй `ResetIdle` (бывший после WaitCompletion) перенесён в `EvtTransferCompleteCb`.
- `ErrExit`-пути не изменены.

## 3. Исправления по итогам ревью

- **Блокер (закрыт)**: timeout-ветка watchdog теперь перед освобождением атомарно «захватывает» `txnDone`/сбрасывает `isReqPending` под `engineLock`, и проверяет возврат `WdfRequestUnmarkCancelable` (`STATUS_CANCELLED` → вернуть, не делать Release/Complete). Это закрывает гонку watchdog-timeout ↔ DPC/`EvtCancelDma`, исключая двойное освобождение транзакции/request (0x10D/0xE6).
- Ошибки компиляции (исправлены): сигнатура callback приведена к `PFN_WDF_DMA_TRANSACTION_DMA_TRANSFER_COMPLETE` (5 арг.); `WdfTimerStart` принимает `LONGLONG` (передаётся `period.QuadPart`); контекст таймера задаётся через `WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE`.

## 4. Сборка

Все 6 TU (`dma_driver.c`, `file_io.c`, `device.c`, `dma_engine.c`, `interrupt.c`, `security_cookie.c`) скомпилированы `cl.exe` с флагами из `build.cmd` — **ALL TU COMPILED OK**. Полная сборка пакета `.sys` — отдельный этап (требует администратора).

## 5. Известные ограничения / риски

- **Многопакетность (>8 MB на запрос)**: если `WdfDmaTransactionDmaCompleted` возвращает `FALSE` (первый из нескольких WDF-пакетов), то request не завершится — `txnDone` уже установлен и следующий DPC будет отброшен guard'ом, а watchdog видит `txnDone=TRUE` и тоже не сработает. Это было ограниченной зоной и до редукции (движок не рестартует между пакетами, см. FIX-ROF/E-19); текущая конфигурация — один WDF-пакет на запрос (`SetMaximumLength=8MB`). При возврате больших пакетов (>8MB) требуется доработка (не трогать `txnDone` при `completed==FALSE`).
- **Надёжность DPC-завершения**: async полагается на то, что прерывание (interrupt.c DPC → EngineProcessTransfer) стабильно приходит. Watchdog — fallback для потерянного MSI-X (~10 с), но не основной путь. Требует стендовой верификации: доля успешных DPC-завершений должна быть 100% на длинном прогоне.
- Тесты, способные вызвать BSOD, и перезагрузка — только с согласия пользователя (правило проекта).

## 6. Двухканальный конвейер (идея пользователя, отдельная фаза)

Прошивка XDMA IP сконфигурирована как `xdma_wnum_chnl {2}` / `xdma_rnum_chnl {2}` (scripts/xdma_ddr3_dfx_bd.tcl:698-699): каналы H2C_1 / C2H_1 **существуют в железе**, но текущий софт/бенчмарк используют только H2C_0/C2H_0. Это отдельные движки со своими SGDMA/firstDesc → их можно запускать реально параллельно. Удвоение через чередование чанков по двум каналам с адресной раскладкой (порядок содержится в адресах DDR3/host-буфера) — выигрыш до 2× за счёт независимых движков, НЕ пула. Требует отдельной фазы: драйвер (распределение запросов по 2 движкам + seq-нумерация) + бенчмарк; узким местом может стать единственный MIG (проверяется железом).

## 7. План следующего шага

1. (опц.) полная сборка пакета `.sys` (build.cmd от администратора) + установка/reboot с согласия.
2. Стендовая верификация async (DPC-надёжность, методы из CHANGE_LOG_2026-10-17 §D).
3. При подтверждении стабильности — рассмотреть двухканальный конвейер H2C_0/1 + C2H_0/1.