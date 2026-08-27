set proj_dir  C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name m2_artix7_xdma_ddr3
open_project ${proj_dir}/${proj_name}/${proj_name}.xpr
set bd [get_files xdma_ddr3.bd]
open_bd_design $bd
puts "=== axi_smc pins ==="
puts [get_bd_pins -quiet axi_smc/aclk*]
puts "=== NUM_CLKS ==="
puts [get_property CONFIG.NUM_CLKS [get_bd_cells axi_smc]]
puts "=== S02 intf ==="
puts [get_bd_intf_pins -quiet axi_smc/S02_AXI]
close_project
