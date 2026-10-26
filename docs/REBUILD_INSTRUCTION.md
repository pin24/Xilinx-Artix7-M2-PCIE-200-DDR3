# Пересборка прошивки (FLAT, актуально 2026-10-26)

> Каноническая инструкция — [`docs/guide/08-build-flash.md`](guide/08-build-flash.md).
> Данный файл — краткая пересборка/перепрошивка. Активная линия — **только FLAT**
> (без DFX/ICAP/partial-битстримов); DFX-скрипты (`build_dfx.tcl`) — исторические.

## 1. Рабочий конфиг и чего ждать

- **NUM_MAC=32, ADDERS=8, DEVPROG_EN=1** → `CORE_PARAMS=0x820`.
- Data-путь синхронный (без async-конвертера) — `SMC.M00(100МГц)→regslice→MIG(100МГц)`.

## 2. Предварительные требования

- Vivado 2025.2: `C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat`.
- Рабочая копия/каталог репозитория.
- Каталог проекта (по умолч. `C:\build_flat`; можно задать env `PROJ_DIR`).

## 3. Сборка FLAT

```bat
cd /d C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch ^
  -source scripts\build_flat.tcl -tclargs NUM_MAC=32 ADDERS=8 DEVPROG_EN=1 JOBS=4 -nojournal
```

Если `C:\build_flat` занят открытым Vivado/hw_server, используй PROJ_DIR:
```bat
set PROJ_DIR=C:\Temp\gigatool\build_flat64
... та же команда ...
```

Быстрые проверки BD-правок без синтеза:
```bat
set PROJ_DIR=C:\Temp\gigatool\build_flat64
vivado -mode batch -source scripts\build_flat.tcl -tclargs NUM_MAC=32 ADDERS=8 DEVPROG_EN=1 SKIP_SYNTH=1 -nojournal
```

## 4. Артефакты

`build\artifacts_flat\`: `xdma_ddr3_core_top.{bit,bin,mcs}` (mcs — для прошивки).

## 5. Прошивка и проверка

```bat
vivado -mode batch -source scripts\flash_program.tcl -tclargs build\artifacts_flat\xdma_ddr3_core_top.mcs
```
Затем power-cycle + (при необходимости) ресканирование PCIe/драйвера XDMA на хосте.
Проверка:
```bat
python scripts\probe_core.py          % ожид. CORE_PARAMS=0x820
python scripts\obs_smi.py --once --interval 0.5
python scripts\test_dprog_single_dot.py   % 3.5
```

## 6. Откат

Текущий битстрим в `build\artifacts_flat\` и запасные `.mcs` в корне — восстановить
перепрошивкой. Старые версии — в git-истории (`docs/CHANGE_LOG_*.md`).

## 7. Частые проблемы

- `vivado not found` → задать полный путь явно.
- `CORE_PARAMS` не `0x820` → убедиться, что переданы `NUM_MAC=32 ADDERS=8`.
- Устройство XDMA в статусе Unknown после прошивки → перезагрузить хост (ресканирование PCIe).
- Ошибка flash Labtools 27-3347 → обеспечить разгрузку SPI-over-PCIe перед программированием.