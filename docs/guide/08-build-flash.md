# 08. Сборка прошивки и прошивка платы

## Сборка (build_flat.tcl)
Проект собирается с нуля из RTL+BD-скрипта `scripts/xdma_ddr3_bd.tcl` и RTL в `rtl/`.

### Базовые команды
```
:: default: 32/8 рабочая прошивка:
C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat ^
  -mode batch -source scripts\build_flat.tcl -tclargs NUM_MAC=32 ADDERS=8 DEVPROG_EN=1 JOBS=4 -nojournal
```
Параметры:
- `NUM_MAC` (32/64), `ADDERS`, `DEVPROG_EN` (0/1), `JOBS`.
- `SKIP_SYNTH=1` — только создать проект/BD и провалидировать (быстрая проверка правок).

### Каталог проекта
По умолчанию `C:\build_flat`. **Переопределение через env `PROJ_DIR`** (удобно, когда
`C:\build_flat` занят открытым Vivado/hw_server):
```
$env:PROJ_DIR="C:\Temp\gigatool\build_flat64"; vivado ... 
```

### Важные ограничения по конфигурации
- **NUM_MAC=64** на этом Artix-7 @125МГц на пределе тайминга (WNS падает при любых BD-правках,
  нужен перепилинг ядра). Рекомендуемый рабочий конфиг — **32/8** (WNS≈0.09-0.10).
- **ASYNC-конвертер в data-пути НЕ использовать** — он давал deadlock под нагрузкой
  (см. 05). data-путь синхронный: SMC.M00(100)→regslice→MIG(100).
- `scripts/xdma_ddr3_bd.tcl` — источник правд по BD; при изменении запускать
  `SKIP_SYNTH=1` валидацию до полной сборки.

### Артефакты
`build/artifacts_flat/`: `xdma_ddr3_core_top.{bit,bin,mcs,rbt,prm}` (mcs — для прошивки).

## Прошивка (flash_program.tcl)
```
C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat ^
  -mode batch -source scripts\flash_program.tcl -tclargs build\artifacts_flat\xdma_ddr3_core_top.mcs
```
- Пишет в QSPI (W25Q128JV) по JTAG. Нужен открытый hw_server/hw-manager.
- **Внимание:** пока активен SPI-over-PCIe битстрим, флеш-пины заняты fabric IO →
  возможна ошибка Labtools 27-3347; обеспечь паузу/разгрузку конфигурации.
- После прошивки — **power-cycle**, затем **host (ре)сканирование PCIe/драйвера XDMA**
  (иногда ребут хоста, т.к. устройство XDMA может висеть в статусе Unknown).

## Проверка после прошивки
```
python scripts/probe_core.py                      # живость; CORE_PARAMS
python scripts/obs_smi.py --once --interval 0.5   # наблюдаемость
python scripts/test_dprog_single_dot.py           # device_prog 3.5
python scripts/train_dprog_batch_mlp.py --epochs 3 --batch 32 --samples 256 --lr 0.1 --seed 0
# полный набор + кривой DDR-стресс (256КиБ) — см. 06
```

## Если тайминг не прошёл (WNS<0)
- Крит. путь чаще всего в ядре (попcount, t_dst→ad_*). Проверь конфиг (32/8), либо
  перепили ядро (pipeline). GLOBAL_RETIMING включён автоматически build_flat.