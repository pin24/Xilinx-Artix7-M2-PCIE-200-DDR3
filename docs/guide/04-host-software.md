# 04. Хост-софт: драйвер, DMA, скрипты, лимиты

## Драйвер и адресование
- **Windows** backend: `pytorch_layer/test_dma_win.py::{XdmaWinDma}` база `\\.\XDMA0dma`,
  узлы `\control` (AXI-Lite) / `\h2c_0` (запись) / `\c2h_0` (чтение).
  - `read(addr)`/`write(addr)` — AXI-Lite (регистры), offset = addr - 0x40000000.
  - `write_dma(ddr_off, data)` — h2c: host→DDR, offset внутри окна DDR3 (без +0x80000000).
  - `read_dma(ddr_off, len)` — c2h: DDR→host.
- **Linux** backend: `xdma_driver.py::XdmaLinux` — `/dev/xdma0_control`, `_h2c_0`, `_c2h_0`.
- DMA-чанки ≤1 МиБ.

## Ключевые модули host-софта
- `pytorch_layer/xdma_driver.py` — `DeviceProgRunner`, `CompletionMailbox`, `TdotCore`,
  `XdmaDevice{read/write_dma}`; адресные константы REG_BASE=0x40023000, DDR3_BASE=0x80000000.
- `pytorch_layer/test_dma_win.py` — Windows-DMA backend (`XdmaWinDma`, `XdmaWinUpstream`).

## Скрипты (`scripts/`)
| Скрипт | Назначение |
|---|---|
| `probe_core.py` | живость/рег-проверка: MAGIC + CORE_PARAMS |
| `obs_smi.py` | дашборд наблюдаемости (nvidia-smi-стиль). `--once`, `--clear`, `--num-mac` (авто из CORE_PARAMS) |
| `test_dprog_single_dot.py` | один 4-dot через device_prog (3.5) |
| `test_dprog_batch_board.py` | batched GEMM (n_batch) |
| `debug_dprog_chain.py` | многоюнитная цепочка src=prev |
| `train_dprog_batch_mlp.py` | обучение MLP через batched device_prog (данные датасета по умолч.) |
| `clean`-запасные | monitor температуры, flash, проверки |
| `bench_fpga_vs_cpu.py` | сравнение FPGA vs CPU + `--mem` + `--hidden` |
| `test_mem_sweep.py` | свип по mem/hidden/batch → таблица |

## Базовые команды
```
python scripts/probe_core.py                       # живость
python scripts/obs_smi.py --once --interval 0.5    # наблюдаемость
python scripts/test_dprog_single_dot.py            # device_prog 3.5
python scripts/train_dprog_batch_mlp.py --epochs 8 --batch 32 --samples 1000 --lr 0.1 --seed 0
python scripts/bench_fpga_vs_cpu.py --hidden 64 --mem 2M --epochs 3 --batch 32 --samples 256 --lr 0.1 --wide 1024
```

## Ограничения/лимиты (host-сторона)
- **Пропускная способность DMA-каналов**: устойчиво ~70 MB/s (запись ≈72, чтение ≈66).
- **NUM_MAC/ADDERS** — читайте из CORE_PARAMS (0x64), не из OBS-CAPS (мог быть недоступен).
  `DeviceProgRunner(num_mac=...)` должен совпадать с платой (32 для 32/8).
- **Длинный dot** ≤ MAX_N_TOTAL (1024 на 32/8); `--hidden` ≤1024, но `B×H×8 ≤ mem`,
  `--mem` ≤ 85% DDR, суффиксы K/M (128K/1M/2M).
- **Device_prog задача**: n_in в [63:48] W2; адреса в окне DDR/BRAM; n_batch ≤255.

## Диагностика
- Плата не открывается (`cannot open \\.\XDMA0dma\control: WinError 3`) — устройство в
  Диспетчере имеет статус Unknown → перезагрузи хост (или disable/enable устройства от админа).
- `CORE_PARAMS недоступны (timeout)` в `obs_smi` — плата заклинила (нужен power-cycle), не баг скрипта.
- Ворожение малых передач работает, крупных — нет: признак data-пути (см. 05); на текущей
  синхронной прошивке 32/8 этого нет.