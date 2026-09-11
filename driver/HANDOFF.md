# HANDOFF — итоговая передача (XDMA Artix-7 M.2)

> Дата: 2026-09-11 · Исполнитель: AutoClaw · Область: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3`

## 1. Что изменено (эта сессия)

| # | Файл | Изменение | Зачем |
|---|---|---|---|
| 1 | `driver/build.cmd` | `/entry:FxDriverEntry`; удалён sc-хвост; дата INF = вчера-UTC (InvariantCulture); версия 1.1.4.0 | устранён BSOD 0x1000007E; исправлена сборка/упаковка |
| 2 | `driver/XDMA.inx` | `[SourceDisksNames]/[SourceDisksFiles]`; `DriverVer 1.1.4.0` | inf2cat создаёт каталог; корректная версия |
| 3 | `driver/driver.c` | FIX-11: порог `DDR3_MIN_WINDOW_BYTES` (16 МБ) для второго BAR + `DbgPrint` диагностика | устранён BSOD 0x124 (запись в MSI-X BAR) |
| 4 | `driver/test_xdma.c` | FIX-12: `IOCTL_XDMA_GET_BAR_INFO`, SKIP для DDR3/XADC, счётчик SKIP | тесты не трогают недоступные области |
| 5 | `driver/emulate_test.py`, `driver/edge_cases.py` | карта приведена к канонической DFX | консистентность с ADDRESS_MAP |
| 6 | `driver/install.cmd`, `driver/uninstall.cmd` | FIX-14: локализационно-устойчивый разбор `pnputil`; удаление копии в System32 | обновление/удаление драйвера работает на RU Windows |
| 7 | `pytorch_layer/monitor_temp.py` | FIX-13: INVALID-детект (BUG-031) + `--allow-invalid` | нет ложных «0 °C» |
| 8 | `pytorch_layer/xdma_driver.py` | шапка приведена к DFX-карте (DMA-only) | консистентность |
| 9 | `.gitignore` | добавлено `_backup_*/` | служебные снапшоты не попадают в git |
| 10 | `driver/ROLLBACK.md` | обновлён под v1.1.4.0 + путь бэкапа | процедура отката |

## 2. Что проверено (evidence)

- **Драйвер**: сборка `Build FULL SUCCESS`; INF/cat подписаны; импорты `WDFLDR.SYS`; entry `0x1988`; установлен `oem10.inf` **v1.1.4.0**; сервис `XDMA` **RUNNING**; устройство «XDMA DDR3 Ternary Accelerator v1.1» — Status OK, Problem 0.
- **Тесты**: `test_xdma.exe ddr3` → **SKIP** (EXIT 0, без BSOD); `gpio tdot xadc` → FAIL/SKIP штатно, без сбоев ОС; число минидампов не изменилось (3).
- **Python**: 71/71 файлов компилируются; `ternary_sw` 10/10; `verify_fpga_backend` (mock) OK; `ternary_dot_layer` OK (diff 4.8e-07); `emulate_test.py` 6/6; `edge_cases.py` 6/6.
- **Сборка Vivado**: не запускалась (часы); скрипты прочитаны, конфиг BAR0=128 МБ подтверждён в `build_dfx.tcl`.

## 3. Что осталось (требует действия)

1. **R-01**: пересобрать и перепрошить плату актуальным битстримом (BAR0=128 МБ) — после этого прогнать `test_xdma.exe gpio tdot xadc proto icap` и `python pytorch_layer/xdma_driver.py --selftest`.
2. **R-03**: прогнать `icap`/`proto` по одному на актуальном битстриме.
3. **R-02**: подтвердить калибровку MIG и DMA-паттерн.
4. **R-04**: при необходимости — чтение температуры через MIG DRP.

## 4. Как собирать и проверять

```bat
:: Сборка драйвера (Admin). Артефакты в driver\build\sys\
driver\build.cmd

:: Установка / обновление (Admin)
driver\install.cmd
:: или напрямую:
pnputil /add-driver build\sys\XDMA.inf /install

:: Полная проверка (см. driver\VERIFY.cmd)
driver\VERIFY.cmd
```

**Быстрая проверка без железа**: `C:\Python39\python.exe driver\emulate_test.py` и `... driver\edge_cases.py` (эмуляция драйвер+FPGA, 6/6 и 6/6).

## 5. Откат

- Снапшот до правок: `_backup_20260911_215624\` (корень проекта).
- Правки в git: `git -C C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3 diff` показывает 11 изменённых файлов; откат — `git checkout -- <файлы>` (или копирование из снапшота).
- Драйвер: удаление/старая версия — `driver/ROLLBACK.md` (включая вывод из BSOD-цикла через WinRE, `Start=4`).

## 6. Для продолжения работы сторонним инженером

1. Прочитайте `driver\PROJECT_MAP.md` (карта) → `driver\ERROR-FIX-LOG.md` (что и почему изменено) → `driver\RISK_REGISTER.md` (что открыто).
2. Источник истины по адресам — `docs/ADDRESS_MAP.md`; любое изменение адресов синхронизируется по чек-листу §12.
3. Перед изменениями — новый `_backup_<ts>\` и запись в `ERROR-FIX-LOG.md`.
