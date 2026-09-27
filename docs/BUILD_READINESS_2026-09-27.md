# Отчёт о готовности сборки — 2026-09-27

Проект: TFloat48 (XC7A200T, M.2 PCIe, XDMA + MIG DDR3 + DFX).
Метод: агентный аудит + повторный аудит (re-audit), чтение RTL/скриптов/логов,
без запуска Vivado. Последние коммиты: `e67a877` (фиксы HW), `1703612`
(re-audit: fileset/доки).

---

## 1. Вердикт

| Аспект | Статус |
|---|---|
| Pipeline (`build_dfx.tcl` + BD) | 🟡 **Готов к запуску** — все известные блокеры закрыты (см. §3) |
| Согласованность RTL ↔ инстанцирование | ✅ OK (icap_ctrl, spi_over_pcie, xadc_temp, xadc_prim) |
| Fileset (add_files) | ✅ OK после включения `xadc_prim.sv` |
| Dual-ICAP | ✅ устранён (axi_hwicap удалён) |
| Тайминг (WNS/TNS по всем доменам) | ⚠️ **Не верифицирован** после правок — требует прогона |
| Over-utilization LUT | ✅ `drc.disableLUTOverUtilError` не активен |
| Прошивка (firmware) | 🟡 сборка готова, прошивка не выполнялась |

**Итог: сборка готова к запуску; последний известный блокер синтеза
устранён. Единственное, что остаётся подтвердить — тайминг, и это возможно
только фактическим прогоном `build_dfx.tcl`.**

---

## 2. Проверенные факты (согласованность)

### 2.1. Карта адресов RTL ↔ BD ↔ ADDRESS_MAP

| Периферия | BD (`xdma_ddr3_dfx_bd.tcl`) | `build_dfx.tcl` (шаг 2d) | top.sv | ADDRESS_MAP §2 |
|---|---|---|---|---|
| GPIO | 0x40000000 | 0x40000000 | — | ✅ |
| DFX Socket | 0x40002000 | 0x40002000 | — | ✅ |
| TDOT regs | 0x40003000 (M03) | 0x40003000 | S_AXI_TDOT_REGS | ✅ |
| ICAP regs | 0x40004000 (M04) | 0x40004000 | S_AXI_ICAP_REGS | ✅ |
| SPI regs | 0x40005000 (M06) | 0x40005000 (добавлен) | S_AXI_SPI_REGS | ✅ |
| XADC | 0x46000000 (M05) | 0x46000000 | S_AXI_XADC_REGS | ✅ |
| DDR3 (DMA) | 0x80000000 (256 MB) | — | — | ✅ |
| HWICAP | не назначается | не назначается | отсутствует | ✅ удалён |

### 2.2. Конфигурация XDMA (FPGA)

- XDMA IP 4.2, PCIe **Gen2 x4**, AXI **Memory Mapped**, **128-bit @ 125 МГц**.
- Каналы **2 H2C + 2 C2H**; AXI-Lite master вкл. (`pciebar2axibar_axil_master = 0x40000000`).
- **BAR0 = 128 MB**; BAR2/3 = MSI-X (данных на BAR2 нет).
- Device ID `0x7024`, Vendor `0x10EE`.

---

## 3. Закрытые блокеры и дефекты (этой сессией)

| № | Область | Проблема | Фикс |
|---|---|---|---|
| F7 | **Сборка (блокер)** | `xadc_prim.sv` инстанцирован в топе (`xdma_ddr3_core_top.sv:261`), но отсутствовал в `add_files` → синтез упал бы с «cannot find module xadc_prim» | добавлен в `scripts/build_dfx.tcl` |
| F8 | build_dfx.tcl | шаг 2d пропускал SPI 0x40005000 | добавлен `assign_bd_address` |
| F9 | README.md | нет строки SPI 0x40005000 | добавлена |
| F10 | DRIVER_DEVLOG.md | HWICAP показан активным, SPI отсутствовал | исправлено |

Раньше в этой же сессии (коммит `e67a877`): ICAP-окно, SPI-протокол, XADC-wiring,
dual-ICAP, DMA-offset, timing-gate.

---

## 4. Что осталось подтвердить (только прогоном)

1. **Тайминг по всем доменам.** Последний завершённый прогон `vivado_3856.backup.log`
   (16.09, ДО правок): routed `WNS=+0.577 / TNS=0.000 / WHS=+0.036 / THS=0.000`.
   Но он исполнял старый гейт (по одному fabric-домену) и без `create_generated_clock
   icap_clk`. Новый глобальный гейт и домен icap_clk (62.5 МГц) **ни разу не исполнялись**.
   Прогон 3908/7700/`vivado.log` (19.09) оборваны на synthesis — неполные.
2. **Over-utilization LUT** при NUM_MAC=32: точная утилизация в логе не отражена
   (в .rpt). При NUM_MAC=64 ожидается возврат к ~8% over (по истории).
3. **Аппаратная верификация** после фиксов (XADC реальные значения, SPI протокол,
   ICAP swap) — не прогонялась на стенде.

---

## 5. Путь к готовности

1. Запустить `build_dfx.tcl` (NUM_MAC=32) → дождаться FATAL-гейта: `0 violations = MET`.
2. Проверить, что артефакты (`build/artifacts_dfx/*.bit/.bin/.mcs`, partial) обновились.
3. Прошивка SPI-флеша (`flash_program.tcl`) — ранее падала на `Failure to set flash
   parameters`; требуется разобраться отдельно (не блокер кода, а параметры cfgmem).
4. Аппаратные проверки: BAR0=128 MB (не 1 MB), регистры TDOT/ICAP/SPI/XADC.
5. DMA→DDR3 на Windows — **отдельный блокер драйвера** (не реализован H2C/C2H),
   см. `docs/COMPATIBILITY.md`.

---

## 6. Источники

`scripts/build_dfx.tcl`, `scripts/xdma_ddr3_dfx_bd.tcl`, `scripts/post_bd_dfx.tcl`,
`rtl/integration/{xdma_ddr3_core_top,icap_ctrl,spi_over_pcie,xadc_temp,xadc_prim}.sv`,
`docs/ADDRESS_MAP.md`, `docs/COMPATIBILITY.md`, `docs/CHANGE_LOG_2026-09-27.md`,
`vivado_3856.backup.log`, `driver/driver.c`.
