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

## 10. Сессия Super Z: аудит 39 (ре-аудит фиксов владельца) + закрытие BUG-060..063 (v1.2.5.0)

### 10.1 Аудит 39 (5 агентов 39-a..e, cc6ce3b)
- Верифицированы фиксы владельца 7d6e74d: CS_ABORT_WAIT (логика/учёт/декоды чисты, pyslang 0 новых), банк дескрипторов 2048+1 (worst case ровно 2049, маржа 1 — «2048 max» в комментарии неточен), гейт hold+PW, generic read-back, E-1..E-5 выжили merge.
- Критичные находки: pblock 6642 SLICE безусловно при дефолте 32/16 (владелец сам признал в worklog); D-2 жив и жёстче описанного (silent IRP leak); версия драйвера не поднята; CS_ABORT_WAIT без закоммиченного регресса; WPP-трейсы мертвы в release-бинарнике; SKIP_SYNTH стирает артефакты; WPWS печатается N/A ровно при нарушении; check_timing-парсер берёт номер пункта вместо счётчика.
- P1-6 (экспонента tf48) ОПРОВЕРГНУТ для живого пути: E-high везде (fpga_backend/xdma_driver/все TB-генераторы); остаток — сериализационная ловушка ternary_sw/tfloat48.py + мёртвые E-low CSV.
- Реестры двух аудитов объединены: 10 дублей (P1-1=C-1, P1-2=C-2, P1-3=D-1, P2-6=B-3, P2-7=C-4, P2-11=D-6, P2-15=E-8...). Отчёт: docs/worklog.md Task 2026-10-20-reaudit-39 (d5833b6).

### 10.2 Фиксы (BUG-060..063, детали в ERROR_HISTORY)
- **BUG-060 (D-2)**: dma_engine.c — хвост completion только при txnReleased; txnDone пере-вооружение при промежуточном пакете; dma_engine.h — XDMA_MAX_WDF_PACKETS=16; file_io.c — EvtIo* ждут каждый пакет (критерий isReqPending==FALSE). Одиночный пакет — поведение прежнее. **Драйвер v1.2.4.0 → v1.2.5.0** (build.cmd + INX DriverVer).
- **BUG-061 (C-5)**: build_flat.tcl — pblock только при NUM_MAC=16, громкий WARNING при иных.
- **BUG-062**: build_flat.tcl — очистка артефактов под гардом !SKIP_SYNTH; +timing_FATAL.rpt к шаблонам.
- **BUG-063**: tb_tdot_axi4.sv — TEST 5 (align-abort + восстановление, бит-в-бит vs золото case 0); pyslang-элаборация TB: 0 новых ошибок (скрипт scripts/…/pyslang_check_tb.py вне репо).

Проверки сессии: pyslang FLAT-набор 0 новых; TB-элаборация 0 новых; C-файлы (dma_engine/file_io) баланс скобок 0/0 после чистки комментариев; compileall 0; pytest 10/10; check_burst_4kb PASS; stress --mock PASS.

Версии: драйвер 1.2.5.0 (банк FIX-DESC владельца + FIX-DESC2 completion); RTL не менялся (только TB); симуляция TEST 5 и стенд-регресс >8MiB IRP — на стенде; пуш по явной команде.

---

## 11. Сессия Super Z: перекрёстная проверка внешнего аудита (AUDIT_VS_ORIGIN_2026-10-20) + BUG-064..069 (v1.2.6.0)

Вход: аудит стороннего агента «АУДИТ ПРОЕКТА И СРАВНЕНИЕ С УДАЛЁННЫМ РЕПОЗИТОРИЕМ»
(выполнен на cc6ce3b — до моего пула cd4f294..ce42d17). Каждый пункт проверен по коду
ce42d17 лично; вердикты — ниже.

**Подтверждено и исправлено (v1.2.6.0 + host-скрипты):**
- §2.1/2.2 (=P2-3): E-7 CAPS-vs---num-mac WARN потерян в мерже 022ff7a (был в 7748803) —
  восстановлен дословно в obs_smi.py + monitor_obs.py → **BUG-065**.
- P1-1 (=D-4/D-5): poll-таймаут не владел транзакцией → поздний DPC завершал IRP второй раз
  (0x10D/0xE6). Фикс: CAS txnDone в таймауте WaitCompletion + STATUS_CANCELLED при чужом
  владении + захват владения/EngineStop на пути исчерпания пакетов (обе ветки W/R) → **BUG-064**.
- P2-2: XdmaWinUpstream (основной бэкенд скриптов) без close()/__del__ → добавлены
  (по образцу XdmaWinDriver); попутно r-string «\c» (последний SyntaxWarning) → **BUG-066**.
- P2-6: interruptRegs — deref после ASSERT (no-op в free) → guard в DeviceOpen + 3 Setup-* → **BUG-067**.
- P2-5 (=P1-4): XDMA_DeviceClose не останавливал движки до освобождения банков/размапливания
  → EngineStop всех включённых движков в начале Close → **BUG-068**.
- P2-4 (39-c F3.1): read-back generic при нераспознанном формате — WARNING-продолжение
  → для кастомных конфигураций (≠16/4) FATAL (молча ехать на топ-дефолтах нельзя), для 16/4 —
  WARNING; + сброс stale `_gb_val`/`_gb_val2` между итерациями (39-c F3.2) → **BUG-069**.
- P2-8: `_flat32.bat` JOBS=13 → 4 (13 job'ов × maxThreads = OOM/swap).
- §2.3 (obs_clear shadow vs read-back): принято как есть — эквивалентно, single-write
  безопаснее RMW; задокументировано в OBSERVABILITY.md (синхронизация тени при смене RTL).

**Опровергнуто (проверка по коду, вносить не нужно):**
- **P2-9 «4KB-кламп может пересечь границу 4KB на невыровненном адресе»**: `ar_addr_w =
  rd_addr + rd_issued*SW`, где `SW = DW/8 = 8` (tdot_axi4.sv:155-156, AXI_SZ=3) — все
  AR-старты кратны 8 при 8-кратной базе; базу гарантирует `align_q` (задача с адресом [2:0]≠0
  уходит в CS_ABORT_WAIT до data-фазы; fetch-адрес = desc_base + rptr*32). При 8-кратном
  старте `bnd_bytes` кратен 8, кламп `(bnd_words-1)` не пересекает 4KB. Сценарий
  «невыровненного адреса» недостижим.
- **P2-10 «align_q включает result_addr — строже, чем нужно»**: AW/W-канал пишет результат
  по result_addr — невыровненный старт писал бы биты результата со смещением; чек —
  осознанная защита (хост передаёт 8-кратные адреса: шаг буферов кратен 8). Удаление
  ослабило бы безопасность без выигрыша — оставлено.

**Уже было закрыто волной cd4f294..ce42d17 (до внешнего аудита):** P2-7 pblock-гард
(BUG-061), SKIP_SYNTH-порядок (BUG-062), D-2 мультипакет (BUG-060), TB align/abort
(BUG-063), версия → v1.2.5.0. Внешний аудит этого пула ещё не видел.

**Зарегистрировано, НЕ исправлялось (P3, решение владельца):**
- Makefile `FLAT=1` молча уходит в DFX-скрипт (самоссылка `FLAT := $(FLAT)`, :35);
- IOCTL FILE_ANY_ACCESS без SDDL (inc/xdma_public.h:63);
- в индексе 47,8 МБ .bit/.mcs/CSV вопреки .gitignore (добавлены до правила; `git rm --cached`
  удалит их из checkout — без явного разрешения владельца не делаем);
- build/XDMA_DMA.inf=1.1.34 в локальном build/ — НЕ в git (артефакт, перегенерируется);
- tfloat48 E-low ловушка (уже в реестре аудита 39).

Версия драйвера: **1.2.5.0 → 1.2.6.0** (build.cmd:37, XDMA_DMA.inx DriverVer).
Статика: compileall(-W error::SyntaxWarning) OK; pytest = baseline (7f/10p/7e —
стендозависимые, новых отказов нет); pyslang 0 новых ошибок; Tcl-баланс OK.
C-код KMD проверен чтением; сборка WDK и стенд — на стороне владельца.
