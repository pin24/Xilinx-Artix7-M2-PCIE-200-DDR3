# Наблюдаемость TDOT: счётчики, SNAP, BUILD_ID/CAPS

Task 35. За образец взята система наблюдаемости openTPU
(github.com/FeSens/openTPU, docs/observability.md, Apache-2.0) — в объёме,
который применим к нашей архитектуре: free-running счётчик тактов,
событийные счётчики, атомарный снимок (SNAP) и самоидентификация
битстрима (BUILD_ID/CAPS). Плюс их главный урок: «`DRAM_WAIT` около нуля
не значит, что память не тормозит — нужен STARVE-счётчик потребителя».

## Зачем

До сих пор вопросы «ядро упирается в память или в арифметику?», «сколько
AR-транзакций на задачу?», «что даст увеличение burst?» решались оценкой.
Счётчики переводят их в измерения на реальном железе за один прогон:

- `MEM_CYCLES` против `COMPUTE_CYCLES` — доля памяти и арифметики в цикле
  задачи. Если `MEM >> COMPUTE` — оптимизировать путь памяти (BURST,
  планирование); если наоборот — арифметику/конвейер.
- `AR_CNT` против `BEAT_CNT` — средний burst (`BEAT/AR`): насколько
  эффективно бьются чтения. До Task 35 дефолт был `BURST_RD_LEN=16`,
  теперь 32 (как в main после P3b), но только на длинных векторах
  средний burst достигает 32 слов.
- `R_WAIT` — такты, когда мы ждём данные, но это не бэкпрешер AR и не
  приём бита: латентность DDR3 и меж-burst-дыры. Это наш аналог
  openTPU-шного `MXU_STARVE`.
- `AR_STALL` — бэкпрешер интерконнекта (SmartConnect/DataMover-шаринг).
- `FIFO_FULL_EV` — такты, когда FIFO полон. ВАЖНО: при полном проходе
  (n_in >= NUM_MAC) в конце weights-burst FIFO ЛЕГАЛЬНО бывает ровно
  полон ~2-4 такта на проход (push последнего слова → rd_done → первый
  pop) — это НЕ деградация, данные не теряются (пуши ≤ DEPTH). Ожидаемая
  базовая линия ≈ 2-4 × число проходов; тревога — только аномальный рост.

## Регистры (слова 25..54 карты tdot_axi4, байты 0x64..0xD8)

| Оффсет | Имя | R/W | Смысл |
|---|---|---|---|
| 0x64 | OBS_CTRL | W/R | бит0 CLEAR (импульс: обнулить СОБЫТИЙНЫЕ счётчики — не CYCLES, не тени; семантика openTPU), бит1 FREEZE (уровень: пауза событийного счёта; CYCLES не замирает). Запись обновляет оба бита — хостовый obs_clear() делает RMW и сохраняет FREEZE |
| 0x68 | BUILD_ID | RO | первые 8 hex git-коммита битстрима (0 = сборка вне git) |
| 0x6C | CAPS | RO | [7:0] NUM_MAC, [11:8] ADDERS (сатурация 15), [15:12] log2(BURST_RD_LEN), [16] планировщик, [31:24] версия REGMAP (=1) |
| 0x70/0x74 | CYCLES_LO/HI | RO | 64-бит free-running такты с ресета |
| 0x78 | BUSY_CYCLES | RO | тактов busy_q=1 (задача исполняется) |
| 0x7C | MEM_CYCLES | RO | тактов фаз CS_RD_DATA/CS_RD_WEIGHTS/CS_FETCH_DESC |
| 0x80 | LOAD_CYCLES | RO | тактов CS_LOAD (2-стадийная загрузка ядра) |
| 0x84 | COMPUTE_CYCLES | RO | тактов CS_RUN/CS_WAIT/CS_ACCUM_WAIT |
| 0x88 | AR_CNT | RO | AXI4 read-транзакций (AR handshakes) |
| 0x8C | BEAT_CNT | RO | принятых R-битов (64-бит слов) |
| 0x90 | AR_STALL | RO | тактов ARVALID && !ARREADY |
| 0x94 | R_WAIT | RO | тактов «данные ожидаются, бита нет, AR-ожидания нет» |
| 0x98 | WR_CNT | RO | AXI4 write-транзакций (B handshakes) |
| 0x9C | JOB_CNT | RO | запущенных задач (GO + планировщик) |
| 0xA0 | FIFO_FULL_EV | RO | тактов fifo_full; базовая линия ≈ 2-4 × проходы при n_in ≥ NUM_MAC, тревога = аномальный рост |
| 0xA4 | SNAP | W | любое значение: атомарно защёлкнуть все счётчики в тени; читается 0 (у openTPU читается число снимков — упрощение, на тени не влияет) |
| 0xA8..0xD8 | тени ×13 | RO | CYCLES_LO_S, CYCLES_HI_S, BUSY_S, MEM_S, LOAD_S, COMPUTE_S, AR_S, BEAT_S, AR_STALL_S, R_WAIT_S, WR_S, JOB_S, FIFO_FULL_S |

Все 32-бит счётчики переполняются по модулю 2^32 (как у openTPU).
CLEAR обнуляет только событийные счётчики — CYCLES и тени НЕ трогаются
(бит-в-бит семантика openTPU: их CLEAR тоже не трогает UPTIME и тени).
Счётчики считаются в такт события (без конвейерного сдвига — у нас
события одноклатные, в отличие от openTPU, где сигнал шёл через регистр).

## Кламп 4KB (попутный фикс, Task 35)

AXI4 запрещает burst'у пересекать 4KB-границу (spec A4.3.1). Старый FSM
(и в нашей ветке, и в main 9f57084 после P3b) длину burst не клампил:
модель `scripts/check_burst_4kb.py` на матрице 512 ×8-смещений × 73
длины показала ~1.5% burst'ов с нарушением — и при BURST_RD_LEN=16, и
при 32. Теперь `ar_len` клампится до границы: `min(len_full, bnd_words-1)`.
На кейсах, где старый код был корректен, разбиение бит-в-бит совпадает
(32829/32829 при burst=16), потерь битов нет.

## Хост (pytorch_layer/xdma_driver.py)

Аддитивные методы `TdotCore`: `read_build_id()`, `read_caps()`,
`obs_clear()`, `obs_freeze(on)`, `obs_snap()`, `obs_read()`,
`obs_read_shadow()`. Существующее поведение не меняется.

## Как снимать профиль (рецепт)

```python
core = TdotCore(dev, num_mac=32)
print(hex(core.read_build_id()), core.read_caps())
core.obs_clear()
# ... N прогонов dot()/планировщика ...
core.obs_snap()
c = core.obs_read_shadow()
work = c["mem"] + c["load"] + c["compute"]   # фазы задачи (BUSY не включает fetch дескриптора)
print("memory share:", c["mem"] / work,
      "load share:", c["load"] / work,
      "compute share:", c["compute"] / work,
      "avg burst:", c["beat"] / max(1, c["ar"]),
      "r_wait share:", c["r_wait"] / work)
```

Интерпретация — по openTPU-принципу: оптимизируй то, что измерил.
Первый замер на стенде определяет, окупается ли overlap CS_LOAD↔compute
(следующий кандидат из списка заимствований openTPU).
