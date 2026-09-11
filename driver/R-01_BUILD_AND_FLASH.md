# R-01 — Пересборка битстрима и прошивка платы (BAR0 = 128 МБ)

> Кому: инженеру за машиной с платой. Цель R-01 — заменить устаревший битстрим
> актуальным (BAR0 = 128 МБ), после чего станут доступны регистры периферии
> (GPIO/TDOT/XADC) и корректная карта адресов из `docs/ADDRESS_MAP.md`.
>
> Контекст: измерено на железе, что BAR0 = 1 МБ (ожидается 128 МБ по
> `scripts/build_dfx.tcl`), записи в AXI-Lite не залипают. Это значит, что в
> SPI-флеш залит другой/старый образ. Подробности — `driver/xdma-bsod-report.html`,
> `driver/RISK_REGISTER.md` (R-01).

---

## ⚠️ ВАЖНО: в системе ДВА каталога проекта — не перепутайте

| Каталог | Что это | Годится для сборки? |
|---|---|---|
| **`C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3`** | **рабочий проект** (HEAD с исправлениями, self-contained `Makefile` ~3.5 КБ) | ✅ ДА — собирать здесь |
| `C:\A7_M2\EXAMPLES\Xilinx-Artix7-M2-PCIE-200-DDR3` | устаревший клон того же репозитория (commit `8dfaa68`); `Makefile` = `include ../../scripts/make/common.mk` (файла нет в этом дереве) | ❌ НЕТ — `make` падает с `No such file or directory` |

Быстрая проверка, что вы в правильном каталоге:

```bat
cd C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3
dir Makefile            :: должно быть ~3.5 КБ, НЕ 38 байт
dir scripts\build_dfx.tcl
git log --oneline -1    :: должен быть коммит с аудитом (c74dd53 или новее)
```

Если нужен именно тот клон в `EXAMPLES\`, сначала обновите его
(`git -C C:\A7_M2\EXAMPLES\Xilinx-Artix7-M2-PCIE-200-DDR3 pull --ff-only`) —
тогда Makefile станет self-contained. Работать одновременно в двух клонах не
рекомендуется: артефакты и `C:\build_dfx` у них общие.

---

## 0. Версии (проверено на этой машине)

| Компонент | Версия / значение |
|---|---|
| Vivado | **2025.2** — `C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat` |
| Часть (FPGA) | `xc7a200tfbg484-2` (Artix-7 XC7A200T) |
| XDMA IP | `xilinx.com:ip:xdma:4.2` (AXI 128 бит @ 125 МГц, 2 H2C + 2 C2H) |
| MIG DDR3 | 7-series, 256 МБ, MT41J128M16XX-125 |
| SPI-флеш | **W25Q128JV** (128 Мбит, SPIx4) · Vivado-part: `w25q128jvq-spi-x1_x2_x4` |
| JTAG | кабель Digilent/FTDI (драйверы `xpcwinusb`, Digilent USB установлены) |
| Сборка-скрипт | `scripts/build_dfx.tcl` (мастер), обёртка `Makefile` |
| Проект сборки | `C:\build_dfx` (создаётся заново; MAX_PATH-обход) |
| Артефакты | `build/artifacts_dfx/` (в корне репозитория) |
| Windows-драйвер | v1.1.4.0 (тест-подпись), `driver/build.cmd` |
| Python (проверки) | `C:\Python39\python.exe` — 3.9.13, torch 2.8.0+cpu |

## 1. Что понадобится

- Плата Artix-7 в слоте, **JTAG-кабель** подключён к площадке платы.
- Свободно **≥ 10 ГБ** на диске C: (проект `C:\build_dfx` + runs).
- Закрыт GUI Vivado (batch-сборка не должна конфликтовать).
- Админ-права (для драйвера и прошивки — не обязательно, но удобно).

## 2. Шаг 1 — пересборка битстрима

Из корня репозитория `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3` (проверьте путь командой `cd` + `dir Makefile` из раздела выше):

```bat
cd /d C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3
:: Вариант A (рекомендуемый, обёртка Makefile; авто-поиск Vivado 2025.2)
make build NUM_MAC=32 JOBS=8
```

```bat
:: Вариант B (напрямую Vivado)
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch ^
  -source scripts\build_dfx.tcl -tclargs NUM_MAC=32 JOBS=8
```

> `NUM_MAC` — число MAC-блоков ядра. Хост-софт в `pytorch_layer/` по умолчанию
> использует `num_mac=32`, поэтому для полной совместимости берите **NUM_MAC=32**
> (дефолт Makefile — 8; тогда передайте `num_mac=8` в `TdotCore`/`FpgaBackend`).
> `JOBS` — параллелизм; 7–12 разумно.

Что делает `build_dfx.tcl`: чистит `C:\build_dfx` и кэши → создаёт проект →
добавляет HDL RP → собирает BD (`xdma_ddr3_dfx.bd`) → постобработка (TDOT/ICAP/XADC
порты, экспорт клока) → **BAR0 = 128 МБ** + карта адресов (печатает
«PCIe BAR REPORT») → RTL ядра → synth → impl → write_bitstream → **FATAL-гейт
тайминга** → экспорт артефактов (шаг 9) и **частичных битстримов RP** (шаг 9b).

**Обязательно проверьте в логе:**
1. `=== PCIe BAR REPORT (xdma_0) ===` → `BAR0: scale=Megabytes size=128`
   (если стоит другое — править `scripts/build_dfx.tcl` шаг 2d, НЕ прошивать);
2. `WNS/WHS/WPWS ≥ 0` — при нарушении тайминга **артефакты не экспортируются**
   (см. `build/artifacts_dfx/timing_FATAL.rpt`);
3. финальные строки — `=== 9. EXPORT ARTIFACTS ===` без ошибок.

**Результат в `build\artifacts_dfx\`:**

```
xdma_ddr3_core_top.bit   — для JTAG-загрузки в FPGA (volatile)
xdma_ddr3_core_top.bin   — тело битстрима (для ICAP/флеша)
xdma_ddr3_core_top.mcs   — образ для SPI-флеша (128 Мбит, SPIx4)
*partial*.bit / *.bin    — частичные битстримы RP (DFX, dfx_swap.py)
timing_FATAL.rpt, timing_summary.rpt, utilization.txt
```

Проверка: `dir build\artifacts_dfx` (должны быть `.bit`, `.bin`, `.mcs`).

## 3. Шаг 2 — прошивка SPI-флеша (постоянная, плата грузится сама)

### Вариант A (автоматически, рекомендую): скрипт `scripts/flash_program.tcl`

```bat
"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch ^
  -source scripts\flash_program.tcl -tclargs build\artifacts_dfx\xdma_ddr3_core_top.bin
```

Скрипт: подключается к hw_server/target, находит `xc7a200t_0`, создаёт cfgmem
`w25q128jvq-spi-x1_x2_x4`, делает Erase → Program → Verify (≈ 2 мин). Полностью
повторяет проверенную последовательность из `C:\build_dfx\vivado.log` (10.09.2026).

### Вариант B (GUI, Vivado Hardware Manager)

1. Vivado → **Open Hardware Manager** → **Open Target** → **Auto Connect**.
2. Правый клик по `xc7a200t_0` → **Add Configuration Memory Device…** →
   выбрать **w25q128jvq-spi-x1_x2_x4** → OK.
3. В диалоге Program Configuration Memory Device: **Configuration file** =
   `build\artifacts_dfx\xdma_ddr3_core_top.mcs` (или `.bin`), галочки
   **Erase / Program / Verify** → **Program**.

### Вариант C (быстрая проверка без перепрошивки флеша, volatile)

В Hardware Manager: **Program Device…** → `xdma_ddr3_core_top.bit` → Program.
Битстрим живёт до выключения питания (полезно быстро проверить сборку).

> Внимание: прошивка флеша идёт ~2 минуты (стирание 128 Мбит + запись +
> верификация). Не отключайте питание/кабель до сообщения
> `Program/Verify Operation successful`.

## 4. Шаг 3 — проверка после прошивки

1. **Полный power-cycle платы** (снять питание, подождать, включить) — чтобы FPGA
   загрузилась из флеша.
2. Диспетчер устройств → **Системные устройства** → «XDMA DDR3 Ternary
   Accelerator v1.1» (без жёлтых знаков).
3. Измерьте BAR (маленькая проверка, читает драйвер):
   ```bat
   driver\build\test_xdma.exe gpio
   ```
   Первая строка после «Device opened OK»: `BAR map: BAR0=131072 KB, BAR2=64 KB`
   → **BAR0 = 128 МБ** (131072 КБ). Если снова 1024 КБ — прошит не тот образ.
4. Прогоните тесты **по одному** (важно для изоляции):
   ```bat
   driver\build\test_xdma.exe gpio
   driver\build\test_xdma.exe tdot
   driver\build\test_xdma.exe xadc
   driver\build\test_xdma.exe proto
   driver\build\test_xdma.exe icap
   driver\build\test_xdma.exe ddr3
   ```
   Ожидание на актуальном битстриме: GPIO/TDOT/XADC/PROTO — PASS; `icap` — PASS;
   `ddr3` — **SKIP** (в DFX-сборке DDR3 доступна только через DMA-каналы).
5. DMA-проверка DDR3 (h2c/c2h) — на Linux:
   `python pytorch_layer/xdma_driver.py --selftest --dot`; на Windows нужен
   `xdma_rw.exe` (см. `driver/RISK_REGISTER.md` R-05).
6. DFX (опционально): `python pytorch_layer/dfx_swap.py --status`, затем замена RP
   частичным битстримом: `python pytorch_layer/dfx_swap.py build/artifacts_dfx/*partial*.bit`.

## 5. Откат / если что-то пошло не так

- JTAG-программа (вариант C) **volatile** — достаточно power-cycle, вернётся
  образ из флеша.
- Если прошитый образ нерабочий: перепрошейте предыдущий `.mcs`/`.bin`
  (если сохранили) тем же скриптом; при отсутствии — повторите шаг 1 на
  предыдущем коммите: `git checkout <commit> -- rtl scripts constraints` → `make build`.
- Ошибки прошивки (не найден target/cfgmem) — проверьте кабель/драйвер JTAG и что
  Vivado видит `xc7a200t_0` в Open Target.
- Диагностика драйвера при проблемах: `driver/ROLLBACK.md`, `driver/HANDOFF.md`.

## 5а. Известные помехи: антивирус и проверка подписи Vivado

Vivado при старте проверяет цифровые подписи загружаемых библиотек. На машинах с
агрессивным антивирусом (наблюдалось: **360 Total Security**, служба
`QHActiveDefense`, процесс `QHSafeTray.exe`) эта проверка может **плавающе**
падать с ошибкой:

```
Unknown error occured while verifying the digital signature. Error Code: -2146869232
(0x80096010 = TRUST_E_BAD_DIGEST)
```

при том что подпись самого файла валидна (проверяется `Get-AuthenticodeSignature`).
Подробный разбор — `driver/ERROR-FIX-LOG.md` (E-11), риск R-13.

Что делать:
1. Добавить в **360 Total Security** исключения: `C:\AMDDesignTools` и каталог проекта
   (или временно отключить защиту на время сборки).
2. **Просто повторить** команду `make build` — при повторном запуске проверка проходит.
3. Диагностика: `powershell -ExecutionPolicy Bypass -File scripts\check_vivado_signatures.ps1`.
4. Держать доступ в интернет (построение цепочки сертификатов); обновить корневые сертификаты Windows.

## 6. Связанные документы

| Документ | О чём |
|---|---|
| `driver/xdma-bsod-report.html` | разбор BSOD (0x7E/0x124), причины, исправления |
| `driver/ERROR-FIX-LOG.md` | журнал ошибок и исправлений (E-01…E-10) |
| `driver/AUDIT-REPORT.md` | повторный аудит кода до/после |
| `driver/RISK_REGISTER.md` | риски (R-01 — эта задача) |
| `driver/HANDOFF.md` | что изменено/проверено/осталось |
| `driver/VERIFY.cmd` | проверка драйвера+Python одной командой |
| `docs/ADDRESS_MAP.md` | карта адресов (источник истины) |
| `xdma_ddr3_dfx_README.md` | архитектура DFX и DFX Socket |
