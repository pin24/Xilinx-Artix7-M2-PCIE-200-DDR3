set ROOT [pwd]
set OUT ${ROOT}/build/flash_access
file mkdir ${OUT}
create_project -in_memory -part xc7a200tfbg484-2
add_files -norecurse ${ROOT}/rtl/integration/flash_access_top.sv
set_property top flash_access_top [current_fileset]
read_xdc -quiet [current_fileset]
synth_design -top flash_access_top -part xc7a200tfbg484-2
create_clock -period 20.000 -name clk50 [get_ports clk50]
opt_design
place_design
route_design
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
write_bitstream -force ${OUT}/flash_access.bit
close_project
puts "=== FLASH_ACCESS BUILD DONE: ${OUT}/flash_access.bit ==="