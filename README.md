# TFloat48 Ternary FP Accelerator — XDMA + DDR3 (Artix-7 XC7A200T, M.2 PCIe)

Проект троичного FP-ускорителя **TFloat48** на плате M.2 (Xilinx Artix-7 XC7A200T),
доступного хосту через PCIe (XDMA) с памятью DDR3, с интеграцией в PyTorch.

> **Актуальная линия (main) — FLAT**: статичный дизайн без partial reconfiguration.
> DFX-линия (Dynamic Function eXchange, hot-swap RP через ICAP) развивается в ветке
> [`XDMA_DDR3_TMUL`](https://github.com/pin24/Xilinx-Artix7-M2-PCIE-200-DDR3/tree/XDMA_DDR3_TMUL)
> — см. исторический раздел ниже и `xdma_ddr3_dfx_README.md`.

## Формат TFloat48
- 48 бит = 6 байт, блоки по 4 трита (1 байт).
- Мантисса M = 20 тритов (нормализована [3^18, 3^19)), экспонента E = 4 трита (bias 40).
- Точность мантиссы 3^-18 ≈ 5.2e-9 (~в 22 раза точнее float32).
- Вся арифметика на LUT: DSP = 0, BRAM ≈ 10%.

## Архитектура FLAT (main, прошивки с 2026-10-13)

```
host (Python/Windows, XDMA_DMA.sys v1.2.5)
  └ PCIe Gen2 x4, BAR0 128 МБ @0x40000000
     ├ AXI-Lite (32b @125): GPIO 0x40020000 · DataMover 0x40010000/0x40018000 ·
     │                      TDOT 0x40023000 · XADC 0x46000000
     └ M_AXI (128b) → SmartConnect → MIG DDR3 0x80000000 (256 МБ, ui_clk 200)
                                     └ diag-BRAM 0x10000000 (8 КБ)

xdma_ddr3_core_top (FLAT: NUM_MAC=16, ADDERS=4 в прошивках; DIAG-сниффер включён)
  └ u_tdot = tdot_axi4: FSM 14 состояний + аппаратный планировщик (ring 256×32Б,
     doorbell WPTR/RPTR, IRQ usr_irq_req), BURST_RD_LEN=32, 4KB-кламп read-burst
     (AXI4 A4.3.1), OBS-наблюдаемость 0x6C..0xE0 (SNAP-тени, BUILD_ID/CAPS)
     └ 16×tfmul_raw + 4×tfadd_raw (ping-pong barrel-дерево, lockstep)
```

- **Сборка**: `scripts/build_flat.tcl` (Vivado 2025.2) — NUM_MAC/ADDERS/BUILD_ID через
  fileset-generic; BUILD_ID = `git rev-parse --short=8` (читается хостом из железа);
  FATAL timing gate перед экспортом. Артефакты: `build/artifacts_flat/`.
- **Не входит во FLAT**: ICAP/SPI/hot-flash, DFX Socket, partial-битстримы
  (удалены из BD 2026-10-05; `spi_over_pcie.sv` = non-blocking заглушка).
- **Наблюдаемость**: см. `docs/OBSERVABILITY.md`; быстрый старт:
  ```cmd
  python scripts/obs_smi.py --num-mac 16 --dot 100 --clear --interval 0.3
  python scripts/monitor_obs.py --once --num-mac 16
  ```
  Эталонные числа (legacy-GO, n=NUM_MAC=16): на 1 задачу AR=2, BEAT=32, WR=1, JOB=1.

## Состав репозитория
| Каталог | Содержимое |
|---|---|
| `rtl/block/` | Блочное ядро: `tbyte_add/mul.sv`, `tfmul_raw.sv`, `tfadd_raw.sv`, `tfadd48.sv`, `compute_dot_par_raw.sv` (параллельный dot, NUM_MAC/ADDERS) |
| `rtl/integration/` | `tdot_axi4.sv` (AXI4-мастер + планировщик + OBS), `xadc_temp.sv`/`xadc_prim.sv` (XADC-телеметрия), `xdma_ddr3_core_top.sv` (топ), `spi_over_pcie.sv` (заглушка) |
| `rtl/diag/` | `diag_axi_sniffer.sv` — счётчики AW/W/B/AR/R, RRESP/BRESP≠OKAY, last-addr (host-доступ планируется, DIAG_PLAN) |
| `constraints/` | `xdma_ddr3_pins.xdc`, `xdma_ddr3_early.xdc`, `pblock_flat_tdot.xdc` (регион ядра), `timing_exceptions_post.tcl` |
| `scripts/` | `build_flat.tcl` — **главная сборка FLAT**; `xdma_ddr3_bd.tcl`/`post_bd_flat.tcl` — BD; `obs_smi.py`, `monitor_obs.py` — OBS-дашборды; `bench_dma_serial/dual.py` — бенчмарки DMA; `nn_fpga_mlp.py`, `nn_fpga_train.py` — NN-эксперименты; `check_burst_4kb.py` — модель 4KB-клампа |
| `data/` | Задача «число(частота)→звук»: `gen.py`, `nn_audio_*.py`, обученные модели `audio_model_*.npz` |
| `_flat16.bat`, `_flat32.bat`, `_flash32.bat` и `_*.tcl` | Лаунчеры стенда (Windows): сборка/прошивка/диагностика |
| `third_party/m2-artix7-accelerator-card/` | Встроенные HDL из [rigoorozco/m2-artix7-accelerator-card](https://github.com/rigoorozco/m2-artix7-accelerator-card) (up_axi.v, datamover_ctrl.v) |
| `pytorch_layer/` | Хост-софт: `xdma_driver.py` (TdotCore + TdotScheduler + OBS), `fpga_backend.py`, `test_dma_win.py`, `stress_platform.py`, `monitor_temp.py` |
| `ternary_sw/` | Python-эталон арифметики TFloat48 (arith48/block) и тесты |
| `driver/dma/` + `xdma_driver_win_src_2017/` | **Windows KMD `XDMA_DMA.sys` v1.2.5** (KMDF, DMA→DDR3) + libxdma-стек |
| `driver/` (корень) | Legacy MMIO-драйвер XDMA.sys 1.1.4 (без DMA!) + журналы аудита |
| `docs/` | `ADDRESS_MAP.md`, `OBSERVABILITY.md`, `ERROR_HISTORY.md` (BUG-001…059), `CHANGE_LOG_*.md` |

## Карта адресов (FLAT-BD, PCIe BAR0 128 МБ)

Полная карта: [`docs/ADDRESS_MAP.md`](docs/ADDRESS_MAP.md); OBS-регистры: [`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md).

| Модуль | Адрес | Размер | Примечание |
|---|---|---|---|
| DataMover MM2S | 0x4001_0000 | 4K | cmd/статусы (потоковая петля тестов BD) |
| DataMover S2MM | 0x4001_8000 | 4K | cmd/статусы |
| AXI GPIO | 0x4002_0000 | 4K | ch1 LED (out); ch2 = MIG status: bit0 mmcm_locked, bit1 init_calib_complete (`check_mig.py`) |
| **TDOT registers** | **0x4002_3000** | 4K | Регистры ускорителя: ядро 0x00..0x30, SCHED 0x40..0x60, CORE_PARAMS 0x64, MAGIC 0x68 ('TDOT'), **OBS 0x6C..0xE0** |
| XADC | 0x4600_0000 | 4K | 0x00 temp, 0x04 vccint, 0x08 valid, 0x0C MAGIC 'XADC'; через примитив `xadc_prim` |
| diag-BRAM | 0x1000_0000 | 8K | AXI4 BRAM-обход (DIAG-план) — всем 4 мастерам |
| DDR3 (DMA XDMA) | 0x8000_0000 | 256 MB | Доступ хоста через H2C/C2H каналы (BAR-моста к DDR3 нет) |
| DDR3 (M_AXI_TDOT) | 0x8000_0000 | 256 MB | Доступ ядра tdot (мастер 64b → MIG 128b через SmartConnect) |

Регионы DDR3 (смещения): dot data 0x0 / weights 0x1000 / result 0x2000; планировщик
0x100000 (дескрипторы, 8К) / 0x110000 (завершения, 4К); слоты data/weights 0x200000/0x600000;
selftest 0x1000000. Данные — TFloat48 в младших 48 битах 64-битного слова.

> ICAP (0x40024000), SPI (0x40025000) и DFX Socket (0x40022000) на FLAT-прошивке
> **отсутствуют** — это адреса DFX-линии.

## Драйвер Windows и производительность

- **`driver/dma/build.cmd` → `XDMA_DMA.sys` v1.2.5** — актуальный DMA-драйвер (FIX-DESC банк 2049 + FIX-DESC2 мультипакет BUG-060)
  (`\\.\XDMA0dma\{control,user,h2c_0..1,c2h_0..1}`), узлы: MMIO-бары + DMA.
  SG-движок: `XDMA_DESC_MAX_BYTES=8192`, `XDMA_MAX_TRANSFER_SIZE=8MiB`.
- `driver/build.cmd` → legacy `XDMA.sys` 1.1.4 (MMIO-only, без DMA) — не использовать
  для DMA; HW-ID совпадает, не держите оба пакета в driver store.
- **Полоса (Gen2 x4)**: 275/262 MB/s при дескрипторах 512Б (over-fetch дескрипторов)
  → **932/699 MB/s** (write/read) после 512→4096 (v1.2.3) → 8192 (v1.2.4); WHEA/ROF нет. v1.2.5: банк дескрипторов 2049 (худшая фрагментация 4К) + packet-aware completion (BUG-060).
  Потолок — не линк (2 ГБ/s) и не DDR3 (~1.6 ГБ/s), а был в дескрипторах; `pcieMRRS` read-only.
- Dual-channel (h2c_0/1+c2h_0/1 параллельно): работает, выигрыша нет — общие
  PCIe/DDR; для параллелизма нужны per-channel очереди (очереди per-engine уже Sequential).
- Журнал BSOD-саги (0x124/ROF, 0x10D, таймауты): `docs/ERROR_HISTORY.md`,
  `docs/CHANGE_LOG_2026-10-20.md`, `xdma_driver_win_src_2017/DRIVER_DEVLOG.md`.

## NN-эксперимент «число→звук» (валидация стека, не производительность)
- MLP 2→H→1, forward на FPGA через `FpgaBackend.run_dot`; H>16 — chunked matmul (64=4×16).
- Обучение на FPGA = ELM/Random Features (`data/nn_audio_train_fpga.py`), CPU = SGD.
- Результаты: loss h16 0.0022 → h64 0.00027 (CPU-верификация); FPGA 8.08 мс/сэмпл
  против CPU 0.1 мкс (PCIe-оверхед на каждый dot) — CPU быстрее ~80000×.

## Ресурсы (XC7A200T, Vivado 2025.2)
- FLAT 16/4 (прошивка): MET, WNS +0.27…+0.55 по сборкам; 32/16: MET, WNS +0.06.
- Ядро NUM_MAC=32: ~55k LUT (45%); полный дизайн ~85k LUT (63.8%) при 32/16. 0 DSP.

## Верификация
```bash
python scripts/check_burst_4kb.py          # модель 4KB-клампа == RTL (PASS)
python -m pytest ternary_sw/tests/ -q      # 10/10
python ternary_sw/verify_cpu.py            # эталон формата (add rel~2e-3 — свойство формата)
python pytorch_layer/verify_fpga_backend.py # протокол host<->mock FPGA
python rtl/integration/verify_tdot_axi4.py 32   # xsim, RTL == raw-модель
python pytorch_layer/stress_platform.py --mock  # стенд без железа
```

## Сборка (FLAT)

```cmd
REM Быстрый старт: 16 MAC / 4 ADDERS (прошивочная конфигурация):
_flat16.bat

REM или напрямую (Vivado 2025.2):
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch ^
  -source scripts\build_flat.tcl -tclargs NUM_MAC=16 ADDERS=4

REM 32 MAC / 16 ADDERS:
_flat32.bat
```

`build_flat.tcl` выполняет: зачистка+создание проекта (`C:\build_flat` или `build/flat_proj`,
env `PROJ_DIR`) → BD (`scripts/xdma_ddr3_bd.tcl` + `post_bd_flat.tcl`: канонические адреса,
tdot_irq→usr_irq_req) → RTL ядра (11 файлов) → BUILD_ID из git → констрейны (pins/early/pblock
LATE) → synth/impl → **FATAL timing gate** (нарушение = exit 1 до экспорта) →
`build/artifacts_flat/{.bit,.bin,.mcs}` + utilization/timing отчёты.

> ⚠️ **Makefile устарел**: `make build` зовёт DFX-сборку (`build_dfx.tcl`), `make artifacts`
> требует `C:\build_dfx` (его нет на FLAT), flat-таргета нет. Пользуйтесь `_flat*.bat` /
> `build_flat.tcl` напрямую (синхронизация Makefile — открытая задача).

Прошивка SPI-флеша (W25Q128JV):

```cmd
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch ^
  -source scripts\flash_program.tcl -tclargs build\artifacts_flat\xdma_ddr3_core_top.bin
```

## R-01: пересборка и прошивка платы (BAR0 = 128 МБ)

> На плате обнаружен устаревший битстрим (измерено BAR0 = 1 МБ вместо 128 МБ),
> из-за чего не работают регистры периферии. Полная пошаговая инструкция:
> [`driver/R-01_BUILD_AND_FLASH.md`](driver/R-01_BUILD_AND_FLASH.md)
> (HTML-версия: [`driver/R-01-build-and-flash.html`](driver/R-01-build-and-flash.html)).
>
> ⚠️ Работайте в каталоге `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3`. В `C:\A7_M2\EXAMPLES\Xilinx-Artix7-M2-PCIE-200-DDR3` лежит устаревший клон того же репозитория с другим (include-based) `Makefile` — `make build` там падает с `No such file or directory`.

Проверка после полного power-cycle: `driver\build\test_xdma.exe gpio` → строка
`BAR map: BAR0=131072 KB, BAR2=64 KB`.

### Документация аудита и журналы (каталог `driver/`)
- [`driver/xdma-bsod-report.html`](driver/xdma-bsod-report.html) — отчёт по BSOD (0x7E / 0x124): причины, адреса, исправления
- [`driver/ERROR-FIX-LOG.md`](driver/ERROR-FIX-LOG.md) · [`driver/error-fix-log.csv`](driver/error-fix-log.csv) — журнал ошибок и исправлений (E-01…E-10)
- [`driver/AUDIT-REPORT.md`](driver/AUDIT-REPORT.md) — повторный аудит кода (до/после)
- [`driver/RISK_REGISTER.md`](driver/RISK_REGISTER.md) — реестр рисков (R-01 — пересборка/прошивка)
- [`driver/PROJECT_MAP.md`](driver/PROJECT_MAP.md) — карта проекта
- [`driver/ENVIRONMENT_MANIFEST.md`](driver/ENVIRONMENT_MANIFEST.md) — версии инструментов
- [`driver/HANDOFF.md`](driver/HANDOFF.md) · [`driver/ROLLBACK.md`](driver/ROLLBACK.md) — передача и откат
- [`driver/VERIFY.cmd`](driver/VERIFY.cmd) — проверка драйвера и Python одной командой

## Историческая DFX-линия (продолжается в ветке `XDMA_DDR3_TMUL`)

Dynamic Function eXchange — partial reconfiguration через PCIe: static region (XDMA, MIG,
`icap_ctrl`, DFX Socket) + RP (`dfx_partition` BDC). Перезагрузка RP без JTAG:
shutdown/decouple через DFX Socket (0x40022000) → partial-битстрим в `icap_ctrl`
(0x40024000) → очистка сокета. Всё одной командой:
`python pytorch_layer/dfx_swap.py build/artifacts_dfx/*partial*.bit`.
Подробности: [`xdma_ddr3_dfx_README.md`](xdma_ddr3_dfx_README.md), сборка `scripts/build_dfx.tcl`
(в main присутствует, но производственной не является). Hot-flash полного образа через
ICAP не применялся (проверено 12.09.2026) — ICAP только для RP-образов.

## Открытые задачи (по аудитам 2026-10-20; обновлено после аудита 39 + фиксов BUG-060..063)
- [x] FLAT-сборка + BUILD_ID/CAPS + OBS-наблюдаемость + 4KB-кламп (прошивка MET, стенд)
- [x] Драйвер v1.2.5: BSOD-сага закрыта, полоса 275→932/699 MB/s; банк дескрипторов 2049
      под худшую фрагментацию (FIX-DESC); мультипакетный hang D-2 закрыт (FIX-DESC2,
      BUG-060) — стенд-регресс >8MiB IRP перед продом
- [x] `nn_audio_infer_fpga.py` + `stress_platform.py` восстановлены (6ec9f5b)
- [x] FATAL-гейт: setup+hold+pulse-width (C-1 половина); generic read-back; pblock только
      при NUM_MAC=16 (BUG-061); SKIP_SYNTH не стирает артефакты (BUG-062); TB TEST 5 —
      align-abort регресс (BUG-063)
- [ ] Сим/стенд: прогнать TEST 5 в xsim (align-abort регресс CS_ABORT_WAIT); разовый
      стенд-регресс драйвера v1.2.5 одиночным IRP >8MiB
- [ ] Сборка: первый реальный прогон 32/16 с report_utilization -pblocks (pblock для 32/16
      теперь пропущен — подтвердить утилизацию/WNS); WPWS печатает N/A ровно при нарушении
      (парсинг VIOLATED-строк, 39-c F4.4); check_timing-парсер берёт номер пункта вместо
      счётчика и ищет несуществующую секцию (F4.5); is_fatal/пустой-отчёт не подключены
      (C-1 вторая половина); `ui_clk` вне async-групп (`-include_generated_clocks`, C-3);
      `_flat64` нежизнеспособен (C-4); Makefile/flash → artifacts_flat (C-6/C-7); BUILD_ID
      dirty-маркировка (C-8); CAPS ADDERS=15 vs CORE_PARAMS=16 при ADDERS=16 (C-9, live)
- [ ] Драйвер: watchdog мёртв (D-3); WaitCompletion-timeout/ErrExit вне txnDone-CAS
      (D-4/D-5); IOCTL GET_VERSION/PERF_STOP (D-7); ReleaseHardware без остановки DMA
      (P1-4 — disable/enable при активном DMA = BSOD-окно); loud-трейсы мертвы в
      release-сборке (WPP off) — продублировать через DbgPrint
- [ ] Host: XdmaWinUpstream без close()/__del__ (утечка хендлов); bw_profile.py — n не
      проверяется, ResetEvent argtypes, дублирует bench_dma_*; E-7: сравнение CAPS vs
      флага --num-mac удалено из obs_smi/monitor_obs; monitor_obs delta без wrap-обработки
- [ ] RTL-резервы: P2-2 (чужие RES0/RES1 при abort-completion), P2-3 (sched_flush
      глотается в задаче), P2-4 (нет таймаутов AXI-мастеров — CS_ABORT_WAIT новый сайт
      вечного busy при зависшей DDR3); TB: 4KB-кламп и OBS при BURST_RD_LEN=32
- [ ] Док-хигиена: COMPATIBILITY.md («DMA не работает» — ложь с v1.2.x) и
      REBUILD_INSTRUCTION.md (эпоха 03.10, v1.1.22, 16/8) переписать; ADDRESS_MAP (M05 vs
      M04, DFX-active); NUL-повреждённые CHANGE_LOG 09-27/09-29 (87%/58% NUL) вычистить;
      CHANGE_LOG_2026-09-* / 10-13 перенести в читаемый вид; ternary_sw/tfloat48.py
      docstring (E-low сериализация) + мёртвые op_*.csv пометить deprecated
- [ ] BD: host-доступ к diag_axi_sniffer (S_AXI_DIAG @0x40007000, B-2); синхронизатор на
      XADC-телеметрию clk50→fab125 (B-3); разовая верификация clock-ассоциаций SmartConnect (B-4)
- [ ] Ветка `2ch-pipeline`: стенд-проверка PACKED6 (p6_a4) и слияние линий драйвера
      v1.1.34 ↔ v1.2.5
- [ ] Подпись драйвера / инсталлятор; UPSTREAM: 4KB-кламп полезен и для main-line ARM/XDMA-стека
