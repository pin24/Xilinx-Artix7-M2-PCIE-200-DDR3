open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t_0] 0]
current_hw_device ${dev}
refresh_hw_device -update_hw_probes false ${dev}
puts "=== available 128M SPI x1_x2_x4 parts ==="
set parts [get_cfgmem_parts {*spi-x1_x2_x4}]
foreach p ${parts} {
    if {[string match "*128*" ${p}] || [string match "w25q128*" ${p}] || [string match "is25*128*" ${p}] || [string match "mx25l128*" ${p}]} {
        puts "  cand: ${p}"
    }
}
puts "=== try auto-detect part via identify (no explicit part) ==="
# Ask Vivado to identify the attached flash through the device boundary-scan.
catch { create_hw_cfgmem -hw_device ${dev} -auto } cfgA
puts "auto create: $cfgA"
set cfg [get_property PROGRAM.HW_CFGMEM ${dev}]
if {${cfg} ne ""} {
    puts "auto-config part: [get_property MEM_DEVICE ${cfg}]"
    set_property PROGRAM.ERASE          1 ${cfg}
    set_property PROGRAM.CFG_PROGRAM    1 ${cfg}
    set_property PROGRAM.VERIFY         1 ${cfg}
    set_property PROGRAM.FILES [list {C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3/build/artifacts_dfx/xdma_ddr3_core_top.mcs}] ${cfg}
    catch { program_hw_cfgmem -hw_cfgmem ${cfg} } err
    puts "cfgmem result: $err"
} else {
    puts "auto-detect failed to attach cfgmem"
}
puts "=== DONE ==="