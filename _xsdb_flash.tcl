connect
puts "=== TARGETS ==="
targets
puts "=== SELECT ==="
targets -set 2
puts "=== PROGRAMMING bitstream ==="
fpga -file C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3/build/artifacts_dfx/xdma_ddr3_core_top.bit
puts "=== DONE ==="
exit
