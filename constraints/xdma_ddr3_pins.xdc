# ============================================================================
# xdma_ddr3_pins.xdc — констрейны платы M.2 (Artix-7 XC7A200T-FBG484)
# ============================================================================
# Используется build_dfx.tcl (PROCESSING_ORDER NORMAL).
# Содержит: bitstream config, clk50, LED, PCIe refclk pair, PCIe lanes, reset.
# ============================================================================

# --- Bitstream compression (SPI x4 fast load) ---
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS true [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE Yes [current_design]

# --- 50 MHz system clock (BD port clk50 → clk_wiz → 200 MHz for MIG) ---
# BUG-050: create_clock клока clk50 передаём BD clk_wiz (он сам создаёт
# create_clock 20ns на своём входе clk_in1). Дублирующий наш create_clock
# -name clk50 даёт CRITICAL [Constraints 18-1056] 'clk50 completely overrides
# clk50[0]' + перекрывает BD-клок. Оставляем только PACKAGE_PIN + IBUF.
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports {clk50[0]}]
set_property IBUF_LOW_PWR TRUE [get_ports {clk50[0]}]

# --- MIG IDELAYCTRL REFCLK: 200 MHz от clk200_clk_wiz ---
# NOTE: create_clock на REFCLK pin можно выполнить ТОЛЬКО после link_design
# (когда MIG IP развёрнут и pin существует). Здесь он не сработает —
# Vivado пишет CRITICAL WARNING [Vivado 12-4739] No valid object(s) found.
# Реальное создание mig_refclk выполняется в scripts/build_dfx.tcl
# в TCL.POST шага synth_1 (после link_design). См. AUDIT-02 в ERROR_HISTORY.md.

# --- Vivado 2025.2: demote REQP-123 to Warning (FP on clk_wiz MMCM CLKINSEL=VCC) ---
set_property SEVERITY {Warning} [get_drc_checks REQP-123]

# --- PCIe reset_n input ---
set_property -dict {PACKAGE_PIN K22 IOSTANDARD LVCMOS33} [get_ports reset_rtl_0]

# --- LED x3 output ---
set_property -dict {PACKAGE_PIN AB21 IOSTANDARD LVCMOS33} [get_ports gpio_rtl_0_tri_o[2]]
set_property -dict {PACKAGE_PIN AA20 IOSTANDARD LVCMOS33} [get_ports gpio_rtl_0_tri_o[1]]
set_property -dict {PACKAGE_PIN AB20 IOSTANDARD LVCMOS33} [get_ports gpio_rtl_0_tri_o[0]]

# ============================================================================
# PCIe reference clock (MGTREFCLK1P/N_216, F10/E10). 100 MHz, period 10 ns.
# IOSTANDARD for GT refclk not needed (defined by GT bank power).
# Confirmed: schematic Schematic_A7_M2_DDR_V1.2.pdf sheet "06 M2_M_KEY.SchDoc".
# ============================================================================
set_property PACKAGE_PIN F10 [get_ports {diff_clock_rtl_0_clk_p[0]}]
set_property PACKAGE_PIN E10 [get_ports {diff_clock_rtl_0_clk_n[0]}]
create_clock -period 10.000 -name pcie_refclk [get_ports {diff_clock_rtl_0_clk_p[0]}]

# ============================================================================
# PCIe lanes (4 lanes Gen2) — confirmed by schematic + timing_full.rpt:273.
# Lane 0 → GTPE2_CHANNEL_X0Y4
# Lane 1 → GTPE2_CHANNEL_X0Y5
# Lane 2 → GTPE2_CHANNEL_X0Y6
# Lane 3 → GTPE2_CHANNEL_X0Y7
# GT lane LOC в xdma_ddr3_early.xdc (PROCESSING_ORDER EARLY) понижает
# IP-generated PCIE_X0Y0.xdc до NORMAL — см. build_dfx.tcl.
# ============================================================================
# PCIe lane 0
set_property PACKAGE_PIN A8 [get_ports {pcie_7x_mgt_rtl_0_rxn[0]}]
set_property PACKAGE_PIN B8 [get_ports {pcie_7x_mgt_rtl_0_rxp[0]}]
set_property PACKAGE_PIN A4 [get_ports {pcie_7x_mgt_rtl_0_txn[0]}]
set_property PACKAGE_PIN B4 [get_ports {pcie_7x_mgt_rtl_0_txp[0]}]

# PCIe lane 1
set_property PACKAGE_PIN C11 [get_ports {pcie_7x_mgt_rtl_0_rxn[1]}]
set_property PACKAGE_PIN D11 [get_ports {pcie_7x_mgt_rtl_0_rxp[1]}]
set_property PACKAGE_PIN C5 [get_ports {pcie_7x_mgt_rtl_0_txn[1]}]
set_property PACKAGE_PIN D5 [get_ports {pcie_7x_mgt_rtl_0_txp[1]}]

# PCIe lane 2
set_property PACKAGE_PIN A10 [get_ports {pcie_7x_mgt_rtl_0_rxn[2]}]
set_property PACKAGE_PIN B10 [get_ports {pcie_7x_mgt_rtl_0_rxp[2]}]
set_property PACKAGE_PIN A6 [get_ports {pcie_7x_mgt_rtl_0_txn[2]}]
set_property PACKAGE_PIN B6 [get_ports {pcie_7x_mgt_rtl_0_txp[2]}]

# PCIe lane 3
set_property PACKAGE_PIN C9 [get_ports {pcie_7x_mgt_rtl_0_rxn[3]}]
set_property PACKAGE_PIN D9 [get_ports {pcie_7x_mgt_rtl_0_rxp[3]}]
set_property PACKAGE_PIN D7 [get_ports {pcie_7x_mgt_rtl_0_txp[3]}]
set_property PACKAGE_PIN C7 [get_ports {pcie_7x_mgt_rtl_0_txn[3]}]
