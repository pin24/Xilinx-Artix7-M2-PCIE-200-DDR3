# ============================================================
# XDMA + DDR3 build for M.2 Artix-7 (XC7A200T) - Vivado 2021.2
# Creates project, block design, constraints, builds bitstream
# Run: vivado -mode batch -source build_xdma_ddr3.tcl
# ============================================================
set proj_dir    C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name   m2_artix7_xdma_ddr3
set part        xc7a200tfbg484-2
set bd_script   C:/A7_M2/EXAMPLES/XDMA_DDR3/scripts/xdma_ddr3_bd.tcl
set pins_xdc    C:/A7_M2/EXAMPLES/XDMA_DDR3/constraints/xdma_ddr3_pins.xdc
set early_xdc   C:/A7_M2/EXAMPLES/XDMA_DDR3/constraints/xdma_ddr3_early.xdc

# ---------- 1. Create project ----------
file mkdir ${proj_dir}
create_project -force ${proj_name} ${proj_dir}/${proj_name} -part ${part}
set_property target_language Verilog [current_project]
set_property target_simulator XSim [current_project]

# ---------- 2. Generate block design ----------
source ${bd_script}

# ---------- 3. Generate wrapper (top) ----------
set bd_file [get_files xdma_ddr3.bd]
make_wrapper -files [get_files ${bd_file}] -top
add_files -norecurse ${proj_dir}/${proj_name}/${proj_name}.gen/sources_1/bd/xdma_ddr3/hdl/xdma_ddr3_wrapper.v
set_property top xdma_ddr3_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ---------- 4. Add constraints ----------
add_files -fileset constrs_1 ${pins_xdc} ${early_xdc}
set_property PROCESSING_ORDER EARLY [get_files ${early_xdc}]
set_property PROCESSING_ORDER NORMAL [get_files ${pins_xdc}]
update_compile_order -fileset constrs_1

# ---------- 5. Fix the PCIe IP constraint order (early must win) ----------
# reference full.tcl moves the IP-generated PCIE_X0Y0.xdc to NORMAL
set pcie_ip_xdc [get_files -all -quiet *PCIE_X0Y0.xdc]
if {$pcie_ip_xdc ne ""} {
    set_property PROCESSING_ORDER NORMAL ${pcie_ip_xdc}
    puts "=== PCIE IP xdc set to NORMAL: ${pcie_ip_xdc} ==="
}

save_project_as ${proj_dir}/${proj_name}/${proj_name}.xpr -force

# ---------- 6. Build ----------
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
