# ============================================================================
# [DEPRECATED — легаси не-DFX потока]
# Этот разовый helper относится к старой (не-DFX) интеграции и в активный
# DFX-поток НЕ входит: пути C:/A7_M2/EXAMPLES/XDMA_DDR3 устарели, часть
# файлов (build_all.tcl, build_existing.tcl, xdma_ddr3.bd) отсутствует.
# Активная сборка: scripts/build_dfx.tcl (vivado -mode batch -source ...).
# Оставлен для истории — не использовать в новых сборках.
# ============================================================================
open_project C:/A7_M2/EXAMPLES/XDMA_DDR3/m2_artix7_xdma_ddr3/m2_artix7_xdma_ddr3.xpr
open_bd_design [get_files xdma_ddr3.bd]
set_property -dict [list CONFIG.pf0_bar0_scale {Megabytes} CONFIG.pf0_bar0_size {128}] [get_bd_cells xdma_0]
set as_lite [get_bd_addr_spaces xdma_0/M_AXI_LITE]
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_gpio_0_Reg}]
assign_bd_address -offset 0x40000000 -range 0x1000 -target_address_space \ [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_TDOT_REGS_Reg}]
assign_bd_address -offset 0x40001000 -range 0x1000 -target_address_space \ [get_bd_addr_segs S_AXI_TDOT_REGS/Reg] -force
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_ICAP_REGS_Reg}]
assign_bd_address -offset 0x40002000 -range 0x1000 -target_address_space \ [get_bd_addr_segs S_AXI_ICAP_REGS/Reg] -force
validate_bd_design
save_bd_design
puts "BD saved!"
close_project
