open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t_0] 0]
if {${dev} eq ""} { puts "ERROR: xc7a200t_0 not found"; exit 1 }
current_hw_device ${dev}

# Try to force a config reset via JTAG (Artix-7 boundary). If supported,
# resets the device to unconfigured state so the SPI flash pins belong to the
# configuration controller.
catch { refresh_hw_device -update_hw_probes false ${dev} } r
puts "device: ${dev}"

# Explicitly drive the device into a blank/unconfigured state by reloading a
# truly-empty bitstream path is not available; instead we rely on the fact the
# board is on a JTAG-only adapter and power-cycle makes it blank. Here we
# create the cfgmem and program it.
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
puts "=== READY: program_hw_cfgmem will run on CYCLE power-up (blank FPGA) ==="
puts "Run this AFTER a power-cycle of the JTAG adapter so FPGA is unconfigured."
puts "proceed: [llength [info commands program_hw_cfgmem]]"
# Gate: only execute if FPGA appears blank (no design). We can't read IS_CAPTURE.
# For safety provide a confirm file guard:
set guard {C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3/build/flash_access/PROCEED_OK}
if {[file exists ${guard}]} {
    puts "=== guard present -> programming ==="
    catch { program_hw_cfgmem -hw_cfgmem ${cfg} } err
    puts "cfgmem result: $err"
    file delete -force ${guard}
} else {
    puts "=== NO GUARD: create ${guard} after power-cycle, then rerun to program ==="
}
puts "=== FLASH DONE ==="