# Диагностика DDR3/DMA — план внедрения (проект 2026-10-03)

Цель: проверить обходным путём (без рабочего DMA-мастера к MIG) работу ядер
TDOT и доступность DDR3, плюс получить инструменты, чтобы однозначно
сопоставить «что ожидали / что получили» между модулями прошивки.

## Контекст / установленный факт
- В текущей DFX-прошивке MIG/DDR3 по `0x80000000` НЕ отвечает: и XDMA-дескриптор
  (h2c→DDR3), и ядро TDOT (сам AXI4-мастер→DDR3) «виснут» в BUSY/без DONE.
- Маршрут `xdma M_AXI / tdot M_AXI → xdma_axi_smc → mig@0x80000000` в BD прописан
  корректно (scripts/xdma_ddr3_dfx_bd.tcl:754/759/832/851-854). Значит дело в
  самом DDR3-контроллере/плате, а не в разводке.
- Ядро `tdot_axi4.sv` умеет читать данные и из BRAM по `0x00000000..0x1FFF`
  (заголовок модуля) — это ключ к обходу БЕЗ DDR3.

## Что уже сделано (RTL + инкремент сборки)
1. Ядро снижено с default **NUM_MAC=32→16** (ADDERS=8) во всех точках:
   - `rtl/integration/xdma_ddr3_core_top.sv` (def. 16/8)
   - `rtl/block/compute_dot_par_raw.sv` (def. 16/8)
   - `scripts/build_dfx.tcl` (set NUM_MAC 16, ADDERS 8)
   - `scripts/build_flat.tcl` (set NUM_MAC 16, ADDERS 8)
   Освобождает ~16 DSP48 + регистры/BRAM для диагностики.
   Важно: CORE_PARAMS после пересинтеза станет `0x00000810` (16/8), не `0x820`.
2. Новый RTL `rtl/diag/diag_axi_sniffer.sv` (компилируется, xvlog rc=0):
   - счётчики AXI транзакций (AW/W/B, AR/R), RRESP/BRESP != OKAY,
     stall-таймаут, последние адреса/ответы;
   - AXI-Lite slave-реестр (сравнение «ожидал/получил», маркеры, статусы);
   - без BRAM (только флип-флопы/LUT), параметричен.
3. Подключён в top `rtl/integration/xdma_ddr3_core_top.sv` через `generate DIAG_EN=1`
   как watch-only на шине tdot-мастера (m_axi_*) + статусы ядра
   (tdot_go/busy/done, выведены из tdot_axi4.sv новыми портами diag_*).
4. Включён в оба build-скрипта (build_dfx.tcl / build_flat.tcl).

## Что осталось (необходимо для полной диагностики) — правки в BD
**РЕАЛИЗОВАНО (2026-10-03, xdma_ddr3_dfx_bd.tcl):**
- Шаг A (BRAM-обход): `diag_bram_ctrl` (axi_bram_ctrl 4.1, **SINGLE_PORT=true,
  INTERNAL** — сам генерит blk_mem_gen корректной версии); xdma_axi_smc
  NUM_MI 1→2, M01→diag_bram_ctrl/S_AXI; сегменты BRAM `0x00000000` (8 КБ) для
  TDOT-мастера и XDMA M_AXI (в дополнение к DDR3 0x80000000).
- Шаг B (доступ хоста к BRAM): через **XDMA M_AXI (S00)→smc→M01→S_AXI** обычным
  DMA на адрес 0x00000000. AXI-Lite порт B НЕ используется (axi_bram_ctrl v4.1
  не даёт разных протоколов A/B; SINGLE_PORT=true). Адрес 0x40006000 не занят.
- Шаг C (сниффер на M00→MIG): в RTL-top уже watch-only на tdot-мастер (m_axi_* =
  тот же путь к MIG). Для различения DMA-каналов отдельный сниффер на M00
  требует module-ref в BD — отложено, не критично для проверки основной гипотезы.

### Ошибка сборки, которую УЖЕ устранили (03.10, повторный запуск)
- `ERROR: VLNV <xilinx.com:ip:blk_mem_gen:8.3> is not supported for the current
  part. The latest supported version is <8.4>` — ручной blk_mem_gen 8.3 не
  поддерживается на xc7a200t в Vivado 2025.2. РЕШЕНО: ручной blk_mem_gen убран;
  axi_bram_ctrl в INTERNAL сам создаёт BRAM. (закоммичено отдельным коммитом)

### Для доступа хоста к diag_axi_sniffer регистрам (чить счётчики)
- Пока s_axi_* сниффера в top не подключены (watch-only). Чтобы хост читал
  счётчики, добавить S_AXI_DIAG порт → xdma_axi_lite_smc (свободный M-порт) на
  адрес 0x40007000 и связать с s_axi_* u_diag. (Опционально, следующий шаг.)

## Порядок пересборки (Vivado 2025.2, C:\AMDDesignTools)
1. `xvlog -sv` по изменённым файлам (diag_axi_sniffer.sv, tdot_axi4.sv) — rc=0 уже.
2. Применить правки BD (Шаги A/B, при необходимости C).
3. `source scripts/build_dfx.tcl` (или build_flat.tcl) — NUM_MAC=16/ADDERS=8,
   diag_axi_sniffer в fileset.
4. Синтез + реализация → .bit/.bin → прошить (как раньше, GUI/скрипты).
5. Прогнать on-host:
   - `test_dma.exe firmware` → ждём CORE_PARAMS=0x810 (16/8), MAGIC 'TDOT'.
   - Обходной TDOT test на BRAM-адресах.
   - читать diag-реестр через CtlRead32.

## Риски / замечания
- Сниффер включён DIAG_EN=1; для продакшена переключается на 0 (модуль
  остаётся в файле, не используется).
- BRAM-обход добавляет ~8 KB BRAM (2×BRAM36) + axi_bram_ctrl (неск. LUT/FIFO) —
  при NUM_MAC=16 запас в 365 BRAM36 достаточно велик.
- После пересинтеза CORE_PARAMS поменяется 0x820→0x810 (16 MAC). Драйверные
  тесты, ожидающие 0x820, надо обновить или передавать NUM_MAC=32 явно в сборке
  (всегда можно собрать 32/8, а diag-модуль по-прежнему влезет — он мал).