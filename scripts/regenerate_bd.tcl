# regenerate BD wrapper + IP outputs
set proj_dir  C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name m2_artix7_xdma_ddr3
open_project ${proj_dir}/${proj_name}/${proj_name}.xpr
set bd [get_files xdma_ddr3.bd]
open_bd_design $bd
generate_target all [get_files xdma_ddr3.bd]
make_wrapper -files [get_files xdma_ddr3.bd] -top
puts "=== BD outputs regenerated ==="
close_project
