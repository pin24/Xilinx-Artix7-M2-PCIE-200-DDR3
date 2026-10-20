# АУДИТ ПРОЕКТА И СРАВНЕНИЕ С УДАЛЁННЫМ РЕПОЗИТОРИЕМ — 2026-10-20

**Корень:** `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3`
**Состояние git на момент аудита:** `HEAD == origin/main == cc6ce3b`
**Режим:** только чтение. Vivado, сборка драйвера и железо не запускались.

## 0. Фактическое состояние репозитория

```
cc6ce3b docs: record session - flat full-audit report …
022ff7a Merge remote-tracking branch 'origin/main'
efac977 chore: take remote canonical stress_platform.py rebuild …
7d6e74d fix(local): audit 2026-10-20 fixes + sync with remote
7f5e2b0 docs: README rewritten for FLAT reality …   (remote)
7748803 fix(obs): truthful OBS readings …            (remote)
6ec9f5b fix(host): nn_audio_infer_fpga + stress_platform (remote)
ff7a18b perf(driver): XDMA_DESC_MAX_BYTES 4096->8192
```

`git diff HEAD origin/main` — **пусто**. Локальные правки аудита 2026-10-20 (гейт тайминга, readback generic, FIX-DESC 2048, `CS_ABORT_WAIT`, OBS RMW, dt-защита) закоммичены в `7d6e74d` и влиты в main; remote-коммиты `6ec9f5b/7748803/7f5e2b0` влиты через `022ff7a`.

Незакоммиченным остаётся только старый WIP (10 файлов): `Makefile`, `_full32.bat`, `data/audio_model_fpga.npz(.json)`, `data/nn_audio_train_fpga.py`, `dfx_runtime.txt`, `rtl/block/*` (3 файла), `rtl/integration/sim/tb_tdot_axi4_expected.hex`.

**Вывод:** сравнивать «локальное с remote» по diff больше нечего — код один. Сравнение имеет смысл только в двух плоскостях: (а) качество самого merge, (б) незакоммиченный остаток.

---

## 1. Качество merge: 3 remote-фикса потеряны

| Фикс remote | Где был | Состояние в локальном | В origin/main |
|---|---|---|---|
| E-7: шапка `obs_smi` показывает CAPS NUM_MAC и WARN при расхождении с `--num-mac` | `scripts/obs_smi.py` (7748803) | **ПОТЕРЯН**: `:159` печатает `build {args.num_mac} MAC` — флаг как истина, CAPS не сверяется | ЕСТЬ |
| E-7 в дашборде: `WARNING: CAPS NUM_MAC≠--num-mac` | `scripts/monitor_obs.py` (7748803) | **ПОТЕРЯН**: `:83-84` читает CAPS и печатает, но сравнения/предупреждения нет | ЕСТЬ |
| E-8: `obs_clear` через read-back шины (`_reg_r`) | `pytorch_layer/xdma_driver.py` (7748803) | **ЗАМЕНЁН** нашим shadow-вариантом `self._obs_ctrl` (`:728`), функционально эквивалентен | ЕСТЬ (read-back) |

Первые два — регресс merge и единственные места, где origin/main **полнее** локального. Третий — сознательная альтернатива (наша реализация даже проще: не требует чтения регистра), но при будущем изменении RTL (если FREEZE переедет в другой бит) разойдётся с железом молча.

---

## 2. Находки в итоговом (смерженном) коде

Колонки «локально» и «origin» идентичны — код общий; отмечено, где расхождение сохранилось.

### P1

| # | Файл:строка | Суть | Сценарий |
|---|---|---|---|
| 1 | `xdma_driver_win_src_2017/sys/file_io.c:750-757` + `libxdma/dma_engine.c:1560` | poll-таймаут **не** выставляет `txnDone=TRUE` перед Release+Complete (в отличие от `EvtCancelDma:884` и watchdog:530) | задержанный MSI-X/DPC приходит после таймаута → второе завершение уже освобождённой транзакции → 0x10D/0xE6. PLAUSIBLE |

### P2

| # | Файл:строка | Суть |
|---|---|---|
| 2 | `rtl/integration/tdot_axi4.sv:950-953` | `CS_ABORT_WAIT` (наш фикс) ждёт `rstate==RST_IDLE` **без таймаута** → при отсутствии ARREADY вечный `busy_q=1`. Класс дефекта «нет таймаута» остаётся и в остальных состояниях |
| 3 | `pytorch_layer/xdma_driver.py:431` | `XdmaWinUpstream` — класс, которым реально пользуются скрипты — **без** `close()/__del__`: утечка 4 handle + event. Наш `close()` ушёл в неиспользуемый `XdmaWinDriver` |
| 4 | `scripts/obs_smi.py:159`, `scripts/monitor_obs.py:83-84` | потерянные CAPS-warn (см. §1) — шапка может молча врать о NUM_MAC |
| 5 | `scripts/build_flat.tcl:319-323` | readback generic при нераспознанном формате — только WARNING: сборка продолжится с дефолтами топа `#(16,4)` (`xdma_ddr3_core_top.sv:5`) вместо 32/16 |
| 6 | `libxdma/device.c:320-364` | `XDMA_DeviceClose` без остановки движков перед освобождением банков и `MmUnmapIoSpace` → UAF при surprise-remove |
| 7 | `libxdma/device.c:244-248`, `interrupt.c:142/177` | `interruptRegs=NULL` при малом BAR, а проверка — только `ASSERT` (в free build no-op) |
| 8 | `constraints/pblock_flat_tdot.xdc:38` | регион `SLICE_X25Y4:X105Y85` = 6642 slice (≤26 568 LUT), не параметризован под NUM_MAC; для 32/64 тесен |
| 9 | `_flat32.bat` (`JOBS=13`) | при `general.maxThreads 4` (`build_flat.tcl:45`) — до 52 процессов, риск OOM |
| 10 | `rtl/integration/tdot_axi4.sv:1022` | 4-КБ кламп может выдать 8-байтовый beat за границу страницы на невыровненном адресе |
| 11 | `rtl/integration/tdot_axi4.sv:761-763` | `align_q` учитывает и `result_addr` — abort строже, чем требует AXI (достаточно data/weights) |

### P3

- `Makefile:35` — `FLAT := $(FLAT)` самоссылка (no-op). Документированная форма `make FLAT build` работает через `$(filter FLAT,$(MAKECMDGOALS)):64`; форма `make FLAT=1 build` молча уйдёт в DFX-скрипт.
- `xdma_engine.c:951` — мёртвая заглушка `if (descBankLens < XDMA_MAX_DESC_COUNT) { }`.
- `build/XDMA_DMA.inf` = 1.1.34.0 при целевой 1.2.4.0 (`build.cmd:37`).
- IOCTL с `FILE_ANY_ACCESS` без SDDL (`inc/xdma_public.h:63`).
- `docs/ADDRESS_MAP.md:7` описывает DFX как активную сборку (актуальна FLAT, ICAP/SPI/DFX-socket в коде нет).
- tf48: RTL `[47:40]=e` vs `ternary_sw/block/tfloat48.py` (E в младшем байте). Реальный путь не затронут: `fpga_backend._to_bits48` пакует в RTL-конвенции. Ловушка для будущего кода.
- Гигиена: 47,8 МБ в индексе (2×`.bit` ~15 МБ, `.mcs` ~14 МБ, `ternary_sw/reference/*.csv` ~17,5 МБ) — вопреки `*.bit/*.mcs` в `.gitignore` (добавлены до правила). `.gigatool/` (52,5 МБ), `*.bak_*`, `*.npz`, `*.substituted` не покрыты.

### Проверено и в порядке

Синхронное завершение DMA и владение транзакцией (`txnDone`, `UnmarkCancelable`-first); FIX-DESC (2048 дескрипторов покрывают 8 МБ при 4-КБ страницах, переполнений нет, банк ~64 КБ/буфер, ~2 МБ на 8 движков); 4-КБ кламп в штатном пути; FIFO `2*NUM_MAC`; zero-fill слотов (BUG-050); кольцо планировщика mod-256; карта регистров RTL↔драйвер↔`ADDRESS_MAP` — 0 расхождений; Δ-frame и метки AR_STALL/R_WAIT после merge; перенос CYCLES LO/HI; `nn_audio_infer_fpga` компилируется; `stress_platform.py` — канонический remote-вариант (13669 б), локальный restore сохранён в бэкапе.

---

## 3. Приоритеты

**Сразу (регресс merge, 15 минут):**
1. Вернуть CAPS-vs-`--num-mac` WARN в `obs_smi.py` и `monitor_obs.py` (перенести из `origin/main`).
2. Добавить `close()/__del__` в `XdmaWinUpstream` (реально используемый класс).

**Ближайшее (драйвер, требует пересборки и теста):**
3. В poll-таймауте выставлять `txnDone=TRUE` до Release+Complete — закрывает окно двойного завершения.
4. Остановка движков в `XDMA_DeviceClose` до `MmUnmapIoSpace`.

**RTL (требует симуляции):**
5. Watchdog/таймаут в `CS_ABORT_WAIT` и в состояниях ожидания AXI.
6. Убрать `result_addr` из условия `align_q`.

**Сборка/гигиена:**
7. `JOBS` в `_flat32.bat` привести к 4; pblock параметризовать или сделать условным по NUM_MAC.
8. `git rm --cached` для битстримов/CSV, дополнить `.gitignore`.

---

## 4. Приложения

- `C:\Temp\gigatool\audit-vs-remote\build.md` — сборка и гигиена (18 находок)
- `C:\Temp\gigatool\audit-vs-remote\rtl.md` — RTL
- `C:\Temp\gigatool\audit-vs-remote\driver.md` — драйвер
- `C:\Temp\gigatool\audit-vs-remote\host.md` — host-софт

Предыдущий аудит: `docs/AUDIT_FULL_2026-10-20.md`.
