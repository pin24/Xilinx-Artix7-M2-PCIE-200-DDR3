# ============================================================
# Build existing XDMA+DDR3 project (BD already generated)
# Run: vivado -mode batch -source build_existing.tcl
# ============================================================
set proj_dir    C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name   m2_artix7_xdma_ddr3
set pins_xdc    C:/A7_M2/EXAMPLES/XDMA_DDR3/constraints/xdma_ddr3_pins.xdc
set early_xdc   C:/A7_M2/EXAMPLES/XDMA_DDR3/constraints/xdma_ddr3_early.xdc

open_project ${proj_dir}/${proj_name}/${proj_name}.xpr

# Ensure wrapper is top
set_property top xdma_ddr3_wrapper [current_fileset]

# Ensure constraints present
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

# ---------- Build ----------
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    puts "=== SYNTHESIS FAILED ==="
    close_project
    exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set st2 [get_property STATUS [get_runs impl_1]]
puts "=== IMPL STATUS: $st2 ==="
if {[string first "complete" [string tolower $st2]] == -1} {
    puts "=== IMPLEMENTATION FAILED ==="
    close_project
    exit 1
}

puts "=== BUILD COMPLETE ==="
puts "Bitstream: ${proj_dir}/${proj_name}/${proj_name}.runs/impl_1/xdma_ddr3_wrapper.bit"
close_project
