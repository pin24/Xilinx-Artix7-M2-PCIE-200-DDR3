# OBSERVABILITY — наблюдаемость ядра tdot (OBS, Task 35)

Источники: `rtl/integration/tdot_axi4.sv` (декод `awaddr/araddr[7:2]`), идеи счётчиков —
openTPU (github.com/FeSens/openTPU, Apache-2.0). Реализовано в **main**-ветке с сохранением
host-контракта: `0x64=CORE_PARAMS`, `0x68=MAGIC` (в отличие от ветки `XDMA_DDR3_TMUL`, где
OBS занимают `0x64/0x68` — там нет CORE_PARAMS/MAGIC). Поэтому в main OBS сдвинуты на `0x6C+`.

## Регистровая карта OBS (main: база = REG_BASE/tdot 0x40023000)

| Смещение | Слово | Направление | Содержание |
|---|---|---|---|
| 0x6C | OBS_CTRL | W/R | W: bit0 CLEAR (импульс: обнулить 11 событийных счётчиков; CYCLES и SNAP-тени НЕ трогаются), bit1 FREEZE (уровень: пауза событийного счёта; CYCLES free-running не подчиняется). R: {30'h0, obs_freeze, 1'b0} — статус FREEZE читаем |
| 0x70 | BUILD_ID | R | первые 8 hex git-коммита битстрима (параметр `BUILD_ID` сборки; 0 = не передан) |
| 0x74 | CAPS | R | `[7:0]` NUM_MAC, `[11:8]` ADDERS (сатурация 15; в отличие от CORE_PARAMS 0x64, где ADDERS[7:0] без сатурации — при ADDERS=16 хост увидит 0x0F здесь и 0x10 в 0x64), `[15:12]` log2(BURST_RD_LEN), `[16]` есть планировщик (1), `[31:24]` REGMAP версия (=1) |
| 0x78/0x7C | CYCLES_LO/HI | R | 64-бит free-running счётчик тактов core_clk |
| 0x80 | BUSY_CYCLES | R | тактов `busy_q=1` (ядро исполняет задачу) |
| 0x84 | MEM_CYCLES | R | тактов фазы памяти (CS_RD_DATA/CS_RD_WEIGHTS/CS_FETCH_DESC) |
| 0x88 | LOAD_CYCLES | R | тактов загрузки ядра (CS_LOAD, 2-стадийный конвейер) |
| 0x8C | COMPUTE_CYCLES | R | тактов вычисления (CS_RUN/CS_WAIT/CS_ACCUM_WAIT) |
| 0x90 | AR_CNT | R | AXI4 read-транзакций (AR handshakes) |
| 0x94 | BEAT_CNT | R | принятых R-битов (64-бит слов) |
| 0x98 | AR_STALL | R | тактов, когда AR держится, ARREADY=0 (бэкпрешер интерконнекта) |
| 0x9C | R_WAIT | R | тактов в RST_ACT: биты ещё ждутся, бит не принят, AR-ожидания нет (латентность памяти/меж-burst-дыры; аналог STARVE) |
| 0xA0 | WR_CNT | R | AXI4 write-транзакций (B handshakes) |
| 0xA4 | JOB_CNT | R | запущенных задач (легаси GO + планировщик) |
| 0xA8 | FIFO_FULL_EV | R | тактов `fifo_full`. НЕ ноль по дизайну: при `n_in=NUM_MAC` занятость FIFO достигает ровно DEPTH=2·NUM_MAC на ~2–4 такта/проход (пуши data+weights завершаются раньше pops; AR-гейт `!fifo_full` в RST_ACT задерживает следующий burst) → ожидаемый базовый уровень ≈2–4/проход. Рост выше базы = деградация/баг |
| 0xAC | SNAP | W | любое значение — атомарно защёлкнуть все счётчики в тени (снимок консистентен) |
| 0xB0..0xE0 | S-тени | R | 13 слов: CYCLES_LO_S, CYCLES_HI_S, BUSY_S, MEM_S, LOAD_S, COMPUTE_S, AR_S, BEAT_S, AR_STALL_S, R_WAIT_S, WR_S, JOB_S, FIFO_FULL_S |

Счётчики событий — 32-бит, переполнение по модулю 2^32. `CLEAR` обнуляет ТОЛЬКО 11 событийных
счётчиков: `CYCLES` (free-running) и SNAP-тени он НЕ трогает (RTL: `cnt_cycles` инкрементируется
безусловно, `snap_*` пишутся только импульсом SNAP). `FREEZE` не останавливает CYCLES.
Host-`obs_clear()` делает RMW и сохраняет FREEZE (RTL-запись 0x6C обновляет ОБА бита —
прямая запись 0x1 молча снимала бы заморозку; tdot_axi4.sv:328-331).

## Правила съёма показаний
- **Тени**: писать SNAP (`obs_snap()`) непосредственно перед чтением теней; тени не обновляются
  ядром сами и не сбрасываются CLEAR — чтение без свежего SNAP даёт предыдущий снимок.
- **Проценты фаз** считать от ΔCYCLES за окно наблюдения (не от абсолютного CYCLES:
  тот идёт с ресета FPGA и не сбрасывается — иначе проценты схлопываются к 0 при аптайме).
- **AR_STALL vs R_WAIT**: AR_STALL — бэкпрешер (AR держится, ARREADY=0); R_WAIT — латентность
  памяти/меж-burst-дыры (биты ждутся, AR не в станции). Это разные величины, не подменять.
- **Sched-надбавки** (планировщик): каждая задача даёт FETCH +1 AR и +4 BEAT (32-Б дескриптор,
  входит в MEM-фазу) и completion +2 WR (16-Б завершение, CMP1/CMP2). Легаси-GO задача при
  n=NUM_MAC, BURST_RD_LEN≥n: AR=2, BEAT=2·n, WR=1, JOB=1.
- **BEAT** = 64-битные слова ядра (M_AXI_DATA_WIDTH=64) — в байты ×8. Это трафик ЯДРА из DDR3,
  а не host-DMA через XDMA.

## Host-API (`pytorch_layer/xdma_driver.py`, TdotCore)
- `read_build_id()` — BUILD_ID битстрима;
- `read_caps()` — dict {regmap_version, sched, log2_burst, adders, num_mac};
- `obs_clear()`, `obs_freeze(on)` — управление;
- `obs_snap()` → затем `obs_read_shadow()` — атомарный консистентный снимок;
- `obs_read()` — последовательное чтение всех счётчиков.

## Побочный фикс: 4KB-кламп read-burst (AXI4 A4.3.1)
Вместе с OBS перенесён из ветки TMUL: длину `AR`-burst теперь клампит до границы 4KB
(`ar_addr_w/bnd_words_w/ar_len_w`), закрывая латентный дефект при ×8-выровненном, но не
4KB-выровненном адресе. Верификация модели: `scripts/check_burst_4kb.py`.