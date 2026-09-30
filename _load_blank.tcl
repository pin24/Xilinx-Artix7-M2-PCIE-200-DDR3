open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t_0] 0]
current_hw_device ${dev}
refresh_hw_device -update_hw_probes false ${dev}
set_property PROGRAM.FILE {C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3/build/flash_access/flash_access.bit} ${dev}
puts "=== LOAD flash_access.bit ==="
catch { program_hw_devices -force ${dev} } prg
puts "program result: $prg"
refresh_hw_device -update_hw_probes false ${dev}
puts "=== CHECK device status (should be blank-ish, no spi_over_pcie) ==="
puts [get_property PROGRAM.IS_CAPTURE ${dev}]
puts "=== LOAD DONE ==="