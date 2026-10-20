# Аудит XDMA (KMDF) Windows-драйвера — v1.2.4.0

Дата: 2026-10-20. Только чтение и анализ, ничего не менялось.
Объект: `driver\dma` (гейтвей `dma_driver.c` + upstream-стек `xdma_driver_win_src_2017\libxdma\{device,dma_engine,interrupt}.c` и `sys\file_io.c`).

## Легенда severity
- **P1** — BSOD / зависание / потеря данных / потенциальное повышение привилегий.
- **P2** — латентный дефект в редком сценарии.
- **P3** — гигиена / согласованность версий / устаревший код.
- **CONFIRMED** — механизм и триггер однозначно воспроизводятся по коду.
- **PLAUSIBLE** — механизм реален, но триггер зависит от внешних условий (тайминги, железо, порядок PnP).

---

## 1. Жизненный цикл транзакции (кто владеет dmaTransaction)

### Активный путь (v1.2.2+)
`EvtIoWriteDma`/`EvtIoReadDma` (file_io.c:685/766):
1. `WdfDmaTransactionInitializeUsingRequest` (один transaction на движок),
2. `WdfRequestMarkCancelableEx(Request, EvtCancelDma)`,
3. `WdfDmaTransactionExecute` (вызывает `ProgramDma` → `EngineStart`),
4. `XDMA_EngineWaitCompletion(engine, 200000)` — блокирующий poll (~10 с макс).

Завершение — **синхронно** внутри `EngineProcessTransfer` (dma_engine.c:291), который вызывается либо из `XDMA_EngineWaitCompletion` (poll-ветка), либо из `EvtChannelInterruptDpc`/`EvtInterruptDpc` (ISR-ветка).

### P1 CONFIRMED — `WdfRequestComplete` внутри блокирующего poll на DISPATCH_LEVEL ≠ реальный IRQL: первичный путь здесь **PASSIVE**, но ISR-ветка — второй вход
Ключевая проблема, которую код пытается закрыть флагом `txnDone`, — оба пути (poll-поток очереди на PASSIVE и DPC на DISPATCH) вызывают `EngineProcessTransfer`. Оба используют check-and-set `txnDone` под `engineLock` (dma_engine.c:323, спинлок на DISPATCH_LEVEL). Спинлок держит ВНОС, поэтому оба пути сериализуются корректно: кто первый − тот владелец завершения. `WdfDmaTransactionDmaCompleted/Release/Complete` корректно выполняются только один раз. **Механизм дедукпликации корректен.** Но см. п. 5 (IRQL эвристика в `EngineProcessTransfer` при `DmaCompleted()==FALSE`).

### P1 CONFIRMED (потенциальная УТЕЧКА/висящий запрос) — status-BUSY больше не завершается для V1-пути? — НЕТ. Разбор:
`EngineProcessTransfer` в ветке `XDMA_ENGINE_STOPPED_OK` вызывает `WdfDmaTransactionDmaCompleted`. Пока transaction игнорирует `XDMA_DESC_STOP_BIT`-семантику — это не дефект: WDF считает все пакеты выполненными при вызове `DmaCompleted`; вызов одного `DmaCompleted` для single-packet транзакции возвращает TRUE и transaction освобождается.

### Флаги не сбрасываются на всех путях отмены
`txnDone` сбрасывается только в начале нового `EvtIoWrite/ReadDma` (file_io.c:699,777). Если `EvtCancelDma` забрал транзакцию (`txnDone=TRUE, ownTxn=TRUE`) и завершился (file_io.c:909), а пользователь открыл новый запрос — сброс в начале следующего DMА-обработчика корректен. Но **если отмена пришла ДО `WdfDmaTransactionInitializeUsingRequest`** (запрос ещё не помечен cancelable), `EvtCancelDma` не вызывается вообще — WDF сам завершит запрос с STATUS_CANCELLED. ОК.

### P2 CONFIRMED — гонка отмены между `MarkCancelableEx` и `Complete` (окно готово к отмене)
Порядок (file_io.c:728→735):
```
MarkCancelableEx(EvtCancelDma)
WdfDmaTransactionExecute()
XDMA_EngineWaitCompletion()   // блокирующий, до ~10с
  └ EngineProcessTransfer(): DmaCompleted -> UnmarkCancelable -> Complete
```
Если во время `WaitCompletion` приходит Cancel, `EvtCancelDma` бегает на пассивном уровне (cancel callback — асинхронный, DISPATCH), берёт `txnDone`, стопает движок, `UnmarkCancelable`, `Release`, `Complete(STATUS_CANCELLED)`. Между тем `EngineProcessTransfer` в poll-потоке уже мог пройти `DmaCompleted` и `UnmarkCancelable` (получил бы STATUS_CANCELLED → сам выходит на `break`, НЕ завершает — file_io.c:369-372). Тогда отмена и DPC конкурируют: poll-поток сделал UnmarkCancelable→CANCELLED→break, отдача владения cancel-пути — корректно (cancel-рутина завершит). **Порядок корректен благодаря UnmarkCancelable-first.** Окно «MarkCancelableEx выполнен, Wait ещё не вошёл» — cancel-рутина получает владение до EngineProcessTransfer, единственный владелец — она. Не дефект.

### Внимание (PLAUSIBLE, P1): `WdfRequestComplete` после `return` при `WaitCompletion` таймауте — повторного `Complete` НЕТ при успешном Dpc? — разбор в секции 5.

---

## 2. Отмена (EvtCancelDma, file_io.c:862)

`EvtCancelDma`:
- Сначала отсекает чужие транзакции: если `active=dmaTransaction.getRequest()` != request → `return` (file_io.c:869-872). Это защита от отмены старого запроса после перезаписи транзакции новым.
- Затем check-and-set `txnDone` (забирает владение). Если владение забрано — `EngineStop`, `UnmarkCancelable`, `Release`, `Complete(CANCELLED)`.

### P1 CONFIRMED — двойной `WdfRequestComplete` при «чужая транзакция» + активный запрос с чужой транзакцией
Сценарий: одна sequential-очередь на движок гарантирует, что параллельных W+R на одном движке нет. НО `EvtCreateEngineQueues` создаёт ПО ОДНОЙ независимой sequential-очереди НА движок (dma_driver.c:357). Пользователь может открыть `h2c_0` И `c2h_0` двумя хендлами — это РАЗНЫЕ движки → разные транзакции. Проблема не возникает.

Другая грань: **один движок, одна очередь, но `WdfRequestForwardToIoQueue` с default-очереди на engine-очередь**. Default-очередь Sequential (dma_driver.c:169). Forward на engine-очередь (тоже Sequential). Пока в очереди один запрос — ок. Если приложение шлёт два Write подряд на `h2c_0`, default-очередь последовательно форвардит, engine-очередь обработает первый, `Execute`+`Wait`, только затем доставит второй. Перекрытия нет. **Ограничение «один канал» подтверждено, но двойного Complete оно не даёт.**

### P1 CONFIRMED — двойное завершение при отмене запроса, чья транзакция УЖЕ перезаписана новым (несовпадение активного request)
`EvtCancelDma` (file_io.c:869): `active != request → return` — cancel-рутина НЕ трогает транзакцию. Но запрос `request` тогда так и НЕ будет завершён здесь, а в `EvtIoWriteDma` poll-поток продолжает `WaitCompletion` по НОВОЙ транзакции. WDF после `EvtCancelDma` возвращает управление; если cancelable-обработчик ничего не сделал с request (return), **запрос остаётся отменённым и «зависшим»**: WDF считает request отменённым, но не завершённым → висящий IRP / утечка. При этом poll-поток в итоге завершит ТЕКУЩУЮ транзакцию, а старый request даже не был `Complete`н.

Это реальная утечка: **запрос, cancelled, когда его транзакция уже перезаписана новым запросом, никогда не завершается.** Сценарий: `Write A` начнён (Execute, WaitCompletion), затем прежде чем A завершился — невозможен по sequential-очереди, НО возможен если приложение закрывает хендл (EvtFileCleanup) или отменяет A через overlapped. Пока `WaitCompletion(A)` блокирует threaded-контекст очереди, второй запрос B **не будет доставлен** той же очередью (sequential). **Значит «чужой active» внутри одной очереди достижим только при... двух очередях на один движок? Нет. Реально: dead-code-ветка.** ВЫВОД: ветка «чужая транзакция» недостижима при текущей топологии очередей (1 sequential очередь/движок). Следствие — см. **недостижимость → оцениваем как P3 (мёртвая защита), но опасную** (см. ниже UAF при close).

---

## 3. Отмена между Execute и Wait, таймаут Wait → уже разобрано в п.2/1. Итог: корректно через UnmarkCancelable-first; единственный риск — «отменённый, но не завершённый» request при перекрытии, которое сейчас недостижимо.

---

## 4. IRQL (XDMA_EngineWaitCompletion)

`XDMA_EngineWaitCompletion` (dma_engine.c:1488) вызывается ИЗ `EvtIoWriteDma`/`EvtIoReadDma`. Эти выполняются в диспетчер-контексте queue-потока WDF — **PASSIVE_LEVEL** (dispatch processing on PASSIVE). Внутри — `KeStallExecutionProcessor(50)` (busy-wait, позволяет любой IRQL ≥ PASSIVE). Само по себе «ожидание» — это спин, а не `KeWaitForSingleObject`, поэтому на PASSIVE/DISPATCH безопасно.

### P1 CONFIRMED — блокировка PASSIVE-потока очереди на ~10 с грузит один CPU на 100%
`KeStallExecutionProcessor(50)` в цикле — **spinning**, ~5 мкс на итерацию (по комментарию), 200000 итераций max. При потерянном MSI-X или зависшей FPGA это ~100% одного ядра на 10 секунд, удерживая последовательность очереди. Это не deadlock системы, но при H2C+R внутреннего кольца задержки крайние. Гигиенически должен быть `KeWaitForSingleObject` с таймером или `LARGE_INTEGER`-таймаут — но то на DISPATCH нельзя. В рамках данной архитектуры спин — осознаваемая плата за reliability. **P2** (не P1: не вешает систему, но роняет ядро в спин).

### P1 CONFIRMED (главный IRQL-риск) — `EngineProcessTransfer` → `WdfRequestComplete` из DPC-пути
Если завершение делает `EvtChannelInterruptDpc`/`EvtInterruptDpc` (DISPATCH_LEVEL), `EngineProcessTransfer` внутри вызывает `WdfRequestCompleteWithInformation`/`WdfDmaTransactionRelease`. **WDF разрешает вызов этих функций на DISPATCH_LEVEL** — WdfRequestComplete можно вызывать на ≤ DISPATCH_LEVEL, WdfDmaTransactionRelease тоже ≤ DISPATCH_LEVEL. Значит IRQL-контракт соблюдён. **P3/подтверждено-безопасно.**

Однако: **спинлок `engineLock` (WdfSpinLock) держится на DISPATCH; из-под него нельзя звать `WdfRequest*`**. В `EngineProcessTransfer` спинлок берётся ТОЛЬКО для check-and-set `txnDone` (dma_engine.c:324-327) и освобождается до `DmaCompleted/Release/Complete`. ОК.

---

## 5. Прерывания / MSI-X (interrupt.c)

`EvtChannelInterruptIsr` (interrupt.c:455) — DISPATCH: `EngineDisableInterrupt` → `WdfInterruptQueueDpcForIsr`. `EvtChannelInterruptDpc` (interrupt.c:470) вызывает `irq->engine->work()` = `EngineProcessTransfer`. Затем re-enable.

### P1 CONFIRMED — bus-read `EvtExecute`-адресов на ISR/DPC если прерывание случилось БЕЗ активного запроса
`EngineProcessTransfer` (dma_engine.c:307) сначала проверяет `isReqPending`: если FALSE → return (спурийный guard). Хорошо.

### P1 CONFIRMED — MSI-X «прерывание не пришло»: пытается ли только poll? Да. Но ISR/DPC параллельно со spin завершает ту же транзакцию?
Сценарий: `EvtIoWriteDma` пошёл в `WaitCompletion` (спин). FPGA завершил и шлёт MSI-X. `EvtChannelInterruptDpc` заходит в `EngineProcessTransfer`, берёт `txnDone`, выполняет `DmaCompleted→Release→Complete`. Параллельно poll-поток в `WaitCompletion` видит `hwDone && actual>=expected` (dma_engine.c:1521) и тоже входит в `EngineProcessTransfer`. Его `check-and-set txnDone` возвращает already=TRUE → **return** (dma_engine.c:328). Он НЕ трогает Release/Complete. **Корректно.** Дуаль к тому, что poll дойдёт первым: тогда DPC войдёт и откинется. Механизм оба раза сохраняет один владелец. **CONFIRMED-безопасно.**

### P1 CONFIRMED — гонка «поллинг победил, DPC ещё висит» и флаг pending
После успешного `EngineProcessTransfer` сбрасывается `isReqPending=FALSE` (dma_engine.c:401-408). DPC, прилетевший позже, увидит `pending=FALSE` → return. ОК.

### Повторное срабатывание DPC от ТОЙ ЖЕ транзакции — `txnDone` не сброшен: сбрасывается только в новом EvtIoWrite/Read. Если DPC пришёл дважды ДО нового запроса — второй войдёт, увидит `txnDone=TRUE` → return. ОК.

---

## 6. DMA-движок / дескрипторы (ProgramDma, dma_engine.c:859)

### P1 CONFIRMED — переполнение массива дескрипторов
`EngineCreateDescriptorBuffer` (dma_engine.c:67) аллоцирует `XDMA_MAX_DESC_COUNT * sizeof(DMA_DESCRIPTOR) + 1*sizeof`. С `XDMA_DESC_MAX_BYTES=8192` и `XDMA_MAX_TRANSFER_SIZE=8MB`: `XDMA_MAX_DESC_COUNT = 8MB/8KB = 1024`. Пул буфера = 1025 дескрипторов.

В `ProgramDma` вычисляется `total = Σ ceil(len/8192)`. При `length=8MB` ровно один SG-элемент → 1024 дескриптора, `total ≤ descBankLens (1025)`: clamp (dma_engine.c:943) сработал бы только при >1025. Но если SG содержит МНОГО элементов по 1 байту — `total` очень большой. Например SgList из 2000 элементов по 1 байту → `total=2000 > 1025` → **clamp до 1025** (dma_engine.c:947). Затем цикл `for (i = 0; i < ne && di < total; i++)` (dma_engine.c:954) с внутренним `while (off<len && di<total)` пишет в `descriptor[di]` только до `di=1024` включительно? Нет: условие `di < total` (total=1025) → допустимые индексы 0..1024 (это в границах буфера 1025). **Безопасно.** Однако часть SG-элементов НЕ переносится в дескрипторы (обрыв), `total` зажат. Тогда `numDescriptors = di` (dma_engine.c:1017) = 1025, а фактически transfer только начальной части. Двигатель выполнит 1025 дескрипторов и встанет в DESC_STOP (на последнем). `completedDescCount`=1025, `WaitCompletion` ждёт `actual>=expected(1025)` — выполнится. Но данные обрезаны (часть пользовательского буфера не отображена). WDF, однако, знает о полной длине запроса и по возврату `ProgramDma=TRUE` продолжит пилить пакеты по `XDMA_MAX_TRANSFER_SIZE`... вернее, single recommended packet. **Обрыв данных при SG с >1025 кусками — это потеря данных (P1), но клиенту вернётся Information<длины -> единственный честный сигнал.** Реальность: XDMA_MAX_TRANSFER_SIZE=8MB достигается только при одном >8MB буфере; WDF режет большой запрос на пакеты по 8MB, каждый пакет = отдельный ProgramDma, обычно MIN_PACKET. Многоэлементный SG >1025 достижим для >4MB буфера с 4KB-страницами: 8MB/4KB=2048 элементов → 2048 > 1025. **CONFIRMED: длинный (≥8MB) буфер с 4KB-skatter даёт >1025 SG-элементов, часть данных теряется/обрезается.** P1 (потеря данных).

### P1 CONFIRMED — double-free/перезапись при нехватке дескрипторов ТОЛЬКО за счёт clamp — частичный перенос без сигнала. Аналогично выше.

### P2 CONFIRMED — `DescriptorIsAligned` использует `desc->srcAddrLo`/`dstAddrLo` НА 32-битных полях как физический адрес, но на самом движке требуется выравнивание по `alignAddr` (256). Для `AddressMode_Contiguous` проверяет остатки адресов/длин. Для 8-byte alignment DMA профиля (device.c:301 `WdfDeviceSetAlignmentRequirement(..., 8-1)`) — элементы SG выровнены по 8, НО действует требование 256 из `alignAddr` defaults (dma_engine.c:821). Невозможность получить <256-aligned — фактически отказ. Это могло бы давать ROF, но уже введён слайсинг по 8192. **Эвристика alignment в ProgramDma пишет только `TraceWarning` и продолжает (dma_engine.c:998)** — не отсекает. P2.

### P3 CONFIRMED — `XDMA_DESC_MAX_BYTES=8192` vs `XDMA_MAX_TRANSFER_SIZE` (8MB) / `XDMA_MAX_DESC_COUNT=1024`. Совместимо с 1025-слотом, но клиентская side — см. P1.

### P3 — «FIX-ROF2» проверка диапазона DDR3 в `ProgramDma` (dma_engine.c:901-911): `SgList->Elements[bi].Length` суммируется в `endOff` как `ULONGLONG`, `deviceOffset` может быть огромным → `endOff` переполнение маловероятно, но если `deviceOffset` уже близко к `UINT64_MAX` (пользователь передал offset 0xFFFF...)? DeviceOffset — LONGLONG из params (может быть отрицательным!). В dma_engine.c:870 `deviceOffset = (SIZE_T)params...DeviceOffset` — **при отрицательном DeviceOffset (VALID при negative offset?)** — на x64 `SIZE_T` знаковое расширение → огромный адрес, пройдёт в дескрипторы и в `ROF-guard` (endOff > 0x90000000 → reject). Отсекается. Но `translateAxiBase==FALSE` (bram-узлы) → guard пропущен, отрицательный offset → адрес ~0xFFFFFFFFxxxx, уйдёт в дескриптор к устройству — FPGA может выдать read/write куда угодно. **PLAUSIBLE P2** (возможность некорректного кардового адреса при bram-узле и отрицательном offset).

---

## 7. Буферы пользователя

`WdfDeviceSetIoType(...BufferedOrDirect)` (dma_driver.c:132). DMA-транзакции используют direct (buffer → MDL). `WdfRequestRetrieveOutputBuffer` в IOCTL.

### P1 CONFIRMED — `IoctlSetAddrMode` читает ULONG из буфера БЕЗ проверки размера входного буфера
file_io.c:568: `WdfMemoryCopyToBuffer(requestMemory, 0, &addrMode, sizeof(addrMode))`. `WdfMemoryCopyToBuffer` сам бросает `STATUS_INVALID_BUFFER_SIZE` при `BufferLength > BufferSize`? Нет — `WdfMemoryCopyToBuffer` копирует min; если requestMemory короче 4 байт → возвращает `STATUS_INVALID_BUFFER_SIZE`. Обработка есть (goto... нет, просто `return status` из IoctlSetAddrMode, и в EvtIoDeviceControl exit завершит запрос, если fail). ОК.

### P1 CONFIRMED — `IoctlGetPerf`/`IoctlGetAddrMode` не проверяют фактический размер выходного буфера, но `WdfMemoryCopyFromBuffer` сам вернёт ошибку при нехватке; в EvtIoDeviceControl exit-ветка завершит. ОК.

### P3 — IOCTL rights: все `IOCTL_XDMA_*` используют `FILE_ANY_ACCESS` (xdma_public.h:63). PERF_START/PERF_GET / ADDRMODE_SET меняют железо (set address mode), но запрос от любого пользователя с доступом к device. Доступ к device ограничен ACL символической ссылки. **P3** (привилегии не повышаются, но нет дифференциации R/W).

### P2 CONFIRMED — `EvtIoDeviceControl` (file_io.c:601) игнорирует `OutputBufferLength`/`InputBufferLength`; при `queue->engine != NULL` для DMA-узлов. Для PERF_GET ожидает 24 байта (XDMA_PERF_DATA). `WdfRequestRetrieveOutputMemory` вернёт буфер меньше → `WdfMemoryCopyFromBuffer` вернёт ошибку. ОК.

---

## 8. Очистка / close / unload

### P1 CONFIRMED — `EvtDeviceReleaseHardware` (dma_driver.c:315) вызывает `XDMA_DeviceClose` БЕЗ остановки активных DMA и БЕЗ ожидания завершения транзакций
`XDMA_DeviceClose` (device.c:320) НЕ зовёт `EngineStop`, не ждёт незавершённые `WdfDmaTransaction`, не ждёт обладателя в `WaitCompletion`. При RemoveDevice / disable-enable пока `EvtIoWriteDma` спит в `WaitCompletion` (до 10с) на пассивном quote-потоке, `XDMA_DeviceClose` уже /может/ `MmUnmapIoSpace` BAR'ов (device.c:356-363) и удалить WDF-объекты (WDF сам удалит по завершению). `EngineProcessTransfer` после unmapping обратится к `engine->regs` (уже мёртвый BAR) → **page fault / access violation на DISPATCH или PASSIVE → BSOD**. WDF гарантирует: `EvtDeviceReleaseHardware` не вызывается, пока есть активные requests (framework паузирует очереди). Но busy `WaitCompletion` (спин) НЕ считается «активным request» для паузы очереди. По завершении ReleaseHardware WDF отменяет запросы в очереди. Poll-поток может быть в середине спина → зайдёт в EngineProcessTransfer по unmapped BAR. **CONFIRMED-механика, PLAUSIBLE-триггер (нужны активные DMA в момент disable-enable). P1.**

### P3 CONFIRMED — `MmMapIoSpace` `barLength` тип ULONG — MapBARs/Unmap передают `resource->u.Memory.Length`. Ок для ≤4GB BAR.

### P3 — удаление watchdogTimer: parent = WDFDEVICE (dma_engine.c:784), уходит автоматически с устройством. Хорошо.

---

## 9. Ресурсы / инициализация

### P1 CONFIRMED — `SetupInterrupts` при `irq->regs==NULL`
`XDMA_DeviceOpen` вызывает `GetRegisterModules`, который может оставить `interruptRegs=NULL` если BAR мал (device.c:243-248). Затем `SetupInterrupts` (interrupt.c:546) без проверки использует `irq->regs->...` в ESE? Нет — `EvtInterruptEnable` (interrupt.c:310) `EXPECT(irq->regs != NULL)` — это ASSERT, отключён в free build → **deref NULL в regs → BSOD**. Но PREVIOUS: XDMA_DeviceOpen проверяет только `configRegs==NULL` (device.c:280), НЕ `interruptRegs`. Если BAR слишком мал для IRQ_BLOCK_OFFSET+sizeof(XDMA_IRQ_REGS), `interruptRegs=NULL`, а `SetupInterrupts` создаст WdfInterrupt с `EvtInterruptEnable`, который разыменует NULL regs. **P1 CONFIRMED-механика (отсутствие валидации), PLAUSIBLE-триггер (нужен малый BAR).**

### P1 CONFIRMED — `GetRegisterModules` сдвиг `configBarAddr + SGDMA_COMMON_BLOCK_OFFSET` без проверки len
device.c:227: `if (len >= SGDMA_COMMON_BLOCK_OFFSET + sizeof(XDMA_SGDMA_COMMON_REGS))` — проверка есть. `sgdmaRegs` защищён. Но `EngineProcessRing`/`EngineCreate` для ST-движка использует `engine->sgdma` напрямую (проверки нет, но EngineCreate проверяет BAR size, dma_engine.c:679: `engineEnd = offset + SGDMA_BLOCK_OFFSET + sizeof(XDMA_SGDMA_REGS)`). Ок.

### P2 CONFIRMED — повторный PrepareHardware (disable/enable): `XDMA_DeviceOpen` вызывается заново. Если WdfDmaEnablerCreate уже существует? WDF пере-создаёт? `WdfDmaEnablerCreate` на повторном PrepareHardware создаст НОВЫЙ enabler, старый останется привязан к WDFDEVICE — старые common-buffer/транзакции наследуют старый enabler. **Двойное создание WDFCOMMONBUFFER/транзакций при повторном включении** — WDF-объекты с parent=device накапливаются (утечки дескрипторов) и старые engine->descBuffer ссылаются на предыдущий enabler. Более того, `DeviceDefaultInitialize` сбрасывает `engines[..].enabled=FALSE`, но НЕ обнуляет `descBuffer`/`dmaTransaction`/`watchdogTimer` наборы — при повторном EngineCreate старые WDF-хендлы перезаписываются без WdfObjectDelete → **утечка дескрипторов и общая память, потерянный объект**. Плюс глобальный `engineIndex` (ProbeEngines, статический мусор нет). PLAUSIBLE P2.

---

## 10. Счётчики PERF / WPP

### P3 CONFIRMED — `EngineGetPerf` (dma_engine.c:1583): `perfData->pendingCount = ((hi<<32)+perfPndLo)` — верно (в отличие от упр. `perfCycHi<<32`? тут корректно). Ошибка строки не критична.

### P3 CONFIRMED — `IOCTL_XDMA_PERF_START` объявлен, `IOCTL_XDMA_PERF_STOP` (0x2) — в xdma_public.h объявлен, но в `EvtIoDeviceControl` (file_io.c:621) **отсутствует case** → `default` → STATUS_NOT_SUPPORTED. Memory подтверждает: тест `test_dma_perf_ioctl` падает именно поэтому. Расхождение API/реализации. P3.

### P3 — `DbgPrint` в hot DMA path (ProgramDma, dma_engine.c:917) — заметно влияет на производительность в цикле, но не блокирует. P3.

---

## 11. Согласованность версий (строение)

- `driver\dma\build.cmd:37` → `DRIVER_VERSION=1.2.4.0` ✓ (цель).
- `XDMA_DMA.inx:9` → `DriverVer=10/17/2026,1.1.32.0` (жёстко зашито, устарело — но stampinf перепокрывает `-v`).
- `build\XDMA_DMA.inf:9` → `DriverVer=10/18/2026,1.1.34.0` (артефакт предыдущей сборки 19.10).
- `build\sys\XDMA_DMA.inf:9` → `DriverVer=10/18/2026,1.1.33.0` (артефакт, расхождение с build\ на 1 тик).
- `.sys` оба 19.10 16:43/16:45 (40832 байт).

**P3 CONFIRMED — расхождение версий артефактов:** в `build\` и `build\sys\` лежат INF от РАЗНЫХ версий (1.1.34 vs 1.1.33), оба ≠ целевой 1.2.4.0. Это остатки прошлых сборок; свежий oem188.inf (1.2.4.0) установлен в системе (по memory), но в дереве нет актуального сгенерированного пакета. При следующем `build.cmd` stampinf перепишет на 1.2.4.0 — если только сравнение `pnputil` не отклонит из-за даты (дата выставляется 'yesterday UTC').

---

## Итог по синхронному завершению DMA (v1.2.2/v1.2.4) — ВЕРДИКТ

**Существенных дефектов в самом синхронном механизме завершения НЕ найдено.** check-and-set `txnDone` под `engineLock` корректно даёт единственного владельца завершения между poll-потоком очереди (PASSIVE), ISR/DPC (DISPATCH) и `EvtCancelDma`; `UnmarkCancelable`-первым исключает двойной `Complete`; флаг `isReqPending`-guard гасит спурийные/двойные прерывания. Синхронность `WdfRequestComplete` прямо в `EngineProcessTransfer` (вместо async callback) устранила зависимость от MSI-X и 10-секундный watchdog-висящий запрос.

**Критические дефекты лежат ВОКРУГ механизма, не в нём:**
1. Переполнение descriptor-пула → обрезка данных при SG > 1025 элементов (длинный ≥8MB scatter-буфер), clamp молчит (никак не сигналит). — P1.
2. Отсутствие остановки/синхронизации DMA в `EvtDeviceReleaseHardware` → обращение к unmapped BAR при disable-enable → BSOD. — P1 (PLAUSIBLE триггер).
3. `interruptRegs==NULL` не валидируется перед `SetupInterrupts` → NULL-deref в `EvtInterruptEnable` (free build, ASSERT отключён). — P1 (PLAUSIBLE).
4. `EvtCancelDma` ветка «чужая транзакция» (file_io.c:871) — мёртвая при текущей топологии, но при её достижении запрос cancel'ится без Complete (утечка/висящий IRP). — P2.
5. `KeStallExecutionProcessor` спин на ~10с на 100% одного ядра при потере MSI-X/зависшей FPGA. — P2.
6. Повторный `PrepareHardware` без очистки старых WDF-объектов (enabler/descBuffer/dmaTransaction/watchdog) — утечка и ссылки на старый enabler. — P2.
7. Расхождение версий INF-артефактов / отсутствие `IOCTL_XDMA_PERF_STOP` в свитче. — P3.

## Счётчики
- P1: 2 CONFIRMED, 2 манифест P1 с PLAUSIBLE-триггером (итого 4 P1: SG-overflow, ReleaseHardware-UAF/BSOD, interruptRegs-NULL, ...).
- P2: 5 (cancel-«чужая транзакция», spin 10с, повторный PrepareHardware, отрицательный offset на bram-узле, невыровненные SG).
- P3: 6 (версии INF, PERF_STOP нет, DbgPrint hot path, FILE_ANY_ACCESS, мёртвый комментарий/старый код waitdog 10с в dma_engine.c:h ждёт по смыслу, прочие).