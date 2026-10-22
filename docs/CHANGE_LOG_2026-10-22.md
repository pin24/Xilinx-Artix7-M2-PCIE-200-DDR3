# CHANGE_LOG — 2026-10-22

Сессия: расследование зависания платы, исправление драйвера и RTL, проверка эмуляцией.
Базовая прошивка на плате: NUM_MAC=32 / ADDERS=16 / DEVPROG_EN=1 (CORE_PARAMS=0x1020).
Сборка flat, без DFX.

---

## 1. Инцидент: зависание host-DMA записи (h2c)

**Симптомы**
- `ring_check --depth 1024` ранее проходил (~2300 dots/s); после убитого посреди DMA процесса:
  `write_dma(0x200000)` → `XdmaError('timeout at 0x200000')` (10 c), повторяемо.
- Регистры (AXI-Lite) читаются, `read_dma` (c2h) работает ~16 мс.
- Ядро tdot IDLE (BUSY/MEM/R_WAIT=0, кольцо пусто, device_prog inactive).

**Диагноз (аудит 3 агентов + read-only проверки)**
- Общий путь к DDR3 один: `S00/S01/S02/S03 → xdma_axi_smc → M00 → MIG`; AXI-Lite — отдельный
  `xdma_axi_lite_smc`, поэтому регистры живы при мёртвом DMA-пути.
- Заблокирован **только** H2C (запись): чтение по тому же порту проходит → MIG и арбитр живы.

## 2. [BUG-072] Таймаут в `EvtIoWriteDma`/`EvtIoReadDma` оставлял IRP незавершённым
- Файл: `xdma_driver_win_src_2017/sys/file_io.c`.
- Причина: `XDMA_EngineWaitCompletion` на таймауте сам захватывает `txnDone` (dma_engine.c:1632-1641)
  и НЕ завершает request; затем второй CAS в `EvtIo*Dma` видел `owner=false` и делал `return`
  без `WdfRequestComplete` → IRP и последовательная очередь залипали навсегда.
- Фикс: вместо `return` — лок с уровнем Info и дальнейшее завершение (`UnmarkCancelable` →
  `Release` → `Complete(status)`). От двойного завершения защищает `txnDone`-guard в
  `EngineProcessTransfer` (dma_engine.c:336-343).

## 3. [BUG-073] Гонка cancel∩timeout: оба пути отступали
- Файлы: `libxdma/dma_engine.h`, `libxdma/dma_engine.c`, `sys/file_io.c`.
- Причина: при таймауте poll забирал `txnDone`; `EvtCancelDma` видел `!ownTxn` → `return`,
  а `EvtIo*Dma` на `STATUS_CANCELLED` → `return`. Никто не завершал IRP.
- Фикс: поле `BOOLEAN txnTimeout` (ставит только poll-владелец на таймауте; DPC ставит FALSE;
  сброс на старте транзакции). `EvtCancelDma` при `pollTimeout` сам делает
  `EngineStop` + `WdfDmaTransactionRelease` + `WdfRequestComplete(STATUS_CANCELLED)`.
  Ровно один завершает во всех четырёх комбинациях (poll/cancel/DPC/watchdog).
- Шум: `TraceError` на штатном таймауте заменён на `TraceInfo`.
- Сборка: драйвер **1.2.7.4**, подписан WDKTestCert, установлен как **oem194.inf**.

## 4. [BUG-074] RTL: у AXI read/write-мастеров не было таймаута
- Файл: `rtl/integration/tdot_axi4.sv`.
- Причина: `RST_ACT` ждёт `rd_total` бит без ограничения; зависший burst на общем M00→MIG
  не освобождался ни `sched_flush` (работает только в `CS_IDLE`), ни DP-watchdog.
- Фикс: watchdog'и read и write burst (лимит `1<<19` тактов ≈ 4.2 мс при 125 МГц),
  счётчики `rd_timeout_events`/`wr_timeout_events`, RO-регистры **0x62/0x63** (байты 0xF8/0xFC).
- Плюс controller-side abort: по импульсу таймаута задача ретирится (`sched_rptr++`,
  `done_cnt++`, `busy=0`, переход в `CS_IDLE`) — кольцо продолжает движение даже при мёртвой шине.

## 5. Ошибки, допущенные и исправленные в ходе работы
- [BUG-075] `RD/WR_TIMEOUT_LIMIT = 1<<20` не влезал в `logic [19:0]` → сравнение `>= 0`
  срабатывало сразу, все результаты нулевые. Поймано xsim (`несовпадений 4`). Исправлено на `1<<19`.
- [BUG-076] После срабатывания таймаута `rd_to_cnt/wr_to_cnt` не обнулялись → `ARVALID`
  больше не поднимался (тихая порча данных). Поймано аудитом с собственным TB. Исправлено.
- [BUG-077] `obs_smi` читал `rr(0x62)/rr(0x63)` — байтовые смещения вместо слов
  (нужны `0xF8/0xFC`), из-за чего показывал DONE_CNT и ложный баннер TIMEOUT. Исправлено.
- [BUG-078] `DP_WDOG_MAX = 1<<22` не влезает в `logic [19:0] dp_wdog_cnt` → сторож device_prog
  не срабатывал никогда (pre-existing). Счётчик расширен до `[21:0]`.
- Инструментальные грабли: `.bat`-обёртки Vivado мангулируют `-timescale`/`=`;
  `Set-Content -Encoding UTF8` в PS5.1 добавляет BOM (xvlog падает на 0xEF);
  `xelab > xelab.log` конфликтует с собственным `xelab.log` (CRITICAL WARNING 17-183);
  `verify_tdot_axi4.py` требует `PYTHONUTF8=1` (локаль cp1251).

## 6. Проверка эмуляцией
- `tb_timeout_abort` (зависший slave): **RESULT: PASS** —
  `rd_timeout_events=1` после ~104859 циклов, `status=0x2` (busy=0, done=1) за 1 опрос,
  второй прогон снова доходит до таймаута (сброс счётчика работает).
- `verify_tdot_axi4.py`: **проверено 4, несовпадений 0** (NUM_MAC=32).

## 7. Состояние аппарата
- До перезагрузки плата остаётся в залипшем h2c-состоянии (следствие прерванной DMA-операции).
- Драйвер 1.2.7.4 активируется только после reboot (disable/enable устройства ядро не подменяет).
- Прошивка **не собиралась и не прошивалась** в этой сессии; команда сборки:
  `vivado -mode batch -source scripts\build_flat.tcl -tclargs NUM_MAC=32 ADDERS=16 DEVPROG_EN=1 JOBS=4 -nojournal`

## 8. Известные незакрытые узлы
- device_prog→кольцо: интерпретатор выдаёт задачи без ретира/backpressure; end-to-end на железе не работает.
- Путь таймаута не проверялся на реальном железе (только xsim).
- Гонка cancel∩timeout исправлена статически; нужна проверка под Driver Verifier с инъекцией отмены.

## 9. Изменённые файлы
- `xdma_driver_win_src_2017/sys/file_io.c`, `libxdma/dma_engine.c`, `libxdma/dma_engine.h`
- `driver/dma/build.cmd` (версия 1.2.7.4)
- `rtl/integration/tdot_axi4.sv`
- `scripts/obs_smi.py`
- `docs/audit-hang-2026-10-21/`, `docs/audit-rerun-2026-10-21/`, `docs/audit-changes-2026-10-21/`
- `docs/CHANGE_LOG_2026-10-22.md` (этот файл), `docs/ERROR_HISTORY.md`, `docs/worklog.md`


## 10. Инцидент 2026-10-22 (после коммита aee457e): XDMA-функция пропала с шины
- Наблюдение: `Get-PnpDevice -PresentOnly` и `pnputil /enum-devices /connected` не содержат ни одного `VEN_10EE`;
  `\\.\XDMA0dma` -> WinError 3; остались два фантома "PCI Memory Controller" (Unknown).
- До инцидента: серия установок 1.2.7.1→1.2.7.4 (oem192/193/194) без перезагрузки на фоне залипшего h2c.
- Не наш дефект: Problem 19 в системе — Intel SMBUS (oem140.inf).
- Влияние: проверка драйвера и любые чтения платы невозможны.
- Требуется: reboot хоста; при отсутствии устройства — power-cycle/reseat M.2, затем проверка привязки 1.2.7.4.
- Статус: ОТКРЫТО (BUG-079).

---

## [ПОЗДНЕЕ, вечер 2026-10-22] BUG-089: h2c-wedge — диагностика и устранение (фикс 1-бис)

### Диагноз
- Одиночная 4 КиБ h2c-запись (1 дескриптор) случайно вешала движок XDMA (2/2 power-cycle).
- `perf_get` (IOCTL 0x3): `dataCycleCount=256` при старте 0, `pendingCount=0` → движок выдал все 256 бит 4 КиБ на AXI, но write-response/completion не вернулся. c2h следом `BUSY`, IRQ pending=0.
- Локус: общий downstream-путь `xdma_axi_smc → async CDC 125→100 → MIG`.

### Фикс (вариант 1-бис)
- `scripts/xdma_ddr3_bd.tcl`: SmartConnect `xdma_axi_smc` переведён **целиком на 125 МГц** (aclk/aclk1/aclk2 все 125; aclk1 убран с MIG ui_clk).
- async-CDC 125→100 **вынесен из SMC** в отдельный `axi_clock_converter:2.1` (`ACLK_ASYNC=1`) между `SMC.M00_AXI` и `mig_7series_0/S_AXI`.
- Коммиты: `85a6afd`, `27cecf5`. Валидация BD в реальном flow (`SKIP_SYNTH`) — exit=0.

### Верификация (прошивка 32/8, на плате)
- Лестница 4…512 КиБ ×3 — все OK, exit=0, `LADDER DONE` (до фикса вешало на первой 4 КиБ).
- Стресс 60×512 КиБ — все match=True, 0 fails.
- BUG-089 закрыт на железе (ERROR_HISTORY.md).
