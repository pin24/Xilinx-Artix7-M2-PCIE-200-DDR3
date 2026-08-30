#bit compress spix4 speed up
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS true [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE Yes [current_design]

#pcie reset_n input
set_property -dict {PACKAGE_PIN K22 IOSTANDARD LVCMOS33} [get_ports reset_rtl_0]

#led x3 output
set_property -dict {PACKAGE_PIN AB21 IOSTANDARD LVCMOS33} [get_ports gpio_rtl_0_tri_o[2]]
set_property -dict {PACKAGE_PIN AA20 IOSTANDARD LVCMOS33} [get_ports gpio_rtl_0_tri_o[1]]
set_property -dict {PACKAGE_PIN AB20 IOSTANDARD LVCMOS33} [get_ports gpio_rtl_0_tri_o[0]]

#pcie lanes
#референс-клок PCIe: пара MGTREFCLK1P/N_216 (P=F10, N=E10, XC7A200T-FBG484,
#банк 216 — в нём же заведены все 16 GT-ланок ниже). Пин подтверждён package-файлом
#Vivado (xc7a200t_fbg484.pkg: MGTREFCLK1P_216=F10, MGTREFCLK1N_216=E10).
#IOSTANDARD для GT-референс-клока не задаётся (определяется питанием GT-банка).
set_property PACKAGE_PIN F10 [get_ports {diff_clock_rtl_0_clk_p[0]}]
set_property PACKAGE_PIN E10 [get_ports {diff_clock_rtl_0_clk_n[0]}]

# PCIe 100 MHz reference clock (MGTREFCLK1P/N_216, F10/E10). Period 10 ns.
# FIX-6 (B-4 / P1-4): explicit create_clock silences Vivado "no_clock"
# warning — "9 register/latch pins with no clock driven by root clock pin:
# diff_clock_rtl_0_clk_p[0]" (timing_full.rpt:65). The PCIe IP derives its
# own logic clocks (clk_125mhz_x0y0, clk_250mhz_x0y0) from GTPE2 TXOUTCLK
# via MMCM; this create_clock just defines the input port clock so the
# IBUFDSGTE → GT refclk path is timed. Frequency 100 MHz confirmed by
# schematic (PCIE_CLK_P/N → R35 → F10/E10, see Schematic_A7_M2_DDR_V1.2.pdf
# sheet "06 M2_M_KEY.SchDoc"). Reference repo does NOT have this constraint
# (xdma_ddr3_pins.xdc in rigoorozco/m2-artix7-accelerator-card has only the
# PACKAGE_PIN line); main adds it as a hardening fix.
create_clock -period 10.000 -name pcie_refclk [get_ports {diff_clock_rtl_0_clk_p[0]}]

set_property PACKAGE_PIN D9 [get_ports {pcie_7x_mgt_rtl_0_rxp[3]}]
set_property PACKAGE_PIN B10 [get_ports {pcie_7x_mgt_rtl_0_rxp[2]}]
set_property PACKAGE_PIN D11 [get_ports {pcie_7x_mgt_rtl_0_rxp[1]}]
set_property PACKAGE_PIN B8 [get_ports {pcie_7x_mgt_rtl_0_rxp[0]}]
set_property PACKAGE_PIN A8 [get_ports {pcie_7x_mgt_rtl_0_rxn[0]}]
set_property PACKAGE_PIN C11 [get_ports {pcie_7x_mgt_rtl_0_rxn[1]}]
set_property PACKAGE_PIN A10 [get_ports {pcie_7x_mgt_rtl_0_rxn[2]}]
set_property PACKAGE_PIN C9 [get_ports {pcie_7x_mgt_rtl_0_rxn[3]}]
set_property PACKAGE_PIN B4 [get_ports {pcie_7x_mgt_rtl_0_txp[0]}]
set_property PACKAGE_PIN D5 [get_ports {pcie_7x_mgt_rtl_0_txp[1]}]
set_property PACKAGE_PIN B6 [get_ports {pcie_7x_mgt_rtl_0_txp[2]}]
set_property PACKAGE_PIN D7 [get_ports {pcie_7x_mgt_rtl_0_txp[3]}]
set_property PACKAGE_PIN A4 [get_ports {pcie_7x_mgt_rtl_0_txn[0]}]
set_property PACKAGE_PIN C5 [get_ports {pcie_7x_mgt_rtl_0_txn[1]}]
set_property PACKAGE_PIN A6 [get_ports {pcie_7x_mgt_rtl_0_txn[2]}]
set_property PACKAGE_PIN C7 [get_ports {pcie_7x_mgt_rtl_0_txn[3]}]

# ============================================================================
# ОТКРЫТЫЙ ВОПРОС (FIX-6 обновил): конфликты LOC GT-ланок — решён частично.
# При имплементации Vivado пишет CRITICAL WARNING о конфликте BEL/LOC на
# GTPE2_CHANNEL_X0Y4..X0Y7: IP-ограничения pcie2_ip-PCIE_X0Y0.xdc (внутри
# xdma_0, строки ~94-100) назначают lane0..lane3 в порядке X0Y7..X0Y4, а
# наш xdma_ddr3_early.xdc задаёт обратный порядок X0Y4..X0Y7.
# Доказательство — лог vivado_9916.backup.log:1138-1144 ("Cannot set LOC
# property ... bel is occupied by pipe_lane[N]").
#
# Сверка со схемой платы Schematic_A7_M2_DDR_V1.2.pdf (sheet 06 M2_M_KEY.SchDoc):
#   M.2 lane 0  → PCIE_RX0_P/N → B8/A8 → MGTPRXP0_216/N0_216 → GTPE2_CHANNEL_X0Y4
#   M.2 lane 1  → PCIE_RX1_P/N → D11/C11 → MGTPRXP1_216/N1_216 → GTPE2_CHANNEL_X0Y5
#   M.2 lane 2  → PCIE_RX2_P/N → B10/A10 → MGTPRXP2_216/N2_216 → GTPE2_CHANNEL_X0Y6
#   M.2 lane 3  → PCIE_RX3_P/N → D9/C9 → MGTPRXP3_216/N3_216 → GTPE2_CHANNEL_X0Y7
# Подтверждено timing_full.rpt:273 (lane[0] размещён на GTPE2_CHANNEL_X0Y4).
# Вывод: соответствие lane<->пин в xdma_ddr3_pins.xdc и xdma_ddr3_early.xdc
# ВЕРНО. Конфликт LOC снимается понижением PROCESSING_ORDER IP-констрейна
# pcie2_ip-PCIE_X0Y0.xdc до NORMAL — см. фикс в build_all.tcl (блок после
# synth, FIX-6 P1-4) и аналогичные блоки в build_xdma_ddr3.tcl:35-41,
# synth_with_core.tcl:49-52, build_existing.tcl:29-33, build_full_bitstream.tcl:55-58.
# ============================================================================
