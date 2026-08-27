# ============================================================================
# gen_bitstream.tcl — полный синтез + имплементация + генерация битстримов
# Генерирует: .bit (JTAG/Flash), .bin (ICAP), .mcs (SPI Flash)
#
# Run: vivado -mode batch -source scripts/gen_bitstream.tcl
# ============================================================================
set proj_dir    C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name   m2_artix7_xdma_ddr3
set pins_xdc    C:/A7_M2/EXAMPLES/XDMA_DDR3/constraints/xdma_ddr3_pins.xdc
set early_xdc   C:/A7_M2/EXAMPLES/XDMA_DDR3/constraints/xdma_ddr3_early.xdc
set top_name    xdma_ddr3_core_top

# ---- 1. Открыть проект ----
open_project ${proj_dir}/${proj_name}/${proj_name}.xpr

set_property top ${top_name} [current_fileset]

# ---- 2. Проверить/добавить констрейнты ----
set cf [get_files -all -quiet xdma_ddr3_pins.xdc]
if {$cf eq ""} {
    add_files -fileset constrs_1 ${pins_xdc}
    set_property PROCESSING_ORDER NORMAL [get_files ${pins_xdc}]
}
set ef [get_files -all -quiet xdma_ddr3_early.xdc]
if {$ef eq ""} {
    add_files -fileset constrs_1 ${early_xdc}
}
set_property PROCESSING_ORDER EARLY [get_files ${early_xdc}]
set_property PROCESSING_ORDER NORMAL [get_files ${pins_xdc}]

# Fix PCIe IP constraint order
set pcie_ip_xdc [get_files -all -quiet *PCIE_X0Y0.xdc]
if {$pcie_ip_xdc ne ""} {
    set_property PROCESSING_ORDER NORMAL ${pcie_ip_xdc}
    puts "=== PCIE IP xdc set to NORMAL: ${pcie_ip_xdc} ==="
}

update_compile_order -fileset sources_1
update_compile_order -fileset constrs_1

# ---- 3. Синтез ----
puts "=== SYNTHESIS ==="
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    puts "=== SYNTHESIS FAILED ==="
    close_project
    exit 1
}

# ---- 4. Имплементация до write_bitstream ----
puts "=== IMPLEMENTATION ==="
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set st2 [get_property STATUS [get_runs impl_1]]
puts "=== IMPL STATUS: $st2 ==="
if {[string first "complete" [string tolower $st2]] == -1} {
    puts "=== IMPLEMENTATION FAILED ==="
    close_project
    exit 1
}

# ---- 5. Генерация .bit (JTAG/Flash) ----
puts "=== WRITE BITSTREAM (.bit) ==="
set bit_path "${proj_dir}/${proj_name}/${proj_name}.runs/impl_1/${top_name}.bit"
write_bitstream -force ${bit_path}
puts "BIT: ${bit_path}"

# ---- 6. Генерация .bin (raw для ICAP) ----
puts "=== WRITE RAW BITSTREAM (.bin) ==="
set bin_path "${proj_dir}/${proj_name}/${proj_name}.runs/impl_1/${top_name}.bin"
write_bitstream -force -raw_bitfile -bin_file -file ${bin_path}
puts "BIN (ICAP): ${bin_path}"

# ---- 7. Генерация .mcs (SPI Flash MT25QL128, 4-байт адрес) ----
puts "=== WRITE CFGMEM (.mcs) ==="
set mcs_path "${proj_dir}/${proj_name}/${proj_name}.runs/impl_1/${top_name}"
write_cfgmem -force -format mcs -size 128 -interface SPIx4 \
    -loadbit "up 0x0 ${bit_path}" \
    ${mcs_path}
puts "MCS: ${mcs_path}.mcs"

# ---- 8. Итог ----
puts "=== DONE ==="
puts "BIT  (JTAG/Flash): ${bit_path}"
puts "BIN  (ICAP):       ${bin_path}"
puts "MCS  (SPI Flash):  ${mcs_path}.mcs"
close_project