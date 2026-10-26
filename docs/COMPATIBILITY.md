# COMPATIBILITY — матрица совместимости Драйвер ↔ Хост ↔ FPGA (FLAT)

Актуально 2026-10-26. Рабочая линия — **FLAT** (без DFX/ICAP/partial). Конфиг
NUM_MAC=32, ADDERS=8. Data-путь синхронный (без async-конвертера).
Первоисточники: `docs/guide/`, `pytorch_layer/xdma_driver.py`, `pytorch_layer/test_dma_win.py`.

> Адресная база (FLAT): BAR0 AXI-Lite `0x40000000…`; DDR3 `0x80000000` — **DMA-only**.
> Периферия: DataMover MM2S `0x40010000`, S2MM `0x40018000`, GPIO `0x40020000`,
> **TDOT `0x40023000`**, XADC `0x46000000`. DFX/ICAP/SPI-регистров на FLAT нет.

## 1. Хост-бэкенды (Windows)

| Бэкенд | Программная основа | Узел | Доступ |
|---|---|---|---|
| `XdmaWinDma` (рекомендован) | `pytorch_layer/test_dma_win.py` | `\\.\XDMA0dma\control, h2c_0, c2h_0` | MMIO + **DMA (h2c/c2h)** |
| `XdmaWinUpstream` | апстрим-путь | `\\.\XDMA0/XDMA0dma` | MMIO + DMA при под-нодах |
| `XdmaLinux` | kernel XDMA | `/dev/xdma0_control`, `_h2c_0`, `_c2h_0` | MMIO + DMA |

Основной путь в проекте — `XdmaWinDma` (база `\\.\XDMA0dma`) и `XdmaLinux`.

## 2. Матрица возможностей

| Возможность | XdmaWinDma (Windows) | XdmaLinux |
|---|---|---|
| Регистры (AXI-Lite, TDOT/GPIO/XADC) | ✅ `read/write(addr)`, offset = addr − 0x40000000 | ✅ `/dev/xdma0_control` |
| DMA запись host→DDR (h2c) | ✅ `write_dma(ddr_off, ...)` | ✅ `/dev/xdma0_h2c_0` |
| DMA чтение DDR→host (c2h) | ✅ `read_dma(ddr_off, ...)` | ✅ `/dev/xdma0_c2h_0` |
| device_prog / scheduler / GEMM | ✅ (через `DeviceProgRunner`) | ✅ |
| DFX/ICAP/SPI-hotflash | ❌ нет на FLAT | ❌ нет на FLAT |
| XADC-телеметрия | ✅ `xadc_temp` | ✅ |

## 3. Пропускная способность / лимиты

- h2c ≈ 72 MB/s, c2h ≈ 66 MB/s, round-trip ≈ 36 MB/s (устойчиво при ≥1 МБ).
- `MAX_N_TOTAL = 32×NUM_MAC = 1024` (ширина одного dot / скрытый слой ≤1024).
- Порог DMA-чанка драйвера ≤1 MiB.

## 4. Известные примечания

- На FLAT **второй BAR (DDR3-окно) через MMIO не маппится** — хост обращается
  к DDR3 только через DMA-каналы h2c/c2h. Регистры — через AXI-Lite (зная BASE).
- `XdmaWinUpstream.write_dma/read_dma` не прибавляют `DDR3_BASE` к offset.
- После прошивки, если устройство `XDMA DMA Subsystem` в статусе Unknown —
  перезагрузить хост (ресканирование PCIe/драйвер), узлы `\\.\XDMA0dma\control` и др.
  снова появятся.