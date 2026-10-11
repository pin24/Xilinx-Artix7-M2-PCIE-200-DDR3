# PROJECT LOG — история исправлений с пометкой версии [FLAT] / [DFX]

**Рабочая версия: FLAT** (`build_flat.tcl`, `xdma_ddr3_bd.tcl`, project `C:/build_flat`,
artifacts `build/artifacts_flat`). Flat: без dfx_partition, без DFX-socket, без ICAP/SPI,
без partial bitstreams, без hot-swap. Flat default **NUM_MAC=32, ADDERS=16**.
Top-level RTL `xdma_ddr3_core_top.sv` — общий (flat-variant: нет icap/SPI).

Метки: **[FLAT]** = затрагивает flat-сборку; **[DFX]** = затрагивает DFX-сборку;
**[SHARED]** = общий RTL/хост/модель, применим обеим.

---

## 2026-10-11 — сессия аудита, исправлений и проверки прошивки

### Бэкап [FLAT]
- Коммит `ddf7710`: рабочее дерево, AUDIT_PLAN.md, `_*.tcl/_*.bat`, `.gitignore`+артефакты.
- Пуш в GitHub. Рабочая версия FLAT.

### Харнесс [SHARED]
- `e8889b0` `verify_tdot_axi4.py`: авто-детект Vivado 2025.2 (был жёсткий 2021.2) +
  добавлен отсутствующий `tfadd48.sv` в список компиляции. Харнесс прогоняет tdot_axi4+core
  (общий RTL). Применим обеим версиям.

### RTL-robustness [SHARED] → [FLAT]
- `884b5ab` `tdot_axi4.sv`: completion-статус флаги насыщения long-dot (`sat_q`) и кратности
  адреса (`align_q`); CS_RD_DATA align-guard; read-FSM AR гейтится `!fifo_full`.
  Общий RTL → действует в FLAT-сборке. Инертно для корректных входов (xsim NUM_MAC=32
  `got` не изменился).

### P1b-модель [SHARED]
- `p1b_csa_model.py`: base-3 CSA-дерево = LUT-выигрыш (180-360 таблиц, 4 уровня,
  латентность 24→4), НЕ DSP-выигрыш (DSP48 бинарный, base-81 carry не нативен).

### P3 host 6-байт packing [SHARED] → [FLAT]
- `e9b1937` `xdma_driver.py`: pack/unpack TFloat48 (−25% DDR3/PCIe), round-trip верифицирован.
  RTL-требование (burst `i*6` + word-straddle barrel) задокументировано.

### DDR3 DMA round-trip test [SHARED]
- `ddr3_roundtrip_test.py` (mock): 8-байт и 6-байт round-trip OK.

### Проверка прошивки [DFX] — НЕ flat
- Полная Vivado 2025.2 DFX-сборка NUM_MAC=16 через `build_dfx.tcl`:
  synth 0 errors, timing MET (WNS +0.425, WHS +0.009), bitstream+partials.
  ⚠️ Это [DFX]. Flat-сборка (`build_flat.tcl`) ещё НЕ проверена на этой сессии.
  Flat default NUM_MAC=32, ADDERS=16 — требует отдельного прогона.

### Ре-аудит [SHARED]
- `cc6cb98` AUDIT_PLAN.md: ре-аудит, ключные зазоры (floor-vs-round-to-nearest, P1a/P1b
  отложены, P0 MIG hw).

### Ключный незакрытый зазор [SHARED]
- Харнесс `verify_tdot_axi4.py` (seed 71) 4/4 расхождений NUM_MAC=32 в младших тритах.
  Эталон `_norm_raw_rtl` (floor) НЕ bit-accurate к round-to-nearest `tfadd_raw`. RTL проверен
  A/B по золотым векторам. Bit-accurate эталон = фундамент перед P1a/P1b RTL-rewrite.

### Address drift [FLAT]
- `xdma_driver.py` содержит ICAP 0x40024000, SPI 0x40025000, DFX-sock 0x40022000 —
  эти адреса НЕ существуют в flat BD. Хост-модули icap_load/dfx_swap/program_spi_flash
  на flat не имеют адресов. На flat релевантны только TDOT 0x40023000, GPIO 0x40020000,
  XADC 0x46000000, DDR3 0x80000000.

---

## Правила ведения лога
- Каждый коммит/правка помечается [FLAT]/[DFX]/[SHARED] в commit message и в этом логе.
- Проверка прошивки фиксируется отдельной строкой с указанием версии и NUM_MAC/ADDERS.
- Артефакты flat → `build/artifacts_flat`; DFX → `build/artifacts_dfx`.
