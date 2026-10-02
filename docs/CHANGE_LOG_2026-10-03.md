# CHANGE LOG — 2026-10-03 (сессия 02.10 ночь → 03.10)

Сводка изменений сессии: драйвер XDMA_DMA v1.1.20→v1.1.21, стабилизация стенда
(диагностика зависаний), диагностический аппарат DDR3/DMA (BRAM-обход + AXI
sniffer). Все правки закоммичены в origin/main.

Каталог: `C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3` (git), рабочая копия `-nodfx`.
Логи подробнее: `docs/ERROR_HISTORY.md`, `driver/ERROR-FIX-LOG.md`,
`driver/error-fix-log.csv`, `docs/worklog.md`, `DIAG_PLAN.md`.

---

## Коммиты сессии

| Коммит | Описание |
|---|---|
| `a9f291a` | fix(driver): v1.1.20 — guard wcscmp NULL (BSOD 0x3B), range-check BAR R/W (BSOD 0x50/0x124), enable large user BAR |
| `7e827f2` | feat(driver): v1.1.21 — optional WPP software tracing (ENABLE_WPP=1) |
| `36b6926` | feat(diag): DDR3/DMA self-test bypass — BRAM walkaround + AXI sniffer, core 16/8 default |
| `aefbd7a` | docs(logs): record 2026-10-02/03 BSOD fixes, power instability, DDR3/DMA diag |

---

## 1. Драйвер XDMA_DMA.sys

### Драйвер v1.1.20 (коммит a9f291a)
Исправления:
- **(A) BSOD 0x3B** (SYSTEM_SERVICE_EXCEPTION, c0000005) в `nt!wcscmp`:
  `EvtDeviceFileCreate` теперь явно проверяет `fileName->Buffer==NULL||Length==0`
  ДО вызова `GetDevNodeType()` (раньше `wcscmp(NULL,...)` при открытии
  `\\.\XDMA0dma` без под-имени → крах). Файл: `xdma_driver_win_src_2017/sys/file_io.c`.
- **(B) BSOD 0x50** (AV_R) / AER при out-of-range BAR-доступе:
  `ReadBarToRequest`/`WriteBarFromRequest` вызывают `ValidateBarParams`
  (offset+len < barLength) до `READ/WRITE_REGISTER_*`. Out-of-range теперь
  возвращает GLE=1, не падение.
- **(C) Большой user BAR**: BAR0 (128MB AXI-Lite) остаётся доступным как
  `\\.\XDMA0dma\user` → периферия (TDOT/GPIO/ICAP/SPI) читается с него;
  маленькие MSI-X BAR блокируются.
- Синхронизирована структура `XDMA_DMA_BAR_INFO` (ConfigBarIdx + BarLength[4]).

### Драйвер v1.1.21 (коммит 7e827f2)
- Опциональная **WPP-трассировка** (программная, в память ETW, НЕ на диск):
  включается сборкой с `ENABLE_WPP=1`; build.cmd `:do_wpp` (tracewpp +
  WppConfig\Rev1), флаг `/DWPP_ENABLED`, `WPP_INIT_TRACING` в DriverEntry;
  маркеры `FILE-CREATE enter`, `READ enter/exit` в file_io.c.
- Регистрация источника события Event Log в INF (`EventLog\System\XDMA_DMA`).

### Проверка на стенде
- Периферия читается через `\\.\XDMA0dma\user` (BAR0): TDOT MAGIC='TDOT',
  CORE_PARAMS=0x820 (32/8), ICAP='ICAP', STATUS=1.
- `\control` = 64KB config BAR — периферию НЕ достаёт (это ожидаемо).

---

## 2. Стабильность стенда (железо, не драйвер)

- Серия внезапных выключений БЕЗ дампа (6008, нет Kernel-Power 41, нет WHEA):
  19:12, 20:02, 20:14, 20:47, 21:13, 21:53, 23:11. Температуры в норме
  (CPU~28°C, GPU 35°C, диски 33–52°C). Вывод: просадка/скачок питания (БП/сеть).
- Один зафиксированный сбой **0x9C MACHINE_CHECK_EXCEPTION** (MEMORY_CORRUPTION,
  `100226-41609-01.dmp`) — аппаратный MCE, не драйвер (нет XDMA_DMA в стеке).
- Рекомендация: проверить/заменить БП, подключить через ИБП.

---

## 3. Диагностика DDR3/DMA (03.10, коммит 36b6926)

### Установленный факт
MIG/DDR3 по `0x80000000` **не отвечает**: и XDMA h2c-дескриптор, и ядро TDOT
(сам AXI4-мастер) висят в BUSY без DONE; loopback виснет. Маршрут
`xdma_axi_smc→MIG` в BD корректен (0x80000000) — значит проблема в самом
DDR3-контроллере/плате, а не в разводке.

### Что сделано (прошивка/RTL, `scripts/xdma_ddr3_dfx_bd.tcl`)
- Ядро **NUM_MAC 32→16** (ADDERS=8) во всех точках: top, compute_dot_par_raw,
  build_dfx.tcl, build_flat.tcl. Освобождает DSP48/LUT/BRAM под диагностику.
- Новый **`rtl/diag/diag_axi_sniffer.sv`**: счётчики AXI (AW/W/B, AR/R,
  RRESP/BRESP!=OKAY, stall-таймаут, последние адреса/ответы) + AXI-Lite реестр
  сравнения «ожидал/получил» (+ маркеры). Только FF/LUT, без BRAM. xvlog rc=0.
- Подключён в top через `generate DIAG_EN=1` как watch-only на tdot-мастере +
  статусах ядра (в tdot_axi4.sv добавлены diag_go/busy/done).
- **BRAM-обход 8 КБ** (`diag_bram` blk_mem_gen + `diag_bram_ctrl` axi_bram_ctrl):
  `xdma_axi_smc` NUM_MI 1→2, M01→BRAM; сегмент `0x00000000` (8 КБ) для TDOT-мастера
  и XDMA M_AXI (в дополнение к DDR3 0x80000000).
- **Хост-доступ к BRAM** через `xdma_axi_lite_smc` M02 (свободный) `@0x40006000`
  (8 КБ), через S_AXI_B — **без DMA**. Конфликтов адресов нет
  (icap=0x40004000, spi=0x40005000, xadc=0x46000000).
- `DIAG_PLAN.md` — полный план внедрения + порядок пересборки.

### Следующий шаг (требует запуска Vivado 2025.2, `C:\AMDDesignTools`)
`source scripts/build_dfx.tcl` (NUM_MAC=16, ADDERS=8, diag включён) → синтез →
.bit → прошивка → on-host: `test_dma.exe firmware` (ждём CORE_PARAMS=0x810),
обходной TDOT-тест на BRAM-адресах, чтение diag-реестра.

> **ВАЖНО**: после пересинтеза CORE_PARAMS станет **0x810** (16/8), не 0x820 —
> обновить тесты, ожидающие 32/8.

---

## 4. Архив версий драйвера

`C:\A7_M2\driver_versions\` (CHANGELOG.md):
- v1.1.17_629ed1a, v1.1.18_0a68510 — исходники (src_*.zip) для отката пересборкой.
- v1.1.20_a9f291a, v1.1.21 — бинарники (.sys+.inf+.cat+.cer) + исходники.
- Откат: pnputil delete oemXXX.inf /uninstall → add-driver выбранной версии.