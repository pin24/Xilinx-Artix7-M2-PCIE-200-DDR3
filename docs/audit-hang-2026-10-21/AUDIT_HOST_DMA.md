# AUDIT_HOST_DMA — разбор зависания H2C write_dma после убийства процесса в середине DMA

> Репозиторий: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3` (HEAD 496272b)
> Драйвер: oem191.inf **v1.2.7.0** (`driver/dma/build.cmd:37` DRIVER_VERSION=1.2.7.0)
> Дата: 2026-10-21. Ракурс: host-DMA. Запись в плату не производилась — только чтение кода/логов и предложения read-only проверок.

---

## 1. Исходные факты инцидента (наблюдение на реальной плате)

1. До инцидента `ring_check --depth 1024` работал стабильно (~2300 dots/s), `mailbox_check` — проходил.
2. В одной shell-команде запущены `ring_check` и `mailbox_check`; процесс убит **СЕРЕДИНЕ операции** (`ChildProcess.kill`).
3. После убийства: `TdotScheduler.__init__` проходит, чтение регистров (AXI-Lite) OK, но первый `write_dma(0x200000, blob)` → `XdmaError('timeout at 0x200000')`. Кольцо пустое, счётчиков нет, AXI-Lite жив.

Оба скрипта используют `XdmaWinDma` из `pytorch_layer/test_dma_win.py` и гонят данные через DMA-каналы `\\.\XDMA0dma\h2c_0`/`c2h_0`:
- `scripts/ring_check.py:32-33` — `from test_dma_win import XdmaWinDma; dev = XdmaWinDma(base=r"\\.\XDMA0dma")`
- `scripts/mailbox_check.py:44-45` — тот же `XdmaWinDma`, `write_flag`/`read_status` через `write_dma`/`read_dma` (mailbox_check.py:101-115).

---

## 2. Что конкретно значит `XdmaError('timeout at 0x200000')`

### 2.1 Возникновение на хосте (Python)

`XdmaWinDma._xfer` (`pytorch_layer/test_dma_win.py:135-168`). Для записи (`is_write`):
- `WriteFile(h= self._h2c, buf, len(data), &n, &ov)` (test_dma_win.py:147).
- `ov.Offset = 0x200000` (test_dma_win.py:140) — первый 1-МиБ чанк из `write_dma(0x200000, blob)` (test_dma_win.py:232-234).
- Если `WriteFile` вернул `FALSE` и `GetLastError()==997` (`ERROR_IO_PENDING`) → `WaitForSingleObject(self._ev, timeout_ms=10000)` **по строке test_dma_win.py:155**.
- Если `WaitForSingleObject` вернул НЕ `0` (т.е. `WAIT_TIMEOUT`/`WAIT_FAILED`) → **raise `XdmaError(f"timeout at 0x{offset:X}")` на test_dma_win.py:156**.

Итак, ошибка означает: **`WriteFile` вернул `ERROR_IO_PENDING`, и IRP в ядре не был завершён за 10 секунд**. Плюс offset=0x200000 — это `ddr_off`, т.е. DMA-запись в DDR3 по адресу `0x80000000 + 0x200000` (добавку `XDMA_DDR3_AXI_BASE` делает сам драйвер, см. п.4.1).

### 2.2 Что происходит в ядре (драйвер)

`WriteFile` на узел `\h2c_0` → `EvtIoWrite` (`file_io.c:476`) → forward в очередь движка → `EvtIoWriteDma` (`file_io.c:685`):

1. Сброс `engine->txnDone=FALSE` (file_io.c:699-703).
2. `WdfDmaTransactionInitializeUsingRequest(... XDMA_EngineProgramDma, WriteToDevice)` (file_io.c:708).
3. `WdfDmaTransactionSetMaximumLength(8 MB)` (file_io.c:723).
4. `WdfRequestMarkCancelableEx(Request, EvtCancelDma)` (file_io.c:728).
5. `WdfDmaTransactionExecute` → `XDMA_EngineProgramDma`: строит дескрипторы, `XDMA_EngineResetIdle`, `EngineStart` (RUN bit), `engine->irqBitMask`… (dma_engine.c:899-1117).
6. **Блокирующий bounded-полл** `XDMA_EngineWaitCompletion(engine, 200000)` (file_io.c:761; ~10 c).
7. В `XDMA_EngineWaitCompletion` (dma_engine.c:1553-1646): цикл до `maxIterations`, читает `completedDescCount` и `statusRC`, ждёт `!BUSY && completed >= numDescriptors` (dma_engine.c:1584-1595).
8. Если за ~10 c не сошлось → `EngineStop`, `STATUS_TIMEOUT` (dma_engine.c:1623-1644) → `EvtIoWriteDma` завершает IRP с `STATUS_TIMEOUT` (file_io.c:816).

**Важно:** драйвер НЕ зависает навсегда — его внутренний полл ограничен ~10 c (dma_engine.c:1568-1573: `passiveMaxIter=maxIterations/20` = 10000 итераций по 1 мс). IRP в итоге завершается (успехом, либо `STATUS_TIMEOUT`). Python-сторона имеет свой собственный таймаут `WaitForSingleObject(...10000)` (test_dma_win.py:155). Оба — ~10 c, поэтому при реально незавершённой передаче они **гонятся**; в отчёте зафиксирован именно `timeout` (test_dma_win.py:156), т.е. Python сдал раньше/одновременно с ядром. Ключевой вывод: **передача физически не завершилась за 10 c** — это сигнал о незавершённой DMA на железе, а не о «висячем» IRP в ядре.

---

## 3. Может ли убитый `proc` оставить «висячий» pending DMA/IRQ (вопрос 2)

Да, на уровне ядра остаётся состояние, но v1.2.2+ спроектирован так, чтобы оно **не блокировало следующий перенос навсегда**. Разбор путей завершения/отмены:

### 3.1 Что происходит при kill процесса
- ОС закрывает handle'ы → `EvtFileCleanup` (`file_io.c:227`): для C2H-ST делает `EngineRingTeardown`; **движок H2C НЕ останавливается и НЕ сбрасывается** здесь.
- «Висячий» WriteFile-IRP отменяется ОС → `EvtCancelDma` (`file_io.c:968-1016`):
  - CAS по `engine->txnDone` под `engineLock` (file_io.c:987-995) — единственный владелец Release.
  - `EngineStop(engine)` — снимает RUN (file_io.c:1003 → dma_engine.c:1154 `controlW1C = RUN_BIT`).
  - `WdfDmaTransactionRelease` + `WdfRequestComplete(STATUS_CANCELLED)` (file_io.c:1010-1015).
- Параллельно поток очереди мог ещё крутиться в `XDMA_EngineWaitCompletion`; по истечении итераций он делает CAS и, т.к. cancel уже стал владельцем, возвращает `STATUS_CANCELLED` (dma_engine.c:1644) → `EvtIoWriteDma` выходит, не трогая IRP (file_io.c:768-771).

### 3.2 Остаточное состояние
- Зависший **аппаратный** движок: после `EngineStop` (снят RUN) карточный контроллер XDMA находится в «середине» дескрипторной цепочки; `BUSY` может остаться.
- `isReqPending` после cancel **не** обнуляется (EvtCancelDma его не трогает; он остаётся TRUE) — но spurious-IRQ guard (`engine->work` в `EngineProcessTransfer`, dma_engine.c:318-327) проверяет `isReqPending` и при повторном входе/позднем DPC с `txnDone=TRUE` отбрасывает двойную обработку (dma_engine.c:329-344). Двойного завершения транзакции нет (это закрыто CAS — см. аудит R1, `AUDIT_FULL_2026-10-19.md:84,154`).

### 3.3 Почему следующий перенос НЕ блокируется ядром
- Начало следующего запроса: `EvtIoWriteDma` сбрасывает `txnDone=FALSE` (file_io.c:699).
- `XDMA_EngineProgramDma` пересоздаёт дескрипторы в `descBuffer` с нуля, вызывает `XDMA_EngineResetIdle` (RUN снят, `statusRC` read-clear, `firstDescLo/Hi` **переприцелен на базу descBuffer**, `firstDescAdj=0`), затем `EngineStart` (dma_engine.c:1100-1112).
- Полл `XDMA_EngineWaitCompletion` стартует с нуля с `expected = numDescriptors` (dma_engine.c:1566), поэтому «старый» pending не влияет на порог.

**Вывод по Q2/Q3:** на уровне **host-драйвера** после kill нет необратимого «висячего» pending, который блокировал бы следующий H2C-перенос навсегда. Более того, повторный `open` (новый `XdmaWinDma`) вообще **не сбрасывает/не пересоздаёт движок и не чистит очереди на железе** — движки создаются один раз при загрузке драйвера в `EvtDevicePrepareHardware` (`dma_driver.c:196`) и в `EngineCreate`/`XDMA_EngineResetIdle`; открытие файла лишь ставит `devNode->u.engine` и включает/выключает прерывание (`file_io.c:198-205`). Поэтому «дочистка прерванного DMA при повторном open» **отсутствует** — это дизайн драйвера, и его хватает для восстановления **программного** состояния, но не для «отлипления» застрявшего аппаратного блока (см. §6).

---

## 4. Как открывается устройство и есть ли гонка в `_xfer` (вопросы 3 и 4)

### 4.1 Адресация и маршрутизация записей
`XdmaWinDma` открывает `\control`, `\user`, `\h2c_0`, `\c2h_0` (test_dma_win.py:114-129). Чтение периферии идёт через `\user` (test_dma_win.py:119, 174), а `write_dma` — через `\h2c_0` (test_dma_win.py:234). Драйвер добавляет AXI-базу DDR3 централизованно в `XDMA_EngineProgramDma` (`dma_engine.c:934-936`), т.е. `0x200000` → кард-адрес `0x80200000`.

### 4.2 Новый объект ≠ сброс движка (Q3)
`XdmaWinDma.__init__` лишь `CreateFileW` на узлы. Он **не** дёргает никакие регистры сброса XDMA-движка. Полноценный «reopen» не дочищает DMA: сброс аппаратного движка происходит только внутри нового переноса (`XDMA_EngineResetIdle`), а если карта/интерконнект застряли — этого сброса недостаточно.

### 4.3 Гонка в `_xfer` после убийства (Q4)
`_xfer` использует один manual-reset event `self._ev`, созданный в `__init__` (test_dma_win.py:130), и перед каждым переносом вызывает `ResetEvent` (test_dma_win.py:143). При последовательных вызовах (TdotScheduler держит `threading.RLock`, xdma_driver.py:937, 1102) гонки нет. При `ChildProcess.kill` процесс и его handle'ы закрываются ОС, поэтому:
- события/OVL от убитого процесса не могут «протечь» в новый процесс;
- новый `XdmaWinDma` создаёт свежий `_ev`;
- `wait`/overlapped-состояние нового инстанса чистое.
`BUG-071` (~15 мс/IOCTL) — это латентность «маленькой» MDL-транзакции (зафиксировано в `QUICKSTART_TESTING.md:110`, `device-prog-2026-10-20.md:4`), а не гонка/зависание. То есть Q4-гипотеза (handle в плохом состоянии от kill) **маловероятна**.

---

## 5. Разделение «host-состояние» vs «железо застряло» (вопрос 5)

Ниже read-only проверки. Все — чтение регистров через `\control` (config-BAR), где лежит блок XDMA-движков. `XdmaWinDma` сам по себе `\control` для чтения **не использует** (нет метода на движковые регистры); для чтения конфиг-BAR есть готовый `XdmaWinUpstream.read_config()` (`xdma_driver.py:549-555`, идёт через `_ctl`). Единственный узел — открыть config-BAR чтением.

### Регистры (смещения в config-BAR, по `libxdma/reg.h` и `dma_engine.c:694-728`)
- H2C_0: `offset = dir*0x1000 + ch*0x100` = **0x0**; C2H_0: **0x1000**.
  - `control` = base+0x04 (`XDMA_ENGINE_REGS.control`), `RUN=bit0`
  - `status` = base+0x40 (RO), `statusRC` = base+0x44 (read-clear), `completedDescCount` = base+0x48
  - `intEnableMask` = base+0x90
- SGDMA: H2C base **0x4000**, C2H base **0x5000**; `firstDescLo`=base+0x80, `firstDescHi`=+0x84, `firstDescAdj`=+0x88, `descCredits`=+0x8C.
- IRQ block base **0x2000**: `channelIntEnable`=+0x10, `channelIntRequest`=+0x44, `channelIntPending`=+0x4C.

### Read-only процедура (никогда не писать в плату)
1. **Состояние движка после инцидента**: прочитать `\control` H2C_0 `status` (0x40) и `completedDescCount` (0x48). Если `BUSY=1` и `completedDescCount` не растёт при последующих read-only опросах — аппаратный перенос застрял **на железе**.
2. **Очередь завершений/прерываний**: `channelIntPending` (0x204C), `channelIntRequest` (0x2044), `channelIntEnable` (0x2010). Если `Pending`/`Request` ненулевые и не гаснут — аппаратное прерывание «залипло» (движок сообщил о завершении, но host не обработал). Если всё нули при застрявшем DMA — движок не выдаёт completion вообще.
3. **firstDesc / движок**: `firstDescLo/Hi/Adj` (0x4080/0x4084/0x4088). Если указывает на актуальный descBuffer и `Adj` согласован — программная перепривязка выполнена; по-прежнему зависает только аппаратура.
4. **Полный сброс движка** (только как резерв, требует записи — обсудить с владельцем, в этом аудите НЕ выполнять): драйвер не имеет ioctl на `XDMA_CTRL_RST` (bit31 `control`, `reg.h:74`); только перепрошивка/reboot. Это отдельное действие, вне read-only.
5. **Наблюдение AXI-Lite**: то, что `read` регистров (через `\user`) работает, а `write_dma`/`read_dma` (через `\h2c_0`/`c2h_0`, M_AXI→DDR3) — нет, само по себе **указывает на блокировку пути M_AXI→DDR3**, т.к. AXI-Lite-BAR и DMA-в DDR3 расходятся в интерконнекте.
6. **Состояние TDOT-ядка** (наблюдено в памяти проекта): `OBS_BUSY` (0x40023000+0x80), `OBS_MEM` (0x84), `SCHED_RPTR/WPTR`, `DP_CTRL` (0xE4). Если ядро застряло в `BUSY/MEM 100%`, `DP_CTRL.bit0=active=1`, `RPTR/WPTR` застыли — источник «занятой» DDR3 находится в TDOT/device_prog (см. §6).

---

## 6. Гипотезы

### H1 (ВЫСОКАЯ): аппаратное/прошивочное зависание пути M_AXI→DDR3, вызванное застрявшим TDOT/device_prog ядром
- **Механизм.** Kill оставил TDOT/device_prog ядро в активном состоянии (`BUSY=1`, фаза памяти 100%, наблюдалось на плате 2026-10-21; в т.ч. `DP_CTRL.active=1`, `RPTR=1018 WPTR=44`, `done_cnt=1018`). Ядро держит/не освобождает доступ к DDR3 через общий M_AXI интерконнект. H2C DMA-запись в DDR3 (`0x80200000`) не получает ответа от контроллера памяти → `completedDescCount` не растёт → host-полл упирается в ~10 c → `timeout at 0x200000`.
- **Согласуется с фактами**: AXI-Lite (`\user`) жив (это другой путь, не через занятый DDR3-порт); регистры читаются; повторный open не помогает (движок/ядко не сбрасывается при открытии).
- Это **не дефект host-драйвера** — драйвер корректно репортит таймаут.

### H2 (MEDIUM): host-драйвер корректно завершает/освобождает (v1.2.2+ CAS), но общий дизайн не имеет аппаратного «отлипания» глухого движка при kill
- После cancel движок останавливается `EngineStop` (RUN снят), но карта может остаться в «середине» дескрипторной цепочки/префетча; последующий `XDMA_EngineResetIdle` перепривязывает `firstDesc` к новому буферу, однако **не сбрасывает карточный DMA-контроллер целиком** (`XDMA_CTRL_RST` не используется ни в одном пути отмены/восстановления; grep по `XDMA_CTRL_RST` → только определение в `reg.h:74`). Если у движка внутренний префетч «залип», следующая запись может стартовать с битой фазой. Это **латентная слабость хоста**, но без доказательства что она единственная.

### H3 (LOW): чистая host-гонка `_xfer`/overlapped после kill
- Опровергается: kill закрывает handle'ы, новый инстанс чист, single-event + ResetEvent при последовательных вызовах корректен (см. §4.3). `BUG-071` — не гонка.

### H4 (LOW): драйвер не обнуляет `completedDescCount`/`numDescriptors` между переносами → ложный «успех»/«таймаут»
- `numDescriptors` переустанавливается в `XDMA_EngineProgramDma` (`dma_engine.c:1082`), полл ждёт именно `>= numDescriptors` текущего переноса (`dma_engine.c:1566`). Не является причиной таймаута. (Отмечено как историческая причина иных ложных завершений — BUG-55, `ERROR_HISTORY.md:10-18`.)

---

## 7. Вывод

1. `XdmaError('timeout at 0x200000')` — это сигнал о **реально незавершённой физической H2C DMA-передаче за 10 c**, а не о «зависшем» IRP: и Python (`WaitForSingleObject`, test_dma_win.py:155), и драйвер (`XDMA_EngineWaitCompletion`, dma_engine.c:1584) ограничены ~10 c и завершаются таймаутом.
2. Kill процесса НЕ создаёт необратимого host-«висячего» pending-дескриптора/IRQ, который блокировал бы следующий перенос навсегда: v1.2.2+ свел отмену к строгому CAS владения транзакцией, следующий `ProgramDma` пересоздаёт дескрипторы и перепривязывает `firstDesc`.
3. Повторный open (новый `XdmaWinDma`) движок **не сбрасывает** (движки инициализируются при загрузке драйвера, открытие лишь включает interrupt). Поэтому ожидать «дочистки» прерванного DMA от повторного open нельзя.
4. Непосредственная причина (наиболее вероятная) — **застрявшее TDOT/device_prog ядро, удерживающее путь M_AXI→DDR3**, из-за чего H2C DMA не получает completion. Это согласуется с живым AXI-Lite и мёртвым DMA-в-DDR3.
5. Read-only дифференциация: опрос H2C_0/C2H_0 `status`/`completedDescCount`/`channelIntPending` (config-BAR) + OBS TDOT-ядра позволяет подтвердить «железо застряло» (BUSY=1, счётчики не растут) против «host-состояние».

### Рекомендованный следующий шаг (вне этого аудита, по согласованию с владельцем железа)
- Прошить/reboot плату или выполнить программный сброс TDOT-ядра и движков, чтобы снять «залипший» DDR3-путь, затем повторить `ring_check`. До этого любые новые DMA-записи будут упираться в тот же таймаут.
- Рассмотреть в драйвере необязательный ioctl полного аппаратного сброса движка (`XDMA_CTRL_RST`) на открытии узла `h2c_0` — как «мягкий» recovery после аварийного kill.