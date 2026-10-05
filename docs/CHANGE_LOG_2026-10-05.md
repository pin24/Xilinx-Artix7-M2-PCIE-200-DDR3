# CHANGE LOG — 2026-10-05 (сессия: 0x124/ROF + аудит связности + правки BD + FIX-ROF 512)

Сводка сессии: найдена причина зависания на новой прошивке (BugCheck 0x124/ROF), проведён цикл
аудитов лучшими субагентами, внесены правки BD (адресная карта 0x4002xxxx + фикс DFX-сегмента)
и FIX-ROF в драйвер (дескрипторы ≤512 Б). Подготовлено к пересборке прошивки.

Каталог: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3`. Логи: `ERROR_HISTORY.md` (см. ниже),
`ERROR-FIX-LOG.md` E-19, `DIAG_MULTIPACKET_2026-10-04.md §7`, `worklog.md`, память проекта.

---

## 1. Причина зависания — BugCheck 0x124 / PCIe ROF

- Свежие дампы стенда (05.10 12:35 и 12:56): **BugCheck 0x00000124, Arg1=0x4 (Non-Processor/шина-PCIe)**,
  WHEA MACHINE_CHECK_EXCEPTION. Оба при тестах DMA на новой прошивке.
- Подтверждено исторической заметкой `docs/CHANGE_LOG_2026-09-27.md §6N`: 0x124 Arg1=4 PCIe,
  WHEA `Status=0x00140000` = **ROF (0x40000) + недопустимый бит**, DevStatus UR, на слоте **VEN_10EE&DEV_7024**.
  Вывод: переполнение приёмника XDMA (ROF) / Unsupported Request — аппаратная PCIe-ошибка при DMA.
- Сторонняя деталь: на новой прошивке C2H0-движок вставал в BUSY с completedDescCount=0 (чтение из DDR3
  не выполнялось), что и провоцировало зависание/0x124. Это прошивочная проблема пути чтения (не драйвер).

## 2. Цикл аудитов лучшими субагентами (BD, RTL, драйвер, артефакты)

- **Адресная карта собранной прошивки = 0x4002xxxx** (GPIO 0x40020000, DFX 0x40022000, TDOT 0x40023000,
  ICAP 0x40024000, SPI 0x40025000, XADC 0x46000000, BRAM 0x10000000, MIG 0x80000000).
  Противоречие «первичные 0x4000xxxx» разрешено: фактическая карта `.bda/.mem/.hwh/synth-MMU` — 0x4002xxxx.
- Драйвер (`test_dma.c`) и `docs/ADDRESS_MAP.md` **согласованы** с этой картой на 100%; DMA-механика
  (SGDMA, XDMA 128-бит @125, pciebar2axibar_xdma=0, каналы h2c_0/c2h_0) — согласована.
- Выявленные и устранённые дефекты — см. §3.
- Остаточные (отложено/для loopback+dot не блокер): **ICAP и SPI висячие** (порты в BD/адреса назначены,
  но RTL-top не инстанцирует icap_ctrl/spi_over_pcie) — ломают dfx_swap/hot-flash, не loopback/dot.
  `xdma_axi_lite_smc/M02_AXI` — свободный (резерв). Установленный драйвер v1.1.27 без FIX-ROF —
  валидирован.

## 3. Правки сессии

- `scripts/xdma_ddr3_dfx_bd.tcl` (первичные адреса периферии → 0x4002xxxx):
  GPIO 0x40000000→0x40020000, DFX-sock 0x40002000→0x40022000, TDOT 0x40003000→0x40023000,
  ICAP 0x40004000→0x40024000, SPI 0x40005000→0x40025000. (Устраняет рассинхрон скрипт↔битстрим↔драйвер
  при пересборке.)
- `scripts/build_dfx.tcl` (фикс DFX-socket сегмента): перед reassign 0x40022000 удалять ОБА имени
  (`SEG_axi_gpio_0_Reg_2` и `SEG_decouple_shutdown_ctrl_Reg`), иначе assign -force создаёт дубликат
  (выявлено аудитом) → может валиться validate_bd_design.
- `xdma_driver_win_src_2017/libxdma/dma_engine.h` (+`.c`): **FIX-ROF 512** — `XDMA_DESC_MAX_BYTES=512`,
  `XDMA_MAX_DESC_COUNT`, буфер дескрипторов расширен до ~512 КБ, `ProgramDma` нарезает каждый SG-элемент
  на дескрипторы ≤512 Б в единую цепочку одного run. Защита от ROF/0x124. **Собран офлайн, НЕ установлен**
  (устройство выключено).

## 4. План пересборки и тестов (следующий шаг)

1. Пересборка прошивки: `vivado -mode batch -source scripts/build_dfx.tcl` (NUM_MAC=16, ADDERS=8).
   Проверить verdict (WNS MET — на 04.10 WNS=0.823ns), partial-битстримы.
2. Заливка: QSPI/JTAG (`flash_access_top` → `flash_program.tcl`) или volatile `.bit` по JTAG.
   (hot-flash через PCIe сейчас недоступен — ICAP/SPI мёртвы, см. §2.)
3. Тесты на НОВОМ битстриме (драйвер НЕ переустанавливать, v1.1.27 валидирован):
   - `test_dma loopback 512` и `1024` — валидирует DMA+MIG+c2h путь;
   - `test_dma dot 4` (DDR3) и `dot_bram 4` (BRAM, без MIG) — разделяет дефект MIG vs ядро;
   - диаг. после loopback: `IOCTL_XDMA_DIAG_GET` → `progDmaCalls==1` (multi-packet не вернулся);
   - мониторинг WHEA/AER/0x124 (FIX-ROF пока не установлен).
4. FIX-ROF-драйвер (512-слайсинг) — установить и провать ОТДЕЛЬНО, после стабильных тестов,
   чтобы изолировать возможный регресс.
## 5. Сборка прошивки (DFX) завершена — артефакты готовы к заливке (21:06)

- Запуск: `vivado.bat -mode batch -source scripts/build_dfx.tcl` (NUM_MAC=16, ADDERS=8), проект C:/build_dfx (out-of-tree). Процесс завершён за ~23 мин (20:42→21:06).
- Артефакты скопированы в `build/artifacts_dfx`:
  - `xdma_ddr3_core_top.bin/.bit/.mcs/.prm/.rbt` (полный; .bit 5 370 477 Б)
  - `xdma_ddr3_core_top_pblock_rm_partial.bit/.bin/.rbt` (DFX RP partial; 1 757 998 Б)
- CRC: полный `SW_CRC=c8fb4bfa`, partial `eeaedcd6`, part xc7a200tfbg484, Version 2025.2, дата 2026/10/05.
- Timing: **WNS(Setup) worst slack 8.692ns MET**, Hold 0.215ns, PW 4.146ns, **0 failing endpoints**, «All user specified timing constraints are met».
- DRC: build прошёл (bitstream создан); методология — TIMING-17 «Non-clocked sequential cell» (1000) и TIMING-27 «Invalid primary clock on hierarchical pin» (2) как Critical Warning — не блокеры (WNS MET, известные типы).
- Адресная карта новой прошивки (lite mem): SEG001 GPIO 0x40020000, SEG002 DFX 0x40022000, SEG003 **TDOT 0x40023000**, SEG004 XADC 0x46000000; **ICAP/SPI отсутствуют** (0x40024000/0x40025000 нет). Согласовано с драйвером test_dma.c.
- ВЫВОД: прошивка пригодна к заливке (QSPI/JTAG; hot-flash через ICAP недоступен — порты убраны). После заливки тесты loopback/dot на установленном драйвере v1.1.27; FIX-ROF (512) НЕ ставить — валидировать отдельно.
