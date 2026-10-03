# Пересборка прошивки (после диагностических правок 03.10.2026)

Обновлено: 2026-10-03, после внесения диагностики DDR3/DMA
(NUM_MAC 16/8, diag_axi_sniffer, BRAM-обход 8 КБ @0x00000000, host AXI-Lite 0x40006000).

---

## 1. Что изменилось и чего ждать

- Ядро по умолчанию **NUM_MAC=16, ADDERS=8** (было 32/8).
  ➜ **CORE_PARAMS после прошивки станет `0x00000810` (16/8), НЕ `0x820`**.
- Добавлен `diag_axi_sniffer` (watch-only на шине tdot-мастера) и BRAM-обход.
- BRAM 8 КБ доступен: для ядра/XDMA по `0x00000000`, для хоста по AXI-Lite `0x40006000`.

---

## 2. Предварительные требования

1. **Vivado 2025.2** установлен: `C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat`
   (Makefile авто-обнаруживает этот путь).
2. Рабочая копия — `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3-nodfx`
   (в ней уже внесены RTL/BD-правки; они же закоммичены в origin, commit `36b6926`).
3. Генерация MIG/DFX требует **короткий путь** (`C:/build_dfx` — авто по умолчанию).
4. Запуск от имени пользователя с правами на запись в `C:\build_dfx` и в корень
   репозитория.
5. (Рекомендация) Разрешить `C:\AMDDesignTools` и каталог проекта в антивирусе
   (360 Total Security может ложно блокировать; см. ERROR-FIX-LOG E-11).

---

## 3. Команды сборки

Откройте CMD (не PowerShell для гарантии передачи `=`) и перейдите в корень:

```bat
cd /d C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3-nodfx
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;%PATH%
```

### 3.1 Полная DFX-сборка (это то, что нужно)

```bat
make build NUM_MAC=16 ADDERS=8 JOBS=8
```

- Создаёт проект с нуля в `C:/build_dfx`, строит BD, post-обработку,
  синтез + реализацию + bitstream + partial-артефакты (RP).
- ВАЖНО: передаёте `NUM_MAC=16 ADDERS=8` явно — надёжнее, чем полагаться на дефолты.
- Ошибка BUG-033 (срезание '=') в `make` не проявляется (make передаёт `-tclargs`
  одним аргументом); скрипт всё равно имеет защиту от позиционной формы.

### 3.2 Только создать проект, без синтеза (быстрый чекап BD-правок)

```bat
make proj
```

Затем вручную открыть `C:/build_dfx/m2_artix7_xdma_ddr3_dfx.xpr` в Vivado GUI,
проверить `Validate Design` (BD) и структуру.

### 3.3 Пересборка bitstream из существующего impl (без полного цикла создания)

```bat
make bitstream NUM_MAC=16 ADDERS=8
```

### 3.4 FLAT-вариант (без DFX) — если нужен именно он

```bat
make build-flat NUM_MAC=16 ADDERS=8
```

---

## 4. Где лежат результаты

| Артефакт | Путь (пример) |
|---|---|
| Проект (DFX) | `C:\build_dfx\m2_artix7_xdma_ddr3_dfx.xpr` |
| Bitstream | `C:\build_dfx\*bit` (полный) + `*partial*.bit` |
| Partial .bin | `C:\build_dfx\*partial*.bin` |
| Flat-артефакты | `build\artifacts_flat\` |

Точные пути печатает Makefile/скрипт в конце (`find` по `ARTIFACTS_DIR`).

---

## 5. После сборки — прошивка и проверка

1. **Прошить** (как обычно):
   - Полный образ для DFX: full `.bit`/`.bin`; RP-части — `partial*.bin` через
     `program_fpga_icap.py` или Vivado HW Manager (JTAG/SPI).
   - Или через `flash_program.tcl` (JTAG) + power-cycle.
2. **На стенде (Windows, драйвер v1.1.21 установлен):**
   ```bat
   test_dma.exe firmware
   ```
   Ожидается: `CORE_PARAMS = 0x00000810` (16/8), `MAGIC='TDOT'`.
3. **Проверить периферию через \user:**
   ```bat
   probe.exe   (чтение TDOT/GPIO/ICAP по \\.\XDMA0dma\user)
   ```
4. **Обходной тест DDR3 без DMA (после прошивки):**
   - Записать data/weights хостом в BRAM через AXI-Lite `0x40006000`
     (CtlWrite32 по \user, offset = 0x40006000 - 0x40000000 = 0x6000).
   - Запустить TDOT с адресами BRAM (`0x0 / 0x800 / 0x1000`).
   - Если `DONE` придёт — ядро и путь tdot→BRAM исправны, значит виноват MIG/DDR3.
   - Читать diag-счётчики (когда подключён S_AXI_DIAG) — см. DIAG_PLAN.md.

---

## 6. Откат / версии

Драйвер: архив `C:\A7_M2\driver_versions` (v1.1.17/18/20/21).
Прошивка: коммиты в origin/main (`36b6926` — диагностика). Для отката прошивки
вернуть NUM_MAC=32 в build-скриптах и пересобрать (правки diag можно выключить
`DIAG_EN=0` в `rtl/integration/xdma_ddr3_core_top.sv`).

---

## 7. Частые проблемы

- **`vivado` not found** → Makefile не нашёл авто; задать явно:
  `set VIVADO=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat`, затем `make build ...`.
- **MAX_PATH / MIG не генерится** → убедиться, что PROJ_DIR = `C:/build_dfx` (короткий).
- **CORE_PARAMS всё ещё 0x820** → сборка прошла со старым дефолтом 32: проверить,
  что NUM_MAC=16 реально передан (см. «BUILD_DFX CONFIGURATION» в логе разработки).
- **Тайминг/ресурсы**: при 16/8 запас большой; если вернуться к 32, проверить
  utilisation (BRAM 365, DSP 740 на xc7a200t).