open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t_0] 0]
current_hw_device ${dev}
refresh_hw_device -update_hw_probes false ${dev}
set CFGPART [lindex [get_cfgmem_parts {w25q128jvq-spi-x1_x2_x4}] 0]
puts "CFGPART='${CFGPART}'"
create_hw_cfgmem -hw_device ${dev} ${CFGPART}
puts "create OK"
set cfg [get_property PROGRAM.HW_CFGMEM ${dev}]
puts "cfg='${cfg}'"
puts "--- all PROGRAM props of part ---"
puts [report_property -all ${cfg}]
puts "--- set props minimal ---"
set_property PROGRAM.ERASE 1 ${cfg}
set_property PROGRAM.UNPROTECT 1 ${cfg}   # FIX-SPI-LOCK 2026-10-20: снять BP-биты защиты чипа (27-3347)
set_property PROGRAM.CFG_PROGRAM 1 ${cfg}
set_property PROGRAM.VERIFY 1 ${cfg}
set_property PROGRAM.ADDRESS_RANGE {use_file} ${cfg}
set_property PROGRAM.FILES [list {C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3/build/artifacts_flat/xdma_ddr3_core_top.mcs}] ${cfg}
puts "props set, FILES set"
puts "--- DRP identify ---"
catch { identify_hw_cfgmem ${cfg} } idres
puts "identify result: $idres"
puts "=== SEQ DONE ==="