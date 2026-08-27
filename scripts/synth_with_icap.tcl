# ============================================================================
# synth_with_icap.tcl — синтез проекта с ICAP + XADC
# Run: vivado -mode batch -source scripts/synth_with_icap.tcl
# ============================================================================
set proj_dir    C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name   m2_artix7_xdma_ddr3
set pins_xdc    C:/A7_M2/EXAMPLES/XDMA_DDR3/constraints/xdma_ddr3_pins.xdc
set early_xdc   C:/A7_M2/EXAMPLES/XDMA_DDR3/constraints/xdma_ddr3_early.xdc
set int_dir     C:/A7_M2/EXAMPLES/XDMA_DDR3/rtl/integration
set block_dir   C:/A7_M2/EXAMPLES/XDMA_DDR3/rtl/block
set logfile     C:/A7_M2/EXAMPLES/XDMA_DDR3/scripts/synth_with_icap.log

set NUM_MAC 32

open_project ${proj_dir}/${proj_name}/${proj_name}.xpr

reset_run synth_1 -quiet

set_property top xdma_ddr3_core_top [current_fileset]

add_files -norecurse \
    ${block_dir}/tbyte_add.sv \
    ${block_dir}/tbyte_mul.sv \
    ${block_dir}/tfadd_raw.sv \
    ${block_dir}/tfmul_raw.sv \
    ${block_dir}/compute_dot_par_raw.sv \
    ${int_dir}/tdot_axi4.sv \
    ${int_dir}/icap_ctrl.sv \
    ${int_dir}/xadc_temp.sv \
    ${int_dir}/xdma_ddr3_core_top.sv

set_property generic NUM_MAC=$NUM_MAC [current_fileset]

set cf [get_files -all -quiet xdma_ddr3_pins.xdc]
if {$cf eq ""} {
    add_files -fileset constrs_1 ${pins_xdc}
}
set ef [get_files -all -quiet xdma_ddr3_early.xdc]
if {$ef eq ""} {
    add_files -fileset constrs_1 ${early_xdc}
}
set_property PROCESSING_ORDER EARLY [get_files ${early_xdc}]
set_property PROCESSING_ORDER NORMAL [get_files ${pins_xdc}]
set pcie_ip_xdc [get_files -all -quiet *PCIE_X0Y0.xdc]
if {$pcie_ip_xdc ne ""} {
    set_property PROCESSING_ORDER NORMAL ${pcie_ip_xdc}
}

update_compile_order -fileset sources_1
update_compile_order -fileset constrs_1

set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
launch_runs synth_1 -jobs 19
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    puts "=== SYNTHESIS FAILED ==="
    close_project
    exit 1
}

open_run synth_1
report_utilization -file ${proj_dir}/scripts/util_with_icap.rpt
report_utilization -hierarchical -file ${proj_dir}/scripts/util_with_icap_hier.rpt
close_design

puts "=== SYNTHESIS OK ==="
close_project