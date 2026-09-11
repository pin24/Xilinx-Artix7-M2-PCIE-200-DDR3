# ENVIRONMENT_MANIFEST — окружение сборки и проверки

> Снято: 2026-09-11, хост `DESKTOP-27KRDOC`. Все команды воспроизводимы на этой машине.

## Хост

| Параметр | Значение |
|---|---|
| ОС | Windows 10 Pro for Workstations, build 19041.5737 (kernel 10.0.19041) |
| Материнская плата | Gigabyte Z890 AORUS ELITE X ICE (BIOS F9, 2024-10-18) |
| CPU | Intel (family 6, model 0xC6), 20 логических процессоров, ~2.26 ГГц базовая |
| Драйвер GPU | — (CUDA не используется) |

## FPGA / Vivado

| Параметр | Значение |
|---|---|
| Vivado | **2025.2** (`C:\AMDDesignTools\2025.2`) |
| Плата | Xilinx Artix-7 XC7A200T, M.2 PCIe-200-DDR3 |
| PCIe | Vendor 0x10EE (Xilinx), Device **0x7024**, Gen2 x4 |
| XDMA IP | `xilinx.com:ip:xdma:4.2` (Vivado 2025.2), AXI 128 бит @ 125 МГц, 2 H2C + 2 C2H |
| KMDF (драйвер) | 1.15 (`Lib\wdf\kmdf\x64\1.15`) |
| DDR3 | MIG 7-series, 256 МБ, MT41J128M16XX-125 |
| Проект сборки | генерируется в `C:\build_dfx` (`scripts/build_dfx.tcl`); последний лог 2026-09-10 22:17 |

## Драйвер (Windows)

| Параметр | Значение |
|---|---|
| Версия | **1.1.4.0** (`DriverVer=09/10/2026,1.1.4.0` в INF) |
| Компилятор | VS2015 (VC 14.0), `cl.exe` x64 |
| WDK | `C:\Program Files (x86)\Windows Kits\10` (10.0.14393.0 + kmdf 1.15) |
| Linker libs | `ntoskrnl.lib hal.lib wdfldr.lib wdfdriverentry.lib`, `/entry:FxDriverEntry` |
| Подпись | тестовая, `WDKTestCert` (Root + TrustedPublisher), `testsigning = Yes` |
| Установка | PnP: `pnputil /add-driver build\sys\XDMA.inf /install` → staged `oem10.inf` |
| Отладочные символы | kernel-символы качаются с `msdl.microsoft.com` (WinDbg `kd`) |

## Python / PyTorch

| Параметр | Значение |
|---|---|
| Рабочий интерпретатор | **`C:\Python39\python.exe`** — Python **3.9.13** |
| PyTorch | **2.8.0+cpu** (CUDA недоступна: `torch.cuda.is_available() == False`) |
| NumPy | присутствует (используется `fpga_backend`, `ternary_dot_layer`) |
| Альтернативы | Python 3.10 (`C:\Program Files\Python310`, без torch); Python 3.13 — встроенный в AutoClaw (без torch) |
| Зависимости проекта | только stdlib + numpy/torch + опц. `tqdm` (progress-bar в `icap_load.py`) |

## Проверки окружения (evidence)

```
python --version            -> Python 3.9.13            (C:\Python39\python.exe)
python -c "import torch..." -> torch 2.8.0+cpu, cuda False
Vivado                      -> C:\AMDDesignTools\2025.2
bcdedit /enum {current}     -> testsigning  Yes
pnputil /enum-drivers       -> oem10.inf (xdma.inf) DriverVer 09/10/2026 1.1.4.0
Get-PnpDevice VEN_10EE&DEV_7024 -> "XDMA DDR3 Ternary Accelerator v1.1", Status OK, Problem 0
```

## Известные ограничения окружения

- Симуляция RTL (xsim) доступна только из Vivado 2025.2; в этой сессии не запускалась (долгие прогоны).
- Полная сборка FPGA (synth/impl/bitstream) занимает часы и в этой сессии не выполнялась — см. RISK_REGISTER.
- Аппаратные тесты ограничены текущей загруженной в плату конфигурацией (см. R-01).
