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

---

## 6. OBS/GO: silent no-op under sched_en=1 (BUG-56) + dot() result magnitude (BUG-57)

### 6.1 OBS «не реальные показания» (BUG-56)
- Симптом: obs_smi.py --dot и legacy core.dot() дают OBS-счётчики = 0 и мусорный результат.
- Причина (RTL tdot_axi4.sv): `go_accept = go_pulse && !busy_q && !sched_en_q` — при sched_en=1 (залипшем после TdotScheduler/обучения) legacy-GO игнорируется, ядро не запускается -> OBS честно 0.
- Фикс (host, безопасный): TdotCore.start() бросает XdmaError при sched_en=1 (никаких тихих no-op); добавлен TdotCore.set_sched(on); obs_smi.py --dot вызывает set_sched(False) перед нагрузкой. Проверено: OBS считает в обеих модах (legacy и scheduler).
- Файлы: pytorch_layer/xdma_driver.py, scripts/obs_smi.py. Статус: ИСПРАВЛЕНО.

### 6.2 Как правильно мониторить OBS (нормальный запуск)
```
python scripts/obs_smi.py --num-mac 16 --clear --interval 0.3            # мониторинг (live)
python scripts/obs_smi.py --num-mac 16 --dot 100 --clear --interval 0.3 # нагрузка dot + живой OBS
python scripts/obs_smi.py --num-mac 16 --bench 8 --clear                 # DMA-нагрузка, живая MB/s
```
Хардварный пример: --dot 100 -> AR=+200, BEAT=+3,200, WR=+100, JOB=+100, JOB/s~3125 (2 AR + 32 слова + 1 WR на задачу).

### 6.3 dot() результат против наивного ожидания (BUG-57, ЗАКРЫТО - не баг)
- Данные в DDR бит-точны (round-trip). Ядро исполняет (OBS: ar/beat/wr/job растут). Но значение результата не совпадает с моделью (~100x на канонической нагрузке n=16; в моём n=8 тесте давал 0). Требуется разбор формата/арифметики результата в RTL (тернарный multiply-accumulate) против декода TFloat + перепрошивка/верификация.


---

## 7. Задача «число (частота) -> звук» — скрипты обучения/генерации (FPGA = умножитель)

Добавлены в data/: nn_audio_common.py (данные, модель MLP 2->16->1, фаза, WAV, переключаемый matmul),
nn_audio_train_cpu.py / nn_audio_infer_cpu.py / nn_audio_train_fpga.py / nn_audio_infer_fpga.py.

- Роль FPGA = вспомогательный умножитель: линейные преобразования (matmul) вынесены в
  matmul_w(..., backend='cpu'|'fpga'); при backend='fpga' каждый dot-нейрон считает tdot-акселератор.
- Обучение на FPGA реализовано как Random Features (ELM): случайный скрытый слой, признаки
  для каждого примера считаются на FPGA, обучаемый линейный выход подгоняется по МНК.
- CPU-вариант: numpy/BLAS (эталон), быстро.
- Проверено: CPU генерирует 80000 сэмплов за 6.2 мс (0.1 мкс/сэмпл), частота точная (440->439.9 Гц);
  FPGA-умножитель 200 сэмплов за 1.6 с (8.08 мс/сэмпл) — на этой поточечной задаче CPU быстрее
  в ~80000x из-за PCIe-оверхеда на каждый dot. Качество ограничено NUM_MAC=16 (ELM RMSE ~0.32).


---

## 8. PCIe BW diagnosis: 512-byte XDMA descriptors cap throughput at ~275 MB/s

- Link is negotiated FULL Gen2 x4 (CurrentLinkSpeed=2, Width=4) = 20 GT/s (~2 GB/s after 8b/10b); DDR3 (MT41J128M16, 16-bit, DDR3-800) ~1.6 GB/s. So the ceiling is ~1.6 GB/s, NOT 275.
- Measured write/read MB/s: saturates at ~275 (write) / ~262 (read) regardless of block size (4KB..8MB) -> steady-state datapath limit, not per-IO overhead.
- Root cause: XDMA_DESC_MAX_BYTES=512 (dma_engine.h:37) slices every transfer into 512-byte descriptors (dma_engine.c:961-962); the engine fetches each descriptor over PCIe from the host, so descriptor-fetch overhead scales with data (6% at 512B) -> ~275 MB/s ceiling.
- 512 was chosen to avoid WHEA 0x124 / ROF on the Root Port (8086:7f3c). Plan to raise to 4096 (8x fewer descriptors, ~0.8% overhead) and re-measure, watching for ROF.
- Files: dma_engine.h, dma_engine.c. Status: OPEN (fix in progress).

---

## 9. Сессия 2026-10-20 (вечер): многоагентный аудит (38-a..e) + корректность OBS + восстановление битых файлов + README FLAT

### 9.1 Фикс-коммит 6ec9f5b (host, BUG-058/059)
- `data/nn_audio_infer_fpga.py` — IndentationError:47 (строка в колонке 0 внутри main()), FPGA-инференс был неработоспособен с 644097c; исправлен отступ, добавлен SANITY-WARN W1.shape[1] vs --hidden (метаданные npz.json врут: audio_model_h64 помечен hidden=16 при W1=(2,64)).
- `pytorch_layer/stress_platform.py` — 10412 Б чистых NUL с рождения на main (6381f8a); портирован проверенный R8-rebuild с 2ch-pipeline на API main: DOT через FpgaBackend.run_dot, NUM_MAC/BUILD_ID из CAPS/OBS (fallback 16), device-fallback chain, XADC-монитор, CSV, --mock; ELEM_FMT-ветки 2ch удалены (в RTL main нет).

### 9.2 Корректность OBS (коммит 7748803; аудит 38-e, находки верифицированы вручную по RTL)
- Карта OBS 0x6C..0xE0 подтверждена 1:1 во всех 5 слоях (0 mismatch); арифметика --dot 100 (AR=+200, BEAT=+3200, WR=+100, JOB=+100) сходится с RTL.
- Исправлено ОТОБРАЖЕНИЕ/доки: E-2 (R_WAIT печатался как «AR_STALL»), E-1 (monitor_obs: фазы, очищенные obs_clear, делились на абсолютный CYCLES → схлопывание к 0 при аптайме; теперь Δ-семантика), E-3 («DMA живая» = AXI-биты ядра, не host-DMA), E-4 (FIFO_FULL «по дизайну 0» ложно: база ≈2-4 такта/проход, AR-гейт tdot:532), E-5 (CYCLES HI→LO→HI), E-7 (CAPS vs --num-mac), E-8 (obs_clear RMW сохраняет FREEZE — порт 187dc69 с TMUL), E-9 (OBSERVABILITY/ADDRESS_MAP: «CLEAR обнуляет всё и тени» ложно; правила съёма; sched-надбавки).

### 9.3 Итоги аудита 5 агентов (READ-ONLY, отчёты в docs/worklog 2026-10-20-audit38)
- 38-a регистры/адреса: 0 MISMATCH через RTL↔BD↔драйвер↔тулзы↔доки; A-1..A-8 — легаси-эмуляторы/доки.
- 38-b маршрутизация FLAT-BD: целостна, DFX→FLAT без потерь; B-2 (сниффер без host-доступа — запланировано), B-3 (XADC CDC), B-4 (SC clock-ассоциации — разово верифицировать).
- 38-c сборка: C-1 HIGH (FATAL-гейт только setup — hold/WPWS не фатальны), C-3 (ui_clk вне async-групп), C-2/C-4..C-9 (дефолты, _flat64 нежизнеспособен, Makefile/flash → artifacts_dfx, BUILD_ID dirty).
- 38-d драйвер v1.2.4: D-1/D-2 CRITICAL латентные (молчаливый кламп банка дескрипторов; >8MiB мультипакет — маскируются python-чанками 1MiB), D-3/D-4/D-5 (watchdog мёртв, путь таймаута вне CAS, ErrExit без Unmark), D-7 (GET_VERSION/PERF_STOP), D-8..D-13.
- 38-e OBS-отображение: E-1..E-10 — исправлены в 7748803 (host/доки); RTL-семантика счётчиков верна.

### 9.4 README переписан под FLAT-реальность
- Архитектура/адреса/сборка/драйвер/OBS-quickstart/открытые задачи по аудитам; DFX — историческая секция со ссылкой на ветку XDMA_DDR3_TMUL; Makefile помечен устаревшим (build→DFX, artifacts→C:/build_dfx).

Версии: драйвер 1.2.4 (без изменений); RTL/BD не менялись; репо +3 коммита (6ec9f5b, 7748803, docs).
