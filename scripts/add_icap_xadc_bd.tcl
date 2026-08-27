# ============================================================================
# add_icap_xadc_bd.tcl — расширение axi_periph 2->4 мастера:
#   M00 -> axi_gpio   (0x4000_0000, уже есть)
#   M01 -> TDOT_REGS  (0x4400_0000, уже есть)
#   M02 -> S_AXI_XADC (0x4500_0000, новый)
#   M03 -> S_AXI_ICAP (0x4600_0000, новый)
# ICAP-контроллер больше не требует M_AXI (пишет напрямую от хоста),
# поэтому axi_smc не расширяется.
# Run: vivado -mode batch -source scripts/add_icap_xadc_bd.tcl
# ============================================================================
set proj_dir  C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name m2_artix7_xdma_ddr3

open_project ${proj_dir}/${proj_name}/${proj_name}.xpr
set bd [get_files xdma_ddr3.bd]
open_bd_design $bd

# ----- axi_periph: 4 мастера -----
set_property -dict [list CONFIG.NUM_MI 4] [get_bd_cells xdma_0_axi_periph]

# ----- S_AXI_XADC (Master, наружу -> xadc_temp.S_AXI) -----
set exist [get_bd_intf_ports -quiet S_AXI_XADC_REGS]
if {$exist eq ""} {
    create_bd_intf_port -mode Master \
        -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_XADC_REGS
}
set_property -dict [list \
    CONFIG.PROTOCOL AXI4LITE \
    CONFIG.DATA_WIDTH 32 \
    CONFIG.ADDR_WIDTH 8 \
    CONFIG.FREQ_HZ 125000000] [get_bd_intf_ports S_AXI_XADC_REGS]
connect_bd_intf_net [get_bd_intf_pins xdma_0_axi_periph/M02_AXI] \
    [get_bd_intf_ports S_AXI_XADC_REGS]

# ----- S_AXI_ICAP (Master, наружу -> icap_ctrl.S_AXI) -----
set exist [get_bd_intf_ports -quiet S_AXI_ICAP_REGS]
if {$exist eq ""} {
    create_bd_intf_port -mode Master \
        -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_ICAP_REGS
}
set_property -dict [list \
    CONFIG.PROTOCOL AXI4LITE \
    CONFIG.DATA_WIDTH 32 \
    CONFIG.ADDR_WIDTH 8 \
    CONFIG.FREQ_HZ 125000000] [get_bd_intf_ports S_AXI_ICAP_REGS]
connect_bd_intf_net [get_bd_intf_pins xdma_0_axi_periph/M03_AXI] \
    [get_bd_intf_ports S_AXI_ICAP_REGS]

# ----- часы/сброс M02/M03 -----
connect_bd_net [get_bd_pins xdma_0_axi_periph/M02_ACLK] \
    [get_bd_pins xdma_0/axi_aclk]
connect_bd_net [get_bd_pins xdma_0_axi_periph/M02_ARESETN] \
    [get_bd_pins xdma_0/axi_aresetn]
connect_bd_net [get_bd_pins xdma_0_axi_periph/M03_ACLK] \
    [get_bd_pins xdma_0/axi_aclk]
connect_bd_net [get_bd_pins xdma_0_axi_periph/M03_ARESETN] \
    [get_bd_pins xdma_0/axi_aresetn]

# ----- ASSOCIATED_BUSIF для axi_aclk -----
set old [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins xdma_0/axi_aclk]]
if {[string first "S_AXI_XADC_REGS" $old] == -1} {
    set new [string trim "$old S_AXI_XADC_REGS"]
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF $new] \
        [get_bd_pins xdma_0/axi_aclk]
}
if {[string first "S_AXI_ICAP_REGS" $old] == -1} {
    set new [string trim "$old S_AXI_ICAP_REGS"]
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF $new] \
        [get_bd_pins xdma_0/axi_aclk]
}

# ----- адреса -----
set as_lite [get_bd_addr_spaces xdma_0/M_AXI_LITE]
assign_bd_address -offset 0x45000000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs S_AXI_XADC_REGS/Reg] -force
assign_bd_address -offset 0x46000000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs S_AXI_ICAP_REGS/Reg] -force

validate_bd_design
save_bd_design
regenerate_bd_layout

puts "=== BD: XADC 0x4500_0000, ICAP 0x4600_0000 ==="
close_project