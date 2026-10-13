# CHANGE LOG — 2026-10-11 (полный аудит адресации + SPI stub)

Каталог: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3` (git, ветка main, HEAD 9f57084).

## 1. Полный аудит связей / регистров / адресации (без «Пети»)

Отчёт: `docs/AUDIT_FULL_2026-10-11.md`. Охвачено:
- адресная карта (новая 0x4002xxxx, DDR3 0x80000000, BRAM 0x10000000; flat vs dfx);
- регистровые карты tdot_axi4 / icap_ctrl / xadc_temp / spi / gpio + сверка с host;
- RTL-связи top (`xdma_ddr3_core_top.sv`), AXI-интерконнект, IRQ-путь, разрядности;
- host-драйвер (узлы control/user/h2c/c2h/bram, BAR-отображение, translateAxiBase, IOCTL).

Итог: оперативный путь согласован 100% (RTL↔BD↔host↔драйвер). Расхождения — МИНОР, вне
оперативного пути (эмуляторы `edge_cases.py`/`emulate_test.py` и часть доков используют легаси 0x4000_3/4xxxx).

## 2. SPI-over-PCIe → неблокирующий stub

Запрос: избавиться от `spi_over_pcie` либо сделать заглушку, не блокирующую SPI.
- Причина блокировки: реальный модуль инстанцировал STARTUPE2 и держал QSPI-пины флэша
  (FCS_B/D00-D03) как user-IO → Labtools 27-3347 при прошивке флэша по JTAG.
- Решение: `rtl/integration/spi_over_pcie.sv` переписан в stub — AXI-Lite отвечает (START→DONE
  сразу), НЕ инстанцирует STARTUPE2, `spi_cclk=0`, `qspi_cs_n=1`, `qspi_d0..d3='z`
  → флэш-пины свободны, real SPI выключен.
- Порт/интерфейс сохранён (совместим с `program_spi_flash.py`). Модуль нигде в активных
  сборках не подключён. Линт xvlog 2025.2 — чистый.

## 3. Не изменялось (возможный следующий шаг)
При решении «полностью избавиться» от SPI-функции: удалить `pytorch_layer/program_spi_flash.py`,
`rtl/integration/spi_over_pcie.sv`, `rtl/integration/flash_access_top.sv` + почистить
`docs/ADDRESS_MAP.md §5.1`, `README.md`, `INTEGRATION_REPORT.md`.

## 4. Слияние OBS-наблюдаемости из XDMA_DDR3_TMUL в main (2026-10-11, объединено)

Пришло 4 новых коммита в удалённую `XDMA_DDR3_TMUL` (a804fca, 55b21fc, 187dc69, a7b44fd) —
tdot OBS-счётчики/SNAP/BUILD_ID/CAPS + 4KB-кламп burst. Влито в main **с сохранением host-контракта**:
- в main `0x64=CORE_PARAMS`, `0x68=MAGIC` (не трогали), поэтому OBS сдвинуты на `0x6C+`
  (в TMUL они на `0x64+`; без CORE_PARAMS/MAGIC там).
- Изменены: `tdot_axi4.sv` (OBS-регистры/счётчики/SNAP/BUILD_ID/4KB-кламп), `xdma_ddr3_core_top.sv`
  (параметр BUILD_ID), `build_flat.tcl`/`build_dfx.tcl` (generic BUILD_ID), `xdma_driver.py`
  (TdotCore OBS-методы), добавлены `check_burst_4kb.py`, `docs/OBSERVABILITY.md`, `ADDRESS_MAP §3.4`.
- Проверки: полный xvlog-линт flat-RTL чистый; `check_burst_4kb.py` PASS; `xdma_driver.py` import OK.
- Отчёт/детали: `docs/OBSERVABILITY.md`, `docs/worklog.md` Task 2026-10-11-obs-merge.
- НЕ коммичено (по правилу — только по явному запросу).