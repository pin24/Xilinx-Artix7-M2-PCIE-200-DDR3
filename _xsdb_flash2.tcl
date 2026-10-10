connect
puts "=== TARGETS ==="
targets
puts "=== FILTER ==="
set fpga_tgt [lindex [targets -filter {name =~ "*xc7a200t*"}] 0]
puts "FPGA target: $fpga_tgt"
targets $fpga_tgt
puts "=== PROGRAMMING ==="
fpga -file "C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3/build/artifacts_dfx/xdma_ddr3_core_top.bit"
puts "=== DONE ==="
exit
