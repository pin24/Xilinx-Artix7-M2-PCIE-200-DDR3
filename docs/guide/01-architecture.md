# 01. Обзор и аппаратная архитектура

## Что это
Плата-акселератор точечных произведений (`dot`) на базе Xilinx Artix-7 (xc7a200t),
PCIe x4 Gen2 через XDMA. Хост обменивается данными с DDR3 (256 МБ) через DMA-каналы,
а движок `tdot` считает scalar-произведения векторов (data·weights) для GEMM/нейросетей.

## Блок-схема data-пути (текущий, синхронный)

```
Хост (PCIe)                     FPGA
  CPU ──PCIe──► XDMA ──M_AXI(128b,125MHz)──► xdma_axi_smc ──S00
                                                │ S01 (DataMover MM2S)
                                                │ S02 (DataMover S2MM loopback)
                                                │ S03 (tdot engine)
                                                ▼
                                  M00 (100MHz, ui_clk, через aclk3)
                                                ▼
                                     axi_regslice_0 (100MHz)
                                                ▼
                                   mig_7series_0 / S_AXI (100MHz)
                                                ▼
                                              DDR3 (256МБ, 0x8000_0000..0x8FFF_FFFF)
```

- **XDMA** — IP 4.2; `M_AXI` (данные, 128-бит, 125 МГц) и `M_AXI_LITE` (регистры, AXI-Lite).
- **xdma_axi_smc** — SmartConnect-коммутатор: S00=XDMA, S01/S02=DataMover`ы (loopback),
  S03=dtdot-движок, M00=DDR(MIG), M01=diag-BRAM. **Синхронный** M00 на 100 МГц.
- **mig_7series_0** — контроллер DDR3, S_AXI на `ui_clk=100 МГц`.
- **regslice_0** — регистр-срез между SMC.M00 и MIG (на 100 МГц).
- **diag_bram** (M01) — диагностическая BRAM в обход DDR (0x1000_0000..0x1000_1FFF).
- **xdma_axi_lite_smc** — отдельный AXI-Lite-коммутатор на регистры периферии:
  GPIO(0x4002_0000), datamover-контролы, **tdot(0x4002_3000)**, XADC.

## Тактовые домены и сброс
- `clk200_clk_wiz` 50→200 МГц → MIG.
- `clk125_core_wiz` 50→125 МГц → fabric/ядро (XDMA, SMC S-стороны, datamovers).
- `mig_7series_0/ui_clk` (100 МГц) → MIG S_AXI, regslice_0, SMC aclk3 (M00).
- Сбросы: `rst_core_125M` (125 fabric), `rst_mig_7series_0_100M` (100 MIG).

## Адресная карта (кратко)
| Диапазон | Назначение |
|---|---|
| 0x4000_0000.. | AXI-Lite регистры (lite SMC) |
| 0x4002_3000 | tdot-ядро (CORE_PARAMS 0x64, MAGIC 0x68, ...) |
| 0x8000_0000..0x8FFF_FFFF | DDR3 (data SMC M00) |
| 0x1000_0000..0x1000_1FFF | diag-BRAM (data SMC M01) |

Полная карта — `docs/ADDRESS_MAP.md`.

## Как проверить живость
- `python scripts/probe_core.py` — читает MAGIC (0x54444F54='TDOT') и CORE_PARAMS
  (младшие 8 бит = NUM_MAC, следующие = ADDERS).
- `python scripts/obs_smi.py --once --interval 0.5` — дашборд наблюдаемости.
- `python scripts/obs_smi.py --clear` — сброс счётчиков (если obs-блок доступен).

## Ограничения/заметки
- MIG `ui_clk=100`; XDMA `M_AXI=125`; переход 125→100 делает SmartConnect (S00=125 → M00=100).