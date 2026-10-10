connect_hw_server -url TCP:127.0.0.1:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
puts "DEVICE: [current_hw_device]"
set_property PROGRAM.FILE {C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3/build/artifacts_dfx/xdma_ddr3_core_top.bit} [current_hw_device]
puts "Program file set. Starting flash..."
program_hw_devices [current_hw_device]
puts "DONE"
exit
