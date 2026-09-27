# docs/ICAP_DDR3_WORKLOG.md - журнал работ по ICAP и DDR3

> Правило: каждая проверка, гипотеза, эксперимент - с датой, описанием,
> результатом, статусом. Стиль - как в docs/ERROR_HISTORY.md.

---

## 2026-09-12 - Старт работ

### Контекст
- Сборка make build NUM_MAC=32 JOBS=8 прошла успешно.
- Артефакты: build/artifacts_dfx/xdma_ddr3_core_top.bin = 5 399 244 байт.
- Плата: XDMA DDR3 Ternary Accelerator v1.1, PCI VEN_10EE&DEV_7024, Status=OK.
- Python 3.9.13 в C:\Python39\python.exe. Python 3.10.0 в PATH.
- Драйвер XDMA.sys установлен, \\.\XDMA0 доступен.

---

### [MIG-01] Проверка калибровки MIG - PASSED 2026-09-12

| Поле | Значение |
|---|---|
| **Инструмент** | pytorch_layer/check_mig.py |
| **Команда** | C:\Python39\python.exe check_mig.py |
| **Читаемый регистр** | GPIO2 @ 0x40000008 |
| **Результат** | GPIO2 = 0x00000003 |
| **mmcm_locked** | 1 |
| **init_calib_complete** | 1 |
| **Вывод** | DDR3 OK - MIG откалиброван. |
| **Статус** | ЗЕЛЕНЫЙ - DDR3 доступна |

---

### [ICAP-W01] Анализ проблемы полного образа через ICAP - ЗАКРЫТО

| Поле | Значение |
|---|---|
| **Симптом** | 1 349 799 слов переданы за 19 с, exit 0, ICAP STATUS=0x1, но BAR0 остался 1024 КБ вместо 131072 КБ. |
| **Причина** | icap_ctrl и PCIe endpoint находятся в той же фабрике, которую перезаписывает полный битстрим. Поток обрывается. |
| **Решение** | Full-образ - только JTAG/SPI. Без JTAG - SPI-over-PCIe (STARTUPE2 + IPROG, R-14). |
| **Статус** | ЗАКРЫТО - путь full-via-ICAP неработоспособен. |

---

### [DDR-01] Проверка Windows DMA-бэкенда - ROOT CAUSE НАЙДЕН

| Поле | Значение |
|---|---|
| **Где** | pytorch_layer/xdma_driver.py, класс XdmaWinDriver |
| **Симптом** | XdmaWinDriver.write_dma/read_dma явно поднимают XdmaError: "DMA не поддерживается штатным драйвером". |
| **Обходной путь** | XdmaWindows использует xdma_rw.exe (subprocess + временный файл). |
| **Решение** | Патч driver.c с IOCTL DMA + симлинками H2C/C2H. |
| **Статус** | ОТКРЫТО - план известен. |

---

*(продолжение следует по мере работ)*

---

### [MIG-02] test_xdma.exe - диагностика текущего битстрима

| Проверка | Результат |
|---|---|
| BAR map | BAR0=1024 KB, BAR2=0 KB |
| Ожидалось | BAR0=131072 KB (128 MB) |
| GPIO | FAIL (TRI=0xFFFFFFFF, ожидалось 0x0) |
| TDOT_REGS | FAIL (N_IN: wrote 0x8, read 0x0) |
| ICAP | PASS |
| XADC | SKIP (0x46000000 вне BAR0 1024 KB) |
| DDR3 | SKIP (нет MMIO-моста, только DMA) |

**ВЫВОД**: FPGA работает на СТАРОМ битстриме из SPI-флеша.
Свежая сборка `make build NUM_MAC=32` НЕ загружена в FPGA.

**Действие**: прошить `build/artifacts_dfx/xdma_ddr3_core_top.bin` через JTAG+SPI
(scripts/flash_program.tcl) и повторить тест.

**Статус**: ЖДЁТ прошивки.

---

### [DDR-02] XdmaWinDriver - DMA-методы заглушки

| Поле | Значение |
|---|---|
| Где | pytorch_layer/xdma_driver.py |
| Симптом | XdmaWinDriver.write_dma/read_dma поднимают XdmaError |
| Причина | Штатный драйвер XDMA.sys не предоставляет IOCTL DMA |
| Обходной путь | XdmaWindows через xdma_rw.exe (в системе отсутствует) |
| Решение | Патч driver.c с IOCTL H2C/C2H (см. ниже) |
| Статус | ОТКРЫТО |


---

### 2026-09-12 - Host-side SPI-flash programming script

**Файл**: `pytorch_layer/program_spi_flash.py`

**Назначение**: обновление SPI-флеша W25Q128JV через PCIe без JTAG,
через SPI-регистры модуля `spi_over_pcie` @ 0x40005000.

**Возможности**:
- `--rdid` - прочитать JEDEC ID (ожидается EF 40 18 = W25Q128JV)
- `--read OUT --addr N --len M` - вычитать произвольный диапазон
- `<bitstream.bin>` - записать образ: chip erase -> page program -> verify
- `--iprog` - после записи дёрнуть IPROG через ICAP (перезагрузка из флеша)
- `--dry-run` - проверить файл без обращений к железу

**Зависимости**: `xdma_driver.XdmaWinDriver` (ctypes, без xdma_rw.exe).

**Статус**: скрипт создан, syntax-check PASS, --help работает.
Требует железа с уже залитым битстримом, содержащим SPI-модуль.

