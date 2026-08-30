# XDMA DDR3 Driver — Development Log

## Project
**XDMA_DDR3** — троичный ускоритель (TFloat48) на базе XDMA PCIe (x4 Gen2) + DDR3 (256MB).
Архитектура: Artix-7 XC7A200T, Vivado, KMDF драйвер Windows.

## Repository Structure

```
xdma_driver_win_src_2017/
├── XDMA.sln              # Visual Studio 2015 solution
├── build.cmd             # Полный цикл сборки (cl + link + sign)
├── clean.cmd             # Очистка артефактов
├── sys/
│   ├── driver.c          # KMDF драйвер (BAR0+BAR2, Read/Write/IOCTL)
│   ├── XDMA.inx          # INF-шаблон
│   └── XDMA_Driver.vcxproj
├── exe/
│   ├── test_xdma.c       # Тестовое приложение (GPIO, TDOT, XADC, ICAP)
│   └── XDMA_Test.vcxproj
├── build/
│   ├── sys/              # Выход: XDMA.sys, XDMA.cat, XDMA.cer, XDMA.inf
│   └── exe/              # Выход: test_xdma.exe
├── build_tmp/            # Временные .obj файлы
├── inc/                  # Общие заголовки (оригинальные Xilinx)
└── libxdma/              # Оригинальная библиотека (не используется)
```

## Address Map

| Периферия | Адрес | Размер | Описание |
|-----------|-------|--------|----------|
| GPIO (LED) | 0x4000_0000 | 4K | 3 LED |
| TDOT_REGS | 0x4000_1000 | 4K | Регистры троичного ядра |
| ICAP | 0x4000_2000 | 4K | Перезагрузка FPGA |
| XADC | 0x4600_0000 | 4K | Температура/напряжение |
| DDR3 | 0x8000_0000 | 256MB | Данные для вычислений |

## Hardware Configuration

- **PCIe:** Xilinx XDMA IP, 4-lane Gen2
- **BAR0:** AXI-Lite control (1:1 mapping, 64KB)
- **BAR2:** DDR3 access (256MB, 0x80000000+)
- **KMDF:** 1.15
- **WDK:** 10.0.14393.0
- **VS:** 2015 (v140)

## Build Instructions

### Prerequisites
1. Visual Studio 2015 with WDK 10.0.14393.0
2. Test signing enabled: `bcdedit /set testsigning on`
3. Admin rights for driver installation

### Build
```cmd
cd C:\A7_M2\EXAMPLES\XDMA_DDR3\xdma_driver_win_src_2017
build.cmd
```

Or open `XDMA.sln` in VS2015, select `Win10_Release|x64`, Build.

### Output
```
build\sys\XDMA.sys     — Подписанный драйвер (26 KB)
build\sys\XDMA.cat     — Каталожный файл
build\sys\XDMA.cer     — Сертификат для установки
build\sys\XDMA.inf     — INF-файл
build\exe\test_xdma.exe — Тестовое приложение (119 KB)
```

### Installation
```cmd
sc create XDMA type= kernel binpath= "C:\Windows\System32\drivers\XDMA.sys" start= demand
sc start XDMA
test_xdma.exe
```

## Driver Design

### SAFE INIT (Critical)
**Никаких чтений из BAR'ов при инициализации.** Только `MmMapIoSpace` в `EvtDevicePrepareHardware`.
Это предотвращает BSOD при зависшем/неотвечающем FPGA.

### BAR Selection
- `offset < 0x80000000` → BAR0 (AXI-Lite, прямой offset)
- `offset >= 0x80000000` → BAR2 (DDR3, offset - 0x80000000)

### I/O Model
- `ReadFile`/`WriteFile` с OVERLAPPED, offset = адрес регистра
- `IOCTL_XDMA_GET_BAR_INFO` — получение информации о BAR
- `RtlCopyMemory` (HE `READ_REGISTER`) — безопасно при зависшем FPGA

## Test Plan

| Test | Function | Description |
|------|----------|-------------|
| GPIO | TestGpio() | LED on/off, TRI config |
| TDOT_REGS | TestTdotRegs() | Write/readback всех регистров |
| XADC | TestXadc() | Температура и VCCINT |
| TDOT_PROTO | TestTdotProtocol() | N_IN → ADDR → GO → DONE → RESULT |
| ICAP | TestIcap() | GO/READY проверка |

## Error Log (known issues)

| # | Date | Description | Status |
|---|------|-------------|--------|
| 1 | 2026-08-26 | `test_xdma.c`: `\\.\XDMA0\control` → `\\.\XDMA0` | Fixed |
| 2 | 2026-08-26 | `driver.c`: BAR selection по Bar0Length (неверно) → по 0x80000000 | Fixed |
| 3 | 2026-08-26 | `driver.c`: `MmUnmapIoSpace(NULL)` → guard | Fixed |
| 4 | 2026-08-26 | `driver.c`: `DriverPoolTag='MDX'` → `'XDMA'` | Fixed |
| 5 | 2026-08-26 | `driver.c`: `WdfDeviceInitSetIoType` не задан → добавлен | Fixed |
| 6 | 2026-08-26 | `driver.c`: Integer overflow в bar2Offset+bufferLen | Fixed |
| 7 | 2026-08-26 | `driver.c`: Повторный PrepareHardware без очистки | Fixed |
| 8 | 2026-08-26 | `test_xdma.c`: `XADC_BASE=0x45000000` → `0x46000000` | Fixed |
| 9 | 2026-08-26 | `test_xdma.c`: Use-after-return при таймауте (CancelIo) | Fixed |
| 10 | 2026-08-26 | `test_xdma.c`: `GPIO_TRI=0xFF` (input) → `0x00` (output) | Fixed |
| 11 | 2026-08-26 | `build.cmd`: `sc create` без пробела после `=` | Fixed |
| 12 | 2026-08-26 | `build.cmd`: `libcntpr.lib` не нужен, `BufferOverflowK.lib` конфликтует | Fixed |
| 13 | 2026-08-26 | `driver.c`: `WdfObjectDelete(device)` → double-free | Fixed |
| 14 | 2026-08-26 | `driver.c`: Неинициализированные Bar0PhysAddr/Bar2PhysAddr | Fixed |
| 15 | 2026-08-26 | `driver.c`: `WdfPciDeviceGetBar` → `ResourceListTranslated` | Fixed |
| 16 | 2026-08-26 | `driver.c`: `__security_init_cookie` — stub-решение | Fixed |
| 17 | 2026-08-26 | Подпись: сертификат WDKTestCert Pin найден, подпись работает | Fixed |
| 18 | 2026-08-26 | **BSOD system_thread_exception_not_handled**: `__security_cookie` константа (0xABCDEF) + `__security_init_cookie` пустой = WDF падает при FxDriverEntry. Исправление: `__security_init_cookie` заполняет cookie через `KeQueryPerformanceCounter`. | Fixed |

## Open Tasks

- [ ] Проверить работу RTL-бага: GO затирает N_IN через биты [16:8] CTRL
- [ ] Реализовать DMA-тест для DDR3 (ReadBlock/WriteBlock)
- [ ] Интеграционное тестирование с FPGA
- [ ] Проверить загрузку битстрима через ICAP
- [ ] Создать инсталлятор (.msi) для автоматической установки