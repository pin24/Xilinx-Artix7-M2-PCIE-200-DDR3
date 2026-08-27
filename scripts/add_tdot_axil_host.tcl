# ============================================================================
# add_tdot_axil_host.tcl - доступ хоста к AXI-Lite регистрам tdot_axi4
# XDMA M_AXI_LITE -> axi_periph (NUM_MI 1->2) -> M01_AXI -> внешний порт
# S_AXI_TDOT_REGS -> tdot_axi4 S_AXI. Адрес 0x44000000.
# ============================================================================
set proj_dir  C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name m2_artix7_xdma_ddr3

open_project ${proj_dir}/${proj_name}/${proj_name}.xpr
set bd [get_files xdma_ddr3.bd]
open_bd_design $bd

# ---- axi_periph: 2 мастера ----
set_property -dict [list CONFIG.NUM_MI 2] [get_bd_cells xdma_0_axi_periph]

# ---- внешний порт для регистров tdot_axi4 (Master: к нему подключается S_AXI) ----
set exist [get_bd_intf_ports -quiet S_AXI_TDOT_REGS]
if {$exist eq ""} {
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_TDOT_REGS
}
set_property -dict [list \
    CONFIG.PROTOCOL AXI4LITE \
    CONFIG.DATA_WIDTH 32 \
    CONFIG.ADDR_WIDTH 8 \
    CONFIG.FREQ_HZ 125000000 \
] [get_bd_intf_ports S_AXI_TDOT_REGS]

# ---- подключаем M01_AXI к внешнему порту ----
connect_bd_intf_net [get_bd_intf_pins xdma_0_axi_periph/M01_AXI] [get_bd_intf_ports S_AXI_TDOT_REGS]

# ---- часы/сброс M01 ----
connect_bd_net [get_bd_pins xdma_0_axi_periph/M01_ACLK]    [get_bd_pins xdma_0/axi_aclk]
connect_bd_net [get_bd_pins xdma_0_axi_periph/M01_ARESETN] [get_bd_pins xdma_0/axi_aresetn]

# ---- адрес: 0x44000000 (после axi_gpio 0x40000000) ----
set addr_space [get_bd_addr_spaces xdma_0/M_AXI_LITE]
assign_bd_address -offset 0x44000000 -range 0x1000 \
    -target_address_space $addr_space \
    [get_bd_addr_segs S_AXI_TDOT_REGS/Reg] -force

validate_bd_design
save_bd_design
regenerate_bd_layout

puts "=== S_AXI_TDOT_REGS -> axi_periph/M01 (0x44000000) ==="
close_project
