open_project C:/A7_M2/EXAMPLES/XDMA_DDR3/m2_artix7_xdma_ddr3/m2_artix7_xdma_ddr3.xpr
open_run impl_1
set d C:/A7_M2/EXAMPLES/XDMA_DDR3/m2_artix7_xdma_ddr3/m2_artix7_xdma_ddr3.runs/impl_1
set top xdma_ddr3_core_top
write_bitstream -force -raw_bitfile -bin_file ${d}/${top}.bit
write_cfgmem -force -format mcs -size 128 -interface SPIx4 -loadbit "up 0x0 ${d}/${top}.bit" ${d}/${top}
puts "BIN: ${d}/${top}.bin"
puts "MCS: ${d}/${top}.mcs"
close_project