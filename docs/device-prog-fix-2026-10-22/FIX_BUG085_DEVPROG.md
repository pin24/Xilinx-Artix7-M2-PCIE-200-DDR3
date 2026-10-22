# Черновик (v2, после аудита/эмуляции): устранение BUG-083/084/085 — device_prog (2026-10-22)

Статус: ЧЕРНОВИК, ревизован аудитом. Применять только после внесения P0/P1 (ниже) и новой эмуляции.

## 1. Проблема
- **BUG-083** DP-watchdog мёртв: `dp_wdog_cnt[21:0]` (`tdot_axi4.sv:811`) vs `DP_WDOG_MAX=1<<22` (`:810`), `>=` (`:955`) недостижимо.
- **BUG-084** Controller-abort ретирит sched-задачу без записи completion (`tdot_axi4.sv:984-994`): `collect()`/`dot_batch` может принять стейл-слот за валидный.
- **BUG-085** Та же abort-ветка не сбрасывает `use_dp_q/dprog_active_q`, не пишет mailbox, не дренирует FIFO → device_prog «висит».

## 2. Корень (подтверждено аудитом)
- abort-ветка `if (rd_to_fire||wr_to_fire)` (`:984`) байпасит `case` — из неё нельзя перейти в CS_DP_MBOX1/2 в том же такте.
- **Fallback-статус CS_DP_MBOX2 жёстко = SUCCESS** (`:1296-1299` `{40'h0, n_units, 8'd0}`) — «reuse CS_DP_MBOX1/2 для abort» запишет status=0=успех.
- **device_prog не останавливается по `en=0`**: `en` используется только на ST_IDLE (`device_prog.sv:175`) и ST_DONE (`:289`); во ST_EXEC/FETCH снятие `en` FSM не сбрасывает. При этом push в FIFO (`tdot_axi4.sv:924-930`) гейтится только на `DEVPROG_EN && dp_desc_task_valid && dp_fifo_ready`, НЕ на `dprog_active_q`. → остаток программы после abort вклинивается в следующий батч (порча).
- Аудит подтвердил: мульти-драйва нет (единый `always_ff :885-1326`); DP-задача в abort не трогает `rptr/done_cnt/irq` (`use_sched_q=0`), штатный sched-поток не затрагивается.

## 3. Контракт (Вася + аудит)
> Каждый запуск (успех ИЛИ abort) → ровно один completion-mailbox со статусом (0=ок, !=0=ошибка) → возврат в IDLE. Сериализация: следующий запуск не начинается, пока текущий не завершён (mailbox записан, активные флаги сняты).

Поправки аудита к контракту:
- `desc_task_ready` — это **вход** device_prog (backpressure от FIFO), «импульс на поглощение» через него невозможен; потребление «зомби» достигается только сбросом device_prog (`en=0` → ST_IDLE) + `dp_rdptr<=0`.
- «Mailbox в любом случае» неабсолютен на мёртвой write-шине: abort-mailbox-write сам может упасть в `wr_to_fire` (`:737-746`). Нужен host-fallback по DP_STAT.

## 4. Правки RTL
### 4.1 `tdot_axi4.sv`
1. **Push FIFO** гейтить ещё и на `dprog_active_q` (а не только `dp_desc_task_valid && dp_fifo_ready`) — `:924-930`.
2. **Abort при `use_dp_q`** — защёлкнуть mbox-валиды с **терминальным статусом != 0** и уйти в mbox-запись:
   ```
   if (rd_to_fire || wr_to_fire) begin
       ... существующий retire :987-993 ...
       if (use_dp_q) begin
           // W0 base: tag/units
           dp_mbox0_valid  <= 1'b1; dp_mbox0_addr <= dprog_mailbox_base_q;
           dp_mbox0_data   <= {48'h0, dprog_n_units_q};
           // W1 base+8: status = ABORT (НЕ 0!)
           dp_mbox1_valid  <= 1'b1; dp_mbox1_addr <= dprog_mailbox_base_q + 32'h8;
           dp_mbox1_data   <= {40'h0, dprog_n_units_q, DP_STATUS_ABORT};
           cstate          <= CS_DP_MBOX1;      // обходят fallback-статус SUCCESS
       end else cstate <= CS_IDLE;
   end
   ```
   (Не использовать CS_DP_MBOX2-фолбэк «как есть» — он запишет 0=успех.)
3. **BUG-083**: `logic [22:0] dp_wdog_cnt` (или `DP_WDOG_MAX=(1<<22)-1`). По срабатыванию `dp_wdog_active_q=1` → тот же терминальный путь (п.2).
4. **BUG-084**: для sched-abort писать слот COMP со `status=timeout` (CS_CMP1..3) либо в host сверять события; не оставлять стейл.
5. `dprog_complete_q` при abort **не ставить** (семантика «программа раскодирована end-to-end», `:281`); для ошибки использовать `dp_wdog_active_q`/новый `dp_abort_q`, читаемый хостом из DP_STAT 0xF4.

### 4.2 `device_prog.sv`
- При `!en` форсировать `state<=ST_IDLE`, гасить `desc_task_valid/table_req/mailbox_wr_start/done/fetch_pend`; сбрасывать внутренние task-регистры/счётчики. Без этого (находка C) — порча следующего батча. `:175, :230-290`.

## 5. Правки host (`pytorch_layer/xdma_driver.py`)
- `DeviceProgRunner.run`: `lsw = read_status(expected=0)`; статус `= lsw & 0xFF`; **при status!=0 не возвращать результат как валидный** (сейчас `read_status` возвращаемое значение отбрасывается, `:1343`, а результат читается всегда, `:1346`).
- На таймаут `read_status`: читать `DP_STAT` (0xF4: `dp_wdog_active/dprog_complete/dprog_active/dp_stall_code/dp_fifo_level`, `tdot_axi4.sv:526-527`) → диагностика «успех/abort/stall», а не вечное ожидание.
- `collect()`: перед доверием слоту сверять `status`, при stейл/abort — отбрасывать. Добавить константы/чтение 0xF8/0xFC (`rd_timeout_events/wr_timeout_events`, `tdot_axi4.sv:520-521`) — сейчас в драйвере их нет.

## 6. Тесты / эмуляция
- **Базовый синтаксис**: `xvlog` device_prog.sv — OK (2026-10-22).
- `tb_timeout_abort` **в репозитории отсутствует** — не регрессия, а **новый TB**, обязателен:
  1. штатный device_prog → mailbox status=0, done;
  2. abort (rd/wr_to_fire в DP-режиме) → mailbox status=ABORT, `dprog_active/use_dp_q` сброшены, FIFO дренаж, способность принять новый запуск;
  3. веджнутая write-шина (abort-mailbox сам не проходит) → host-fallback через DP_STAT;
  4. push FIFO гейтится на `dprog_active_q` (после abort нет «фантомных» задач);
  5. backpressure (valid во время EXECUTE → готовность только после mailbox).
- **Регрессия ядра**: `verify_tdot_axi4.py` (4/4) — убедиться, что не сломан штатный abort→retire.
- **Аудиты**: пройден один (выводы ниже); при внесении — повторный RTL/host-аудит.

## 7. Итог (результаты тестов/аудитов/эмуляции — 2026-10-22)
- **Эмуляция**: `xvlog` device_prog.sv компилируется без ошибок (базовая ок). Содержательного TB по device_prog/abort нет — создаётся по §6.
- **Аудит (агент)**: диагностика BUG-083/084/085 подтверждена по коду; мульти-драйва нет; штатный sched-abort не ломается. Найдены P0: (1) device_prog не сбрасывается по `en=0` + push не гейтится на `dprog_active_q` → порча следующего батча; (2) «reuse CS_DP_MBOX1/2» запишет status=0=успех — нужен явный ABORT-статус; (3) host не проверяет статус mailbox и не имеет fallback по DP_STAT на мёртвой шине. P1: `<3/#3>` про backpressure переформулировать; `tb_timeout_abort` = новый TB. P2: `dprog_complete_q` при abort маскирует успех; docstring CompletionMailbox; 0xF8/0xFC в драйвере.
- **Вердикт**: план применим после внесения P0+P1; применять в RTL (tdot_axi4 + device_prog) и host, затем новый TB + verify_tdot_axi4 + повторный аудит, затем пересборка 32/8 → прошивка → репро device_prog (штатно + abort).

## 8. Принятие (после внесения)
- [ ] P0 1-3 и P1 внесены.
- [ ] Новый TB (сценарии 1-5 §6) — PASS.
- [ ] verify_tdot_axi4 4/4.
- [ ] Повторный аудит RTL/host.
- [ ] Пересборка 32/8 → прошивка → на плате: device_prog штатно (status=0) и при abort (status!=0 + бэкенд-диагностика) — не залипает.