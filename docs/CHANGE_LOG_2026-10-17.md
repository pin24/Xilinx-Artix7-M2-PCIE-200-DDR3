# CHANGE LOG — 2026-10-17 (BSOD 0x10D_4 при перекрытии W+R, фикс EvtCancelDma)

Каталог: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3` (main).

## 1. Инцидент
При запуске DMA-бенчмарка (большой блок + перекрытие write/read потоками) — BSOD.
- Дамп: `C:\Windows\MEMORY.DMP` (2009 МБ) + миндамп `101726-37171` (пустой) 17.10 09:30.
- **BugCheck 0x10D, Arg1=4** («NULL-параметр») — Probably caused by **`XDMA_DMA!EvtCancelDma+42`**.
- Стек: `EvtCancelDma → WdfDmaTransactionRelease/RequestComplete → FxVerifierNullBugCheck → KeBugCheckEx`. PROCESS_NAME= python.exe.

## 2. Причина
`EvtCancelDma` при отмене выполнял повторный `WdfDmaTransactionRelease` + `WdfRequestComplete`,
когда транзакция УЖЕ обработана `EngineProcessTransfer` (DmaCompleted/Release/Complete) —
двойная обработка освобождённой транзакции → KMDF Verifier (пустой/двойной, 0x10D Arg1=4).
Возникло при перекрывающихся W/R и/или большой транзакции. Имеет место на НЕАКТИВИРОВАННОМ
старом драйвере (без фикса txnDone; перезагрузка не выполнялась).

## 3. Фикс
`xdma_driver_win_src_2017/sys/file_io.c` — `EvtCancelDma`: если `engine->txnDone` уже TRUE
(транзакция завершена), выходим без повторного Release/Complete. Компиляция OK.

## 4. Контекст
- Предыдущий BSOD (15.10): 0x10D Arg1=8 — двойной DmaCompleted в EngineProcessTransfer;
  фикс (txnDone guard) внесён, собран как v1.1.30, НО НЕ активирован (нужна перезагрузка).
- Оба бага — класс «гонка/двойная обработка DMA-транзакции»; закрываются согласованно
  (router + отменой) только после активации нового .sys.

## 5. Рекомендации
- Перезагрузить систему для активации драйвера v1.1.30 (с обоими фиксами).
- Не запускать перекрывающиеся W/R тесты до активации.
- Миндампы при малом ОЗУ: полный MEMORY.DMP отключён (minidump), но при сбое до reboot
  каждый раз пишется ~2 ГБ — установить minidump-только и, при возможности, освободить диск.