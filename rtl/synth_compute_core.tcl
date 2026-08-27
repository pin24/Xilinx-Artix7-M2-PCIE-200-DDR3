# ============================================================================
# synth_compute_core.tcl - синтез конвейерного compute_core_dot_pipe (N=16)
# ============================================================================
set proj_dir C:/A7_M2/EXAMPLES/XDMA_DDR3/rtl/synth_check
set rtl_dir   C:/A7_M2/EXAMPLES/XDMA_DDR3/rtl/rtl

file mkdir ${proj_dir}
create_project -force compute_synth ${proj_dir} -part xc7a200tfbg484-2
set_property top compute_core_dot_pipe [current_fileset]

add_files -norecurse \
    ${rtl_dir}/tfloat_pkg.sv \
    ${rtl_dir}/int_to_trits.sv \
    ${rtl_dir}/tf40_to_f32.sv \
    ${rtl_dir}/tf40_mul_pipe.sv \
    ${rtl_dir}/tf40_add_pipe.sv \
    ${rtl_dir}/f32_to_tf40_pipe2.sv \
    ${rtl_dir}/compute_core_dot_pipe.sv

update_compile_order -fileset sources_1
set_property generic N=16 [current_fileset]

launch_runs synth_1 -jobs 19
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    puts "=== SYNTHESIS FAILED ==="
} else {
    puts "=== SYNTHESIS OK ==="
    open_run synth_1
    report_utilization -file ${proj_dir}/util.rpt
    report_timing_summary -file ${proj_dir}/timing.rpt
    close_design
}
close_project
