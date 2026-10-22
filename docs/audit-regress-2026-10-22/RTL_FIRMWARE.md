# Аудит-регресс RTL/прошивки tdot после правок 2026-10-21/22

**Дата:** 2026-10-22 (чт)
**Платформа:** flat-сборка, NUM_MAC=32, ADDERS=16, DEVPROG_EN=1
**Объект:** `rtl/integration/tdot_axi4.sv` (1551 стр.), `rtl/integration/device_prog.sv` (313 стр.),
`pytorch_layer/xdma_driver.py`, `scripts/obs_smi.py`, TB `C:\Temp\gigatool\tb_timeout\*`
**Методы:** статический анализ, xvlog/xelab/xsim (эмуляция), git-diff (aee457e^..aee457e).
Запись в плату и модификация production-файлов НЕ выполнялись.

---

## 1. Регрессия на дефолтном пути (фактический прогон)

| Проверка | Команда | Результат |
|---|---|---|
| Основная регрессия | `python verify_tdot_axi4.py 32` (env `PYTHONUTF8=1`, PATH с Vivado 2025.2) | **несовпадений 0** (4 случая, NUM_MAC=32) |
| TB таймаута (копия без `timescale`, `C:\Temp\gigatool\tb_timeout\tb_to_nots.sv`) | `xvlog -sv -f files_nots.txt` + `xelab tb_timeout_abort` + `xsim tb_to -runall` | **RESULT: PASS** (`rd_timeout_events=1`, `[ok] watchdog fired`, `[ok] core left busy`, 2nd run `rd_timeout_events=2`, `[ok] P0 closed`) |

### Важное замечание о `-timescale` и "копии без timescale"
- Инструкция «прогнать xvlog с `-timescale`» НЕВЫПОЛНИМА: `xvlog` в Vivado **2025.2 не имеет опции `-timescale`** (справка `xvlog --help` её не содержит; передача `-timescale 1ns/1ps` вызывает «unrecognised option», что и зафиксировано в `run_fixed3/xvlog.pb`).
- Заявленная «копия без timescale/BOM» `C:\Temp\gigatool\tb_timeout\tb_timeout_abort.sv` по факту **СОДЕРЖИТ `timescale 1ns / 1ps` на строке 7** (BOM отсутствует, первые байты `47 47 32` = `//` ASCII). Именно поэтому корневой `xelab.log` (репо) падает с **XSIM 43-4099** («Module tdot_axi4 doesn't have a timescale but at least one module in design has a timescale»).
- Рабочий фоллбок-путь: временная копия без строки `timescale` (все модули, включая TB, без timescale → единый дефолт 1ns/1ns, `Time Resolution 1ps`). Только так TB собирается и даёт PASS. **Production-файлы не менялись.**

---

## 2. Корректность новых AXI-таймаутов (RD/WR 1<<19)

| Утверждение | Проверка (код/xsim) | Вердикт |
|---|---|---|
| `1<<19=524288` помещается в `rd_to_cnt[19:0]` (20 бит) | `1<<19` = бит 19 установлен, 20-бит диапазон 0..1048575 → влезает | **ОК** (арифметика корректна; в отличие от DP_WDOG_MAX — см. §5) |
| Условия прогресса (сброс счётчика) | RST_ACT: `(ar_valid_r&&M_AXI_ARREADY) \|\| (M_AXI_RVALID&&r_ready_r)` → `rd_to_cnt<=0` (tdot_axi4.sv:650); WST_ACT: `AW\|\|W\|\|B` прогресс (tdot_axi4.sv:734). Порядок «сначала сброс, потом проверка fire» исключает ложное срабатывание в такт handshake | **ОК** |
| Нет ложных срабатываний на легальном burst (BURST_RD_LEN=32, 4KB-кламп) | Основная регрессия 4 случая прошла без таймаута (`несовпадений 0`); 4KB-кламп `ar_len_w` (tdot_axi4.sv:1352-1366) на легальном пути не блокирует AR. AR-выдача гасится `!fifo_full`, но при data(≤32)+weights(≤32)=64=ровно FIFO_DEPTH AR не блокируется на легальном path | **ОК** (легальный burst до 524288 тактов без прогресса не дотягивает) |
| Нет ложных срабатываний на backpressure `fifo_full` | `fifo_full` только блокирует выдачу нового AR; при легальном заполнении FIFO до 64 AR уже выдан (rd_issued==rd_total), счётчик стоит на последнем beat и сбрасывается по нему; длительного «затишья» на легальном cons-stream нет | **ОК** на нормальном трафике |
| Сбросы счётчиков (P0) | RS-сброс + `rd_to_cnt<=0` в fire-ветке; TB подтвердил 2-й запуск (`rd_timeout_events=2`) | **ОК** (TB PASS) |
| Нет мульти-драйва NBA на `r_ready_r/ar_valid_r/aw_valid_r/w_valid_r` | Каждый из этих сигналов присваивается **в одном** `always_ff` (read-мастер 608-672 / write-мастер 703-756). Внешних ассайнов на них НЕТ (выходы идут через `assign M_AXI_* = <reg>`). | **ОК** (мульти-драйв отсутствует) |
| `rd_timeout_sticky/wr_timeout_sticky` | Устанавливаются в 1 при fire, но **не читаются ни одним регистром и не сбрасываются** (tdot_axi4.sv:251,655,742) | **Мусор/dead-code** (не функциональная ошибка; наблюдаемы только events 0xF8/0xFC) |
| Событийные счётчики 0xF8/0xFC | `rd_timeout_events[31:0]`/`wr_timeout_events` инкрементируются на каждый fire, не очищаются host (считают с reset). Отображаются в obs_smi.py:277-284 | **ОК** (диагностика) |

**Риск ложного срабатывания при mid-burst stall (средний):** WD срабатывает, если между beats одной транзакции пауза >5.2 мс (524288×10нс). MIG при сильной конкуренции DDR в принципе может выдать такую паузу в середине burst. В этом случае после abort в slave остаются «осиротевшие» beats/b responses (см. §3-риски), которые на следующей задаче могут попасть в FIFO как её данные (AXI in-order по общему ID=0). Вероятность низкая, импакт высокий.

---

## 3. Controller-abort (tdot_axi4.sv:984-994)

| Аспект | Анализ | Вердикт |
|---|---|---|
| Что с FIFO | Аборт сбрасывает только `r_ready_r/ar_valid_r`, FIFO-указатели НЕ обнуляются на месте; мусорных слов после abort остаётся столько, сколько успело прийти. Очистка — только `fifo_clr` следующей задачи (`job_start\|CS_SCHED_KICK\|CS_DP_KICK`). В CS_IDLE FIFO не читается → безвредно до старта следующей задачи | **ОК** (кроме orphaned-burst, см. риск ниже) |
| `res0_reg/res1_reg` и completion | На abort результат НЕ пишется: для legacy `res0/res1` остаются СТАРЫМИ; host должен трактовать DONE=1 + BUSY=0 после abort как «нет результата». Для sched completion-запись ПРОПУСКАЕТСЯ (rptr/done_cnt всё равно +1) → в слоте completion остаётся СТАРОЕ содержимое | **ДЕФЕКТ-риск(host): см. §7** |
| `sched_rptr_q/done_cnt_q` + `CS_CMP3` | Двойного ретира нет: fire-обработчик выставляет `cstate<=CS_IDLE`, и `case(cstate)` (в т.ч. CS_CMP3) в этом такте не выполняется. При abort в CS_FETCH_DESC `use_sched_q==0` → rptr НЕ двигается → дескриптор перечитывается повторно (идемпотентно) — корректно. При abort после CS_SCHED_KICK rptr/done_cnt идут в fire-обработчике ровно раз | **ОК** (без двойного инкремента/рассинхронизации) |
| `use_dp_q`/`CS_DP_WAIT` | **ДЕФЕКТ:** fire-обработчик НЕ очищает `use_dp_q` и НЕ снимает `dprog_active_q`. После abort DP-задача: cstate=CS_IDLE, busy=0, done=1, но use_dp_q=1/dprog_active_q=1 висят, mailbox не пишется, dp_wrptr/dp_rdptr не сброшены. В CS_IDLE нет DP-ветки без `dprog_start_q` → устройство застревает в «полуактивном» режиме до старта НОВОЙ программы. DP-watchdog не спасает, т.к. он не срабатывает вовсе (см. §5) | **ДЕФЕКТ (DEVPROG_EN=1)** |
| `busy_q` в режимах | legacy: busy=0,done=1 — ок. sched: busy=0,done=1,rptr+1 — ок (completion пропущен). dp: busy=0,done=1, но active/use_dp не сняты — дефект | legacy/sched **ОК**, dp **ПОЛОМАН** |

**Риск (средний): осиротевший burst/B-response.** Если WD сработал на mid-burst stall (не полная 100%-тая заморозка шины), `r_ready_r`/`b_ready_r` снимаются при живых outstanding-транзакциях. Т.к. оба мастера используют ID=0 (in-order), освободившийся slave вернёт «хвост» прежней транзакции на следующем чтении/записи как данные новой задачи → **порча данных/B-рассинхрон**. В TB проверен только полностью мёртвый slave (RVALID=0 всегда); частичный stall не покрыт.

---

## 4. Регистры 0x62/0x63 (байты 0xF8/0xFC)

| Вопрос | Анализ | Вердикт |
|---|---|---|
| Место в декодере | `6'd62/6'd63` объявлены в read-decoder НАД DP-регистрами; `rd/wr_timeout_events` объявлены (стр.252) ДО декодера (стр.455) | **ОК** (объявления до использования, xvlog проходит) |
| Конфликт с занятыми offsets | Word 62/63 → byte 0xF8/0xFC. Заняты: 0xE4..0xF4 (DP 57-61), 0x6C..0xE0 (OBS). Свободные 0xF8/0xFC — конфликта нет | **ОК** |
| word vs byte для host | Адресация `araddr_q[7:2]` — СЛОВА; byte = word*4. host правильно читает `0xF8`(=62), `0xFC`(=63) в obs_smi.py:279. Memory-нота о «0x62/0x63 алиасится на DONE_CNT» относится к чтению БАЙТА 0x62 (=word 0x18=DONE_CNT 0x60) — это старый подводный камень, в текущем коде его нет (используются 0xF8/0xFC) | **ОК** |
| `OBS_REGMAP_V=1` не обновлён | Новые регистры 0xF4/0xF8/0xFC НЕ входят в OBS-блок/тень (0x6C..0xE0). Формально OBS_REGMAP_V описывает только OBS-карту — не добавление регистра не противоречит. НО: `obs_smi` при отсутствии firmware-регистров прочитал бы 0 (default `rdata=32'h0`) и показал «rd=0 wr=0» — ложный «нет таймаутов» вместо «n/a». Fallback `except` ловит только исключения, не «0» | **ОК формально, но рекомендация: поднять OBS_REGMAP_V до 2, чтобы host отличал новое прошивки** |

---

## 5. device_prog

| Аспект | Анализ | Вердикт |
|---|---|---|
| Интерфейс `desc_task_*`, backpressure | Наличие `desc_task_ready` в device_prog.sv:75 и ST_EXEC (device_prog.sv:230-277): `valid` держится с полезной нагрузкой, счётчики нейрона/пасса не продвигаются, пока `!ready` → **потерь задач нет** | **ОК** |
| table-путь (CS_DP_WAIT ∧ dpt_state) | `rd_total=1` только в DPT_WAIT, ipte `dp_table_permit=(CS_IDLE\|\|CS_DP_WAIT)` (tdot_axi4.sv:807). В CS_DP_WAIT задача не ставится, пока идёт table-чтение (tdot_axi4.sv:1235-1243) — FIFO не переполняется | **ОК** |
| mailbox-путь | CS_DP_MBOX1/2 пишут 2 слова по mailbox_base/+8 со статусом; конфликтов с abort нет (abort gасит путь раньше). `dp_progress` включает MBOX1/2 в «прогресс» | **ОК** |
| `DP_WDOG_MAX=(1<<22)` после расширения | **ДЕФЕКТ (ПОДТВЕРЖДЁН xsim):** `dp_wdog_cnt[21:0]` — 22 бита, макс 4194303; `(1<<22)=4194304` требует БИТ 22 (23 бита). Комментарий «FIX 2026-10-22: 1<<22 needs 22 bits» (tdot_axi4.sv:811) — НЕВЕРЕН. Условие `dp_wdog_cnt >= DP_WDOG_MAX` НИКОГДА не истинно: счётчик переполняется молча (4194303→0) и таймер не срабатывает. Проверено отдельным xsim: прокручено 25,165,824 тактов (6× порог), `fired` так и не поднялся. | **ДЕФЕКТ высокого приоритета — watchdog device_prog мёртв** |
| Правка не рвёт длинные валидные программы | Даже если исправить ширину на `[22:0]`, порог 4194304 тактов (~42 мс) >> любой валидной паузы между задачами (таблица/exec микросекунды) → валидные длинные программы не пострадают | после фикса ширины — **ОК** |
| Взаимодействие с abort | См. §3: abort не снимает dprog_active_q/use_dp_q, а dp-watchdog не работает → DP-режим виснет при AXI-таймауте до следующего batch | **ДЕФЕКТ** |

---

## 6. Сверка RTL ↔ host (offsets, маски, формат)

| Пункт | RTL | host | Вердикт |
|---|---|---|---|
| OBS CAPS/CORE_PARAMS/MAGIC | CAPS@0x74 `{v,1,CAPS_L2BURST,ADDERS,NUM_MAC}`; CORE_PARAMS@0x64 `{16'h0,ADDERS,NUM_MAC}`; MAGIC@0x68=`0x54444F54` | xdma_driver.py:783-787 читает CAPS/regmap, CORE_PARAMS; obs_smi.py считывает regmap_v | **ОК** |
| RD/WR timeout events | 0xF8/0xFC (word 62/63) | obs_smi.py:279 `rr(0xF8)/rr(0xFC)` + маркер `** TIMEOUT **` | **ОК** |
| DP регистры | write decoder 6'd57..60 → byte 0xE4..0xF0; read 6'd57..61 → byte 0xE4..0xF4 | DP_CTRL/DATA/TABLE/MBOX_BASE = 0xE4/0xE8/0xEC/0xF0; избыточный `DP_CTRL` read в state() (0xE4) матчит `{n_units,15'h0,active}` | **ОК** |
| Completion формат/tag | CS_CMP1: W0=`{job_tag,res1[15:0],res0}`; CS_CMP2: W1=`{48'h0,passes,6'b0,align,sat}` (tdot_axi4.sv:1206,1215) | collect() читает `tag=W0>>48`, `result=W0&48`, `status=W1&0xFF`, `passes=(W1>>8)&0xFF` | **ОК** (формат совпадает) |
| Scheduler ring | RING-1024: rptr/wptr 10 бит, desc собир. CS_FETCH_DESC | xdma_driver.py: mask=0x3FF, submit/wait/collect по mod 1024 | **ОК** |
| **Dropped completion на abort (host)** | abort продвигает rptr/done_cnt БЕЗ записи completion (tdot_axi4.sv:988-993) | `runtime.wait()` видит rptr advance как «задача завершена»; `collect()` читает СТАРЫЕ данные слота; `dot_batch` проверяет только `status!=0` и НЕ смотрит 0xF8/0xFC → **симlently возвращает устаревший result** | **ДЕФЕКТ (серьёзный host-side)** |

---

## 7. Сводный список дефектов/рисков (по приоритету)

| # | Приоритет | Область | Дефект/риск | Место |
|---|---|---|---|---|
| 1 | **CRITICAL** | device_prog | **DP watchdog НИКОГДА не срабатывает**: `dp_wdog_cnt[21:0]` не может достичь `DP_WDOG_MAX=(1<<22)=4194304` (нужно 23 бита). Комментарий «needs 22 bits» ошибочен. Подтверждено xsim (25М тактов без срабатывания). Оригинальный дефект (не помещался в [19:0]) лишь частично «починили» | tdot_axi4.sv:810-811, 955 |
| 2 | **HIGH** | host + RTL | **Silent data corruption при aborted sched-task**: RTL ретирит задачу без записи completion; host `collect()`/`dot_batch()` читает СТАРОЕ содержимое слота и не проверяет 0xF8/0xFC → устаревший result/status молча возвращается как валидный | tdot_axi4.sv:988-993; xdma_driver.py:1098-1158 |
| 3 | **HIGH** | device_prog | **Abort не очищает DP-FSM**: `use_dp_q`/`dprog_active_q` остаются 1, mailbox не пишется, FIFO-задачи не сброшены → DP-режим виснет до нового batch (dp-watchdog бесполезен, см. #1) | tdot_axi4.sv:984-994 |
| 4 | **MEDIUM** | AXI abort | **Осиротевший burst/B-response при mid-burst stall**: снятие RREADY/BREADY при живых outstanding (ID=0, in-order) → хвост прежней транзакции попадает в данные следующей / B-рассинхрон. TB покрывает только полностью мёртвый slave | tdot_axi4.sv:650-662, 734-749 |
| 5 | **LOW** | AXI WD | `rd/wr_timeout_sticky` — dead signals (устанавливаются, нигде не читаются и не сбрасываются) | tdot_axi4.sv:251,655,742 |
| 6 | **LOW** | obs/proшивка | `OBS_REGMAP_V=1` не отражает новые 0xF4/0xF8/0xFC; obs_smi на старой прошивке покажет «rd=0 wr=0» (ложный «чисто») вместо «n/a» | tdot_axi4.sv:235; obs_smi.py:277-284 |

### Что могло проявиться ПОСЛЕ обновлений (сопоставление с симптомами)
- **Тихий abort / зависание busy в DP-режиме**: #1+#3. На DEVPROG_EN=1 плата при AXI-таймауте во время device_prog не восстанавливается dp-watchdog'ом и не очищает DP-FSM — ядро застревает, host ждёт mailbox до своего host-timeout.
- **Порча данных**: #2 (host молча берёт stale completion) и #4 (orphaned beats) в wedged-bus сценарии.
- **Ложный DONE**: #2 — abort ставит `done_q=1` без результата; host по DONE=1 читает старый RES0/RES1 (legacy), или по RPTR-advance берёт старое completion (sched).
- **DP watchdog не срабатывает** всегда (не только после обновления) — дефект ширины унаследован от «фикса» 2026-10-22.

---

## 8. Ограничения аудита
- Не проверялись: реальная плата (запись запрещена), синтез/тайминг (только эмуляция), mid-burst-stall сценарий (TB не покрывает), долгий DP-сценарий с переполнением FIFO (>64 задач) в интеграции.
- xsim зафиксирован в `C:\Temp\gigatool\tb_timeout\run_audit\` (xvlog/xelab/xsim успешны) и `C:\Temp\gigatool\tb_wdog_width\run\` (доказательство дефекта #1).
- Вердикты — статический анализ + эмуляция; верификация на железе остаётся за вами.