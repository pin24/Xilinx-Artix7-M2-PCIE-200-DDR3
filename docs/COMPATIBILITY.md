# COMPATIBILITY — Матрица совместимости Драйвер ↔ Хост ↔ FPGA

Сводная матрица того, какие хост-бэкенды и драйверы с чем работают в проекте
**TFloat48 at Artix-7 XC7A200T (XDMA + DDR3 + DFX)**. Факты перепроверены
чтением `docs/ADDRESS_MAP.md`, `rtl/integration/xdma_ddr3_core_top.sv`,
`driver/driver.c` и `scripts/xdma_ddr3_dfx_bd.tcl`.

> Адресная база (каноническая): BAR0 AXI-Lite `0x40000000…0x47FFFFFF`;
> DDR3 `0x80000000` — **DMA-only**. AXI-Lite периферия: GPIO `0x40000000`,
> DFX Socket `0x40002000`, TDOT `0x40003000`, ICAP `0x40004000` (кастомный),
> SPI `0x40005000`, XADC `0x46000000`. HWICAP `0x40001000` **удалён**.

---

## 1. Хост-бэкенды

| Бэкенд | Программная основа | Узел/устройство | Доступ |
|---|---|---|---|
| `XdmaWindows` (XdmaWinDriver) | Кастомный `driver\driver.c` (KMDF) | `\\.\XDMA0` (ед. нода) | BAR MMIO через FIX-1/`RtlCopyMemory`; БЕЗ DMA/под-нод |
| `XdmaWinUpstream` | Апстрим-путь Windows | `/dev/xdma0_*` / `\\.\XDMA0` (вариант) | MMIO + DMA-каналы при наличии под-нод |
| `XdmaWindows(xdma_rw)` | `test_xdma.c` / `xdma_rw.exe` | `\\.\XDMA0` | MMIO-чтение/запись BAR0/BAR2 + DMA-каналы (h2c_0/c2h_0) |
| `XdmaLinux` | Ядро Linux XDMA (xdma_control/h2c/c2h) | `/dev/xdma0_control`, `/dev/xdma0_h2c_0`, `/dev/xdma0_c2h_0` | Полный стек: MMIO + DMA |

---

## 2. Матрица возможностей по бэкендам

| Возможность | XdmaWindows (XdmaWinDriver) | XdmaWinUpstream | XdmaWindows (xdma_rw) | XdmaLinux |
|---|---|---|---|---|
| **Регистры (MMIO)** | ✅ `\\.\XDMA0`, FIX-1 роутит в BAR0 | ✅ | ✅ | ✅ `/dev/xdma0_control`, offset = addr − 0x40000000 |
| **DMA (H2C/C2H)** | ❌ не реализован (только MMIO) | ⚠️ зависит от под-нод (DMA есть в апстриме, но локальный driver.c их не создаёт) | ✅ каналы h2c_0/c2h_0 (при наличии) | ✅ `/dev/xdma0_h2c_0` / `/dev/xdma0_c2h_0` |
| **DFX-swap** (горячая замена RP) | ✅ через `icap_ctrl` `0x40004000` + `dfx_swap.py` | ✅ | ✅ | ✅ |
| **SPI-hotflash** (`0x40005000`) | ✅ | ✅ | ✅ | ✅ |
| **XADC** (`0x46000000`, `xadc_prim`) | ✅ реальные `raw_temp`/`raw_vccint` | ✅ | ✅ | ✅ |
| **Требуется от драйвера** | MMIO + `RtlCopyMemory`; DMA **нет** | MMIO + DMA-под-ноды | MMIO + DMA-каналы | Kernel XDMA (control/h2c/c2h) |

---

## 3. Какие драйверы нужны / есть

### 3.1. Кастомный драйвер (`driver/driver.c`, KMDF, v1.1.4.0) — `\\.\XDMA0`
- **Единственная нода** `\\.\XDMA0`; **нет** под-нод `\control/\user/\h2c_0/
  \c2h_0/\event`.
- **Только BAR MMIO** (через `RtlCopyMemory`), **без DMA**.
- BAR-фолбэк: `0x40000000–0x7FFFFFFF` → BAR0 (offset = addr − 0x40000000);
  `>= 0x80000000` → BAR2 (offset = addr − 0x80000000; FIX-11: BAR2 маппится
  только если ≥16 MB, иначе — `STATUS_DEVICE_NOT_CONNECTED`).
- Один IOCTL `0x800 GET_BAR_INFO`.

### 3.2. Официальный Xilinx 2017 (`xdma_driver_win_src_2017`)
- Под-ноды `control/user/h2c/c2h/event`, **DMA реализован**.
- ⚠️ `sys\driver.c` в этом дереве **подменён** локальной копией кастомного
  `driver\driver.c` (старая, БЕЗ FIX-11, единственная нода `\\.\XDMA0`) —
  не подлинный апстрим 2017. `file_io.c`/`libxdma` — нетронутые, но
  **неиспользуемые** актуальным driver.c.

---

## 4. Вывод по совместимости текущего Windows-стека

- **Работают на текущем Windows-стеке (через `\\.\XDMA0` + MMIO)**:
  регистры (TDOT/GPIO/DFX/ICAP/SPI/XADC), горячая замена RP (DFX-swap через
  `icap_ctrl`), SPI-hotflash, мониторинг XADC.
- **НЕ работает**: **DMA→DDR3** (и, следовательно, tdot-вычисления через
  scheduler на Windows). Причина — кастомный драйвер **не обслуживает**
  DMA-каналы; FPGA-каналы присутствуют (2×H2C + 2×C2H), но драйвер их не
  обслуживает.
- На Linux полный стек работает (DMA + регистры).

---

## 5. Примечания

- **HWICAP удалён** из активной DFX-сборки; **единственный ICAP** =
  `icap_ctrl` `0x40004000` (`S_AXI_ICAP_REGS`, M04). HWICAP `0x40001000` — только
  legacy `block_design_top.tcl`.
- FIX-11: второй BAR маппится как DDR3 только при размере ≥16 MB; MSI-X
  (64 KB) не маппится → DDR3-запросы на Windows без FIX-11 дают
  `STATUS_DEVICE_NOT_CONNECTED`.
- Изменение: `XdmaWinUpstream.write_dma/read_dma` больше **не прибавляют**
  `DDR3_BASE` к смещению — offset передаётся как есть.