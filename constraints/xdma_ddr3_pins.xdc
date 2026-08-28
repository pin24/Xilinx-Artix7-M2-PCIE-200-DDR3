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
# ОТКРЫТЫЙ ВОПРОС: конфликты LOC GT-ланок (без схемы платы не чинится).
# При имплементации Vivado пишет CRITICAL WARNING о конфликте BEL/LOC на
# GTPE2_CHANNEL_X0Y4..X0Y7: IP-ограничения pcie2_ip-PCIE_X0Y0.xdc (внутри
# xdma_0, строки ~94-100) назначают lane0..lane3 в порядке X0Y7..X0Y4, а
# фактическая разводка платы может отличаться. Доказательство — лог
# vivado_9916.backup.log, строки 1138-1144 ("Cannot set LOC property ...
# bel is occupied by pipe_lane[N]"). Сборка при этом проходит (Vivado
# размещает по факту), но соответствие lane<->пин надо сверить со схемой
# платы M.2 и при необходимости поправить порядок pcie_7x_mgt_rtl_0_rxp/txp.
# ============================================================================
