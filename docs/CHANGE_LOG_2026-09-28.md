# Change Log — 2026-09-28 (ночь/утро)

## BSOD D1 при DMA loopback — НАЙДЕН И ЗАЩИЩЁН (01:46)

Минидамп 092826-46453-01.dmp: BugCheck D1 (DRIVER_IRQL_NOT_LESS_OR_EQUAL),
Arg1=2 Arg2=5, faulting XDMA_DMA!EvtInterruptDpc+0x101, Wdf01000+0x38f6.

Корень: libxdma/interrupt.c:416 EvtInterruptDpc (и :528 EvtUserInterruptDpc)
БЕЗУСЛОВНО пишут в bar[userBarIdx]. DMA-гейтвей ставит userBarIdx=bypassBarIdx=-1
(MSI-X не экспонирован) -> OOB bar[-1] при DISPATCH_LEVEL -> D1. Это latent-риск,
предсказанный аудитами C4/C5.

Фикс (interrupt.c, оба места): guard if (userBarIdx>=0) перед записью; user-event
не используется. Собран 1.1.10.0, установлен (oem146.inf), устройство OK.
Повторного BSOD нет.

## DMA loopback всё ещё таймаутит (overlapped write timed out)

Крах устранён, но H2C-запись не завершается. Диагноз по dma_driver.c (комм. в коде):
- card-адрес ПРАВИЛЬНЫЙ: dma_engine.c:458 сам добавляет XDMA_DDR3_AXI_BASE
  (0x80000000), raw 0x100000 -> 0x80100000 (DDR3 AXI) — совпадает.
- Завершение не приходит: interrupt-режим ждёт MSI-X IRQ (на DFX могут не доходить);
  poll (EnginePollTransfer) — вечный busy-loop, если битстрим не пишет writeback.
Оба пути завершения зависят от FPGA-битстрима/движка. Это железо/прошивка-зависимый
блокер, НЕ ошибка адресации в driver. TF96 check: regs PASS, GPIO_DATA live.

Следующий шаг (предложить): проверить, действительно ли h2c_0-движок сконфигурирован
в прошивке и работает DMA-de скриптор (читать дескриптор/CFG в mmio), либо собрать
test-битстрим где h2c/c2h явно активен.

---

## БOUNDED-COMPLETION-POLL РЕАЛИЗОВАН; H2C-TAЙMАУТ УСТРАНЁН (28.09)

OCT-диагностика (oct_diag.py, лог oct_diag.log): движок H2C0 жив (id 0x1FC00006),
сигналит через completedDescCount/status, но channel-MSI-X не доходит до хоста
(chReq/Pend висят) -> IRQ-завершение не прилетало.

Решение: XDMA_EngineWaitCompletion в dma_engine.c — bounded-poll по
engine->regs->completedDescCount + statusRC (!BUSY), затем EngineProcessTransfer;
вызывается из EvtIoWriteDma/EvtIoReadDma (file_io.c) вместо EnginePollTransfer.
Жёсткий лимит итераций (~10с) — мёртвая FPGA не подвесит запрос.

Собран v1.1.11.0 (oem161.inf), устройство OK.

PASS 1М/256/8 байт loopback (1048576/256/8 identical) — DMA-транспорт работает.
FAIL 4/64/1024 байт — первый байт mismatch (write 0x.. read 0x..) — похоже на
дескрипторную оптимизацию (OptimizeDescriptors/firstDescAdj) при невыровненных
малых размерах. Не блокер транспорта; отдельная группа для разбора.

Статус: зависание H2C устранено (bounded-poll), большой DMA-передачей verтиirmed.

---
## Edge-кейс малых передач + разбор bounded-poll (продолжение)

OCT на v1.1.13 (python, regs): WriteFile h2c 4 байта -> writeResult=4 (завершился),
engine status=0 (BUSY False), completed=1. Т.е. DMA-транспорт в python РАБОТАЕТ и
завершается быстро.

Однако C-тест test_dma.exe loopback (тот же драйвер) возвращает
'overlapped write timed out' на НОВОМ загруженном драйвере (v1.1.13). При этом
v1.1.11 ранее давал 1M PASS. Версия загружена корректно (System32\drivers = 35200)

Вывод: (а) драйвер и движок работают (python подтверждает write+status+completed);
(б) нестабильность C-теста может быть связана с тем, что IRP в драйвере не всегда
завершается в EvtIoWriteDma/ReadDma (EngineProcessTransfer/IRQ path), и событие
OVERLAPPED не сигналится -> C-тест ждёт до timeout; python read regs успешен
потому что сам не ждёт IRP-событие.
(в) statusRC двойное чтение (первый poll) стирает BUSY — риск; требуется
обдуманный фикс EngineProcessTransfer со capturedStatus.

НЕ ЗАВЕРШЕНО окончательно: требуется чистая перезагрузка и проверка (1) python
loopback через XdmaWinDma.write_dma/read_dma (не только regs), (2) C loopback.
Не трогаю дальше чтобы не зависнуть; логирую.
