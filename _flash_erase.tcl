open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t_0] 0]
current_hw_device ${dev}
refresh_hw_device -update_hw_probes false ${dev}
set CFGPART [lindex [get_cfgmem_parts {w25q128jvq-spi-x1_x2_x4}] 0]
create_hw_cfgmem -hw_device ${dev} ${CFGPART}
set cfg [get_property PROGRAM.HW_CFGMEM ${dev}]
set_property PROGRAM.ERASE 1 ${cfg}
set_property PROGRAM.CFG_PROGRAM 1 ${cfg}
set_property PROGRAM.VERIFY 1 ${cfg}
set_property PROGRAM.FILES [list {C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3/build/artifacts_dfx/xdma_ddr3_core_top.mcs}] ${cfg}
puts "=== try BLANK_CHECK only (no program) ==="
set_property PROGRAM.BLANK_CHECK 0 ${cfg}
set_property PROGRAM.CFG_PROGRAM 0 ${cfg}
set_property PROGRAM.VERIFY 0 ${cfg}
catch { program_hw_cfgmem -force -hw_cfgmem ${cfg} } e1
puts "erase-result: $e1"
close_hw_target
close_hw_manager
puts "=== DONE ==="