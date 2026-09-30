open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t_0] 0]
if {${dev} eq ""} { puts "ERROR: xc7a200t_0 not found"; exit 1 }
current_hw_device ${dev}
refresh_hw_device -update_hw_probes false ${dev}

# STEP 1: load a MINIMAL bitstream that does NOT claim the QSPI flash pins
# (flash_access_top), so the configuration controller regains access to flash.
# Without this, the running spi_over_pcie design holds FCS_B/D00-D03 -> 27-3347.
set_property PROGRAM.FILE {C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3/build/flash_access/flash_access.bit} ${dev}
puts "=== program_hw_devices (load flash_access) ==="
catch { program_hw_devices ${dev} } prg
puts "program result: $prg"
refresh_hw_device -update_hw_probes false ${dev}

# STEP 2: program SPI flash with the full design .mcs
set CFGPART [lindex [get_cfgmem_parts {w25q128jvq-spi-x1_x2_x4}] 0]
if {${CFGPART} eq ""} { set CFGPART [lindex [get_cfgmem_parts {w25q128jvm-spi-x1_x2_x4}] 0] }
if {${CFGPART} eq ""} { puts "ERROR: no w25q128 part"; exit 1 }
puts "CFGPART = ${CFGPART}"
catch { delete_hw_cfgmem -quiet [get_property PROGRAM.HW_CFGMEM ${dev}] } del
create_hw_cfgmem -hw_device ${dev} ${CFGPART}
set cfg [get_property PROGRAM.HW_CFGMEM ${dev}]
set_property PROGRAM.ERASE          1 ${cfg}
set_property PROGRAM.CFG_PROGRAM    1 ${cfg}
set_property PROGRAM.VERIFY         1 ${cfg}
set_property PROGRAM.FILES [list {C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3/build/artifacts_dfx/xdma_ddr3_core_top.mcs}] ${cfg}
puts "=== program_hw_cfgmem ==="
catch { program_hw_cfgmem -hw_cfgmem ${cfg} } err
puts "cfgmem result: $err"
puts "=== FLASH DONE ==="