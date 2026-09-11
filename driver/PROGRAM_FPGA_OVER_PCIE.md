# PROGRAM_FPGA_OVER_PCIE — прошивка FPGA **без JTAG** (по PCIe)

> Скрипт: `pytorch_layer/program_fpga_icap.py` · Контроллер: `rtl/integration/icap_ctrl.sv` (0x4000_4000)
> Работает, когда FPGA уже сконфигурирована и PCIe-линк жив (базовый/DFX-образ проекта).

## 1. Способы программирования (%) — что вообще возможно

| Способ | Инструмент | Когда применять | Остаётся после выключения питания? |
|---|---|---|---|
| **ICAP по PCIe — полный образ** | `program_fpga_icap.py top.bin --full --yes` | FPGA уже жива, но **не применяется** (проверено 2026-09-12) — см. §9. Для полного образа — JTAG/флеш | ❌ Нет (volatile) |
| **ICAP по PCIe — частичный (RP)** | `program_fpga_icap.py p.bin --partial` / `dfx_swap.py` | DFX-обновление ускорителя (штатный путь) | ❌ Нет |
| **JTAG (Vivado HW Manager)** | `scripts/flash_program.tcl` / GUI | прошивка SPI-флеша (persistent), восстановление, «пустая» FPGA | ✅ Да (флеш W25Q128JV) |
| SPI-флеш из фабрики (без JTAG) | — **не реализовано** в проекте | «золотой» образ + доступ к SPI через STARTUPE2/USR_ACCESS2 | — (риск R-14) |

Ключевое: **по PCIe нельзя залить образ в «пустую» плату** — без работающего PCIe-эндпойнта нет канала. Для этого только JTAG/флеш (см. `driver/R-01_BUILD_AND_FLASH.md`).

## 2. Предусловия

- FPGA сконфигурирована образом с PCIe + ICAP (текущий проект), устройство живо: Windows `\\.\XDMA0` / Linux `/dev/xdma0_user` (ICAP лежит в BAR0/AXI-Lite).
- Python 3.9 (`C:\Python39\python.exe`), запуск из каталога `pytorch_layer` (там `xdma_driver.py`, `icap_load.py`).
- Windows: драйвер XDMA + `xdma_rw.exe` для MMIO (см. риск R-05). Linux: `xdma0_control`/`xdma0_user`.

## 3. Как запускать

```powershell
cd C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer

# разобрать файл, ничего не трогая:
C:\Python39\python.exe program_fpga_icap.py ..\build\artifacts_dfx\xdma_ddr3_core_top.bin --dry-run

# прогон без железа (in-memory модель ICAP) — проверка скрипта:
C:\Python39\python.exe program_fpga_icap.py ..\build\artifacts_dfx\xdma_ddr3_core_top.bin --mock

# прошивка ПОЛНОГО образа по PCIe (линк просядет на ~5–10 c):
C:\Python39\python.exe program_fpga_icap.py ..\build\artifacts_dfx\xdma_ddr3_core_top.bin --full --yes

# частичный образ (RP) — линк не рвётся:
C:\Python39\python.exe program_fpga_icap.py ..\build\artifacts_dfx\partial_rp.bin --partial
```

Что делает скрипт:
1. **Разбор файла**: sync word `0xAA995566` (в DATA уходит LE-вид `0x665599AA`), проверка размера/формата.
2. **Precheck**: читает `STATUS` ICAP (`BUSY=0 READY=1`).
3. **GO** → для каждого 32-битного слова ждёт `READY` и пишет в `DATA`.
4. **STOP** (для полного образа «не доставлен» — нормально: линк уже ушёл).
5. Печатает скорость и подсказки по проверке.

Exit codes: `0` ok · `2` usage/нужно `--yes` · `3` файл/формат · `4` precheck (ICAP занят/недоступен) · `5` ошибка загрузки.

## 4. Регистры ICAP (для справки)

| Адрес (BAR0-rel) | Имя | Смысл |
|---|---|---|
| `0x4000_4000 +0x00` | CTRL | bit0 GO (самосброс), bit1 STOP |
| `+0x04` | STATUS | bit0 READY (mailbox свободен), bit1 BUSY |
| `+0x08` | DATA | write-only, 32-бит слово (LE) |

RTL: `rtl/integration/icap_ctrl.sv` (ICAPE2 X32 @62.5 МГц). Альтернатива — Xilinx `axi_hwicap` на `0x4000_1000`.

## 5. Что ожидать и как восстановиться

- **Полный образ**: во время загрузки переконфигурируется весь кристалл, включая PCIe-блок → линк пропадёт на ~5–10 с, устройство в диспетчере может мигнуть/пропасть и вернуться. Если не вернулось — **power-cycle**: FPGA поднимется из SPI-флеша (флеш ICAP не трогает) → безопасно.
- **Частичный образ**: PCIe не рвётся (это и есть DFX).

## 6. Проверка после прошивки

```powershell
# Windows:
driver\build\test_xdma.exe gpio         # строка "BAR map: BAR0=131072 KB, BAR2=64 KB" для актуального образа
python pytorch_layer\xdma_driver.py --selftest
python pytorch_layer\dfx_swap.py --status
```
Также диспетчер устройств → «Системные устройства» → «XDMA DDR3 Ternary Accelerator v1.1».

## 7. Ограничения и риски

- Прошивка по ICAP **временная** (сбрасывается выключением питания). Постоянно — только через флеш (JTAG) или спец. дизайн SPI-over-PCIe (не реализован, R-14).
- Полный образ должен быть **совместим** с текущим по PCIe/ICAP-инфраструктуре, иначе восстановление только power-cycle + JTAG.
- Нельзя прошить «пустую» FPGA по PCIe (нет линка).
- Скорость: mailbox-слово за PCIe (~10–30 тыс. слов/с на Gen2) → полный образ 4.5 МБ (~1.1 млн слов) ≈ 40–100 с. Для быстрой прошивки используйте JTAG/флеш.

## 8. Ошибка «неверный sync word 0xFFFFFFFF …» — что это (E-13)

Vivado-овские `.bin`/`.bit` для 7-серии начинаются с **48-байтовой преамбулы**:

```
FF x32 | 00 00 00 BB 11 22 00 44 | FF x8 | AA 99 55 66 (sync) | ...
```

— 32x0xFF (bus-width detect) + паттерн автоопределения ширины шины + 8x0xFF.
Первое LE-слово такого файла = `0xFFFFFFFF`, а не sync → старый загрузчик падал с
«неверный sync word 0xFFFFFFFF». Исправлено (E-13): `find_sync_offset()` ищет
sync-слово в первых 1024 байтах (выравнивание по 4) и **пропускает преамбулу**;
работает и для полного, и для частичного образов.
Числа ваших файлов: полный `xdma_ddr3_core_top.bin` = 5 399 244 б (**1 349 799 слов**),
частичный `..._partial.bin` = 2 023 652 б (**505 901 слово**).

## 9. Результат проверки на железе (2026-09-12) — важно

Полный образ `xdma_ddr3_core_top.bin` был передан по ICAP успешно (1 349 799 слов
за 19 с, exit 0), ICAP STATUS до/после = `0x1`, плата не пострадала. **НО образ
не применился:**

| Проверка | До | После |
|---|---|---|
| BAR0 (probe после remove+rescan) | 1024 КБ | **1024 КБ** (не 131072) |
| GPIO_TRI readback (write 0) | 0xFFFFFFFF | 0xFFFFFFFF |
| Перечисление PCIe / PnP-события | — | без изменений |

При этом сам битстрим корректен: в собранной IP-конфигурации
`pf0_bar0_scale=Megabytes`, `pf0_bar0_size=128` (проверено в `.xci` в `C:\build_dfx`).
Значит, дело в механизме, а не в файле.

**Вывод:** полная реконфигурация кристалла через ICAP не срабатывает (поток идёт
через порт, реализованный в той же фабрике, которую перезаписывает; поддержанный
Xilinx путь для полного образа — конфигурационный движок: JTAG/SPI). Раньше
«ICAP self-test PASS» проверял только регистровый handshake (GO/READY/DATA/STOP),
но не факт записи CRAM.

**Штатные пути:**
- полный образ -> `scripts/flash_program.tcl` (JTAG, SPI-флеш) -> power-cycle (R-01);
- реконфигурация ускорителя -> частичный (RP) образ через ICAP (DFX, проверить на
  актуальном статик-регионе);
- постоянное обновление без JTAG -> требует SPI-over-PCIe (STARTUPE2) + IPROG — в
  проекте пока нет (R-14).

## 10. Windows: штатный драйвер вместо xdma_rw.exe

На Windows Python-слой теперь общается с вашим драйвером напрямую (`\\.\XDMA0`,
ReadFile/WriteFile по смещению = AXI-адрес) через класс `XdmaWinDriver`
(`xdma_driver.py`) — xdma_rw.exe для регистров/ICAP **не нужен**. `xdma_rw.exe`
остаётся только для DMA (h2c/c2h) в `XdmaWindows`. Проверено на железе:
`ICAP STATUS = 0x1`, чтение/запись GPIO проходят.
