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
set bar0size [get_property CONFIG.pf0_bar0_size [get_bd_cells xdma_0]]
set bar0scale [get_property CONFIG.pf0_bar0_scale [get_bd_cells xdma_0]]
set axil_offset [get_property CONFIG.pciebar2axibar_axil_master [get_bd_cells xdma_0]]
puts "BAR0: $bar0size $bar0scale"
puts "AXIL_OFFSET: $axil_offset"
report_bd_address -name addr_table
close_project