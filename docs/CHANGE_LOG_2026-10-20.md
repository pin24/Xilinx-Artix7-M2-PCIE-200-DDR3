# CHANGE LOG — 2026-10-20 (DMA-завершение: регрессия v1.1.33 устранена, драйвер v1.2.2)

Каталог: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3` (main).

## 1. Инцидент
На прошивке flat 16/4 (BUILD_ID `32'hb3e07b13`, v1.1.29 RTL) DMA `write_dma`/`read_dma`
стабильно давал **10-секундный таймаут** (`timeout at 0x100000`): IRP не завершался,
драйвер возвращал ошибки (`996 ERROR_IO_INCOMPLETE` / `STATUS_TIMEOUT`). При этом:
- DDR3 откалибрована и готова (`GPIO2_DATA=0x03`: `mmcm_locked=1`, `init_calib_complete=1`);
- адресация и карта регистров верны (аудит: H2C0=0x0, C2H0=0x1000, SGDMA=+0x4000, IRQ=0x2000
  совпадают с pg195 и прошивкой);
- конфиг XDMA/MSI-X/DDR3 побайтно идентичен эталонной рабочей прошивке;
- движок XDMA реально выполнял транзакцию, но драйвер не доводил её завершение до хоста.

## 2. Причина (корень)
Регрессия внесена в **v1.1.33 (коммит `d7520aa`)**: `EvtIoWriteDma`/`EvtIoReadDma`
переведены с синхронного завершения на **асинхронный `EvtTransferCompleteCb` + watchdog**.
`EvtTransferCompleteCb` вызывается KMDF **только** когда `WdfDmaTransactionDmaCompleted==TRUE`,
то есть когда прерывание (MSI-X) реально доходит до хоста через ISR/DPC. На ненадёжном
канальном MSI-X прерывание не достигало хоста → никакой путь не вызывал завершения →
request висел и падал в watchdog (~10 c). В рабочем **v1.1.29** завершение было
**синхронным** (`EngineProcessTransfer` сам делал DmaCompleted→Release→CompleteWithInformation)
и не зависело от прерывания; блокирующий poll `XDMA_EngineWaitCompletion` доходил до железа
сам.

Промежуточная правка v1.2.1 вернула poll, но лишила watchdog и CAS в `EvtCancelDma`
(2 латентных дефекта: возможный вечный ханг при `DmaCompleted==FALSE` и двойной Release
в cancel↔DPC).

## 3. Фикс (v1.2.2, проверен на железе)
Вернулась **синхронная модель завершения по образцу рабочего v1.1.29**:
- `libxdma/dma_engine.c` — `EngineProcessTransfer` (case `XDMA_ENGINE_STOPPED_OK`) после
  `WdfDmaTransactionDmaCompleted` сам выполняет
  `WdfRequestUnmarkCancelable` → (для C2H `XDMA_EngineResetIdle`) →
  `WdfDmaTransactionRelease` → `WdfRequestCompleteWithInformation`. Завершение больше
  не зависит от `EvtTransferCompleteCb`/прерывания.
- `sys/file_io.c` — в `EvtIoWriteDma`/`EvtIoReadDma` убрана регистрация
  `WdfDmaTransactionSetTransferCompleteCallback`; оставлен блокирующий
  `XDMA_EngineWaitCompletion(engine,200000)` (~10 c) после `WdfDmaTransactionExecute`.
  Watchdog в этих путях не армлится (как в 1.1.29).
- `sys/file_io.c` — `EvtCancelDma` получил **CAS по `engine->txnDone`** (участие cancel в
  флаге-собственнике транзакции — закрывает двойной Release/0x10D).
- `driver/dma/build.cmd` — `DRIVER_VERSION=1.2.2.0`, полное WPP (tracewpp для
  dma_engine/interrupt/device + гварды `#if defined(DBG)||defined(WPP_ENABLED)`).

## 4. Верификация на железе (после установки, disable/enable драйвера)
- `test_dma_win.py`: `test_regs_tdot_readback` PASS, `test_dma_loopback_4b/1k/1M` PASS,
  `smoke` OK. `write_dma` и `read_dma` завершаются мгновенно, **данные round-trip корректны**.
- `test_dma_perf_ioctl` FAIL `WinError 50` — IOCTL `PERF_STOP` есть только в v1.1.34,
  в базе v1.2.2 (d7520aa) отсутствует — несоответствие версии теста, не поломка.
- Устройство привязано к `oem186.inf` = **1.2.1.0→1.2.2.0** (апстрим `4&167CEF57&0&00E4`).

## 5. Выводы по сопутствующему
- **Проблема была чисто драйверной** (завершение зависело от прерывания), **не** в
  железе/адресации/прошивке. Аудит 6 агентов подтвердил: `interrupt.c`, конфиг MSI-X,
  раскладка регистров и запуск движка идентичны эталону.
- **Один DMA-канал** (h2c_0/c2h_0) используется потому, что `sys/driver.c.substituted:137`
  создаёт **одну default-Sequential I/O очередь на все каналы** + один `dmaTransaction` на
  движок. Два аппаратных H2C/C2H канала есть, но параллельное использование h2c_1/c2h_1
  потребует переделки на per-channel очереди (отдельная задача).

Версионирование с 2026-10-20: **1.2.x**.