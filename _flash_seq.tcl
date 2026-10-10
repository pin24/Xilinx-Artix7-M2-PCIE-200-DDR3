open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t_0] 0]
current_hw_device ${dev}
refresh_hw_device -update_hw_probes false ${dev}

# Step 1: (re)program the FPGA with the .bit to reset config and free flash pins.
set_property PROGRAM.FILE {C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3/build/artifacts_dfx/xdma_ddr3_core_top.bit} ${dev}
puts "=== program_hw_devices (reset config) ==="
catch { program_hw_devices ${dev} } prg
puts "program_devices: $prg"
refresh_hw_device -update_hw_probes false ${dev}

# Step 2: flash the .mcs
set CFGPART [lindex [get_cfgmem_parts {w25q128jvq-spi-x1_x2_x4}] 0]
create_hw_cfgmem -hw_device ${dev} ${CFGPART}
set cfg [get_property PROGRAM.HW_CFGMEM ${dev}]
set_property PROGRAM.ERASE 1 ${cfg}
set_property PROGRAM.CFG_PROGRAM 1 ${cfg}
set_property PROGRAM.VERIFY 1 ${cfg}
set_property PROGRAM.FILES [list {C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3/build/artifacts_dfx/xdma_ddr3_core_top.mcs}] ${cfg}
puts "=== program_hw_cfgmem ==="
catch { program_hw_cfgmem -hw_cfgmem ${cfg} } err
puts "cfgmem: $err"
puts "=== FULLSEQ DONE ==="