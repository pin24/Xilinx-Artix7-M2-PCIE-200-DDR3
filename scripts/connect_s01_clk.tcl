# ============================================================================
# [DEPRECATED — легаси не-DFX потока]
# Этот разовый helper относится к старой (не-DFX) интеграции и в активный
# DFX-поток НЕ входит: пути C:/A7_M2/EXAMPLES/XDMA_DDR3 устарели, часть
# файлов (build_all.tcl, build_existing.tcl, xdma_ddr3.bd) отсутствует.
# Активная сборка: scripts/build_dfx.tcl (vivado -mode batch -source ...).
# Оставлен для истории — не использовать в новых сборках.
# ============================================================================
# connect S01_ACLK: NUM_CLKS 2->3, S01_ACLK/S01_ARESETN -> 125MHz axi clock
set proj_dir  C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name m2_artix7_xdma_ddr3
open_project ${proj_dir}/${proj_name}/${proj_name}.xpr
set bd [get_files xdma_ddr3.bd]
open_bd_design $bd
set_property -dict [list CONFIG.NUM_CLKS 3] [get_bd_cells axi_smc]
connect_bd_net [get_bd_pins axi_smc/S01_ACLK]    [get_bd_pins xdma_0/axi_aclk]
connect_bd_net [get_bd_pins axi_smc/S01_ARESETN] [get_bd_pins xdma_0/axi_aresetn]
validate_bd_design
save_bd_design
puts "=== S01_ACLK connected (NUM_CLKS=3) ==="
close_project
