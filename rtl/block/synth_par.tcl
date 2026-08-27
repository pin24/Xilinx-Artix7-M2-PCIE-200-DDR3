# ============================================================================
# synth_par.tcl - синтез параллельного compute_dot_par (NUM_MAC)
# ============================================================================
set proj_dir C:/A7_M2/EXAMPLES/XDMA_DDR3/rtl/block/synth_check
set rtl_dir   C:/A7_M2/EXAMPLES/XDMA_DDR3/rtl/block
set npar 16

file mkdir ${proj_dir}
create_project -force par_synth ${proj_dir} -part xc7a200tfbg484-2
set_property top compute_dot_par [current_fileset]

add_files -norecurse \
    ${rtl_dir}/tbyte_add.sv \
    ${rtl_dir}/tbyte_mul.sv \
    ${rtl_dir}/tfmac.sv \
    ${rtl_dir}/tfmul.sv \
    ${rtl_dir}/compute_dot_par.sv

update_compile_order -fileset sources_1
set_property generic NUM_MAC=$npar [current_fileset]

launch_runs synth_1 -jobs 19
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    puts "=== SYNTHESIS FAILED ==="
} else {
    puts "=== SYNTHESIS OK ==="
    open_run synth_1
    report_utilization -file ${proj_dir}/util_par${npar}.rpt
    report_timing_summary -file ${proj_dir}/timing_par${npar}.rpt
    close_design
}
close_project
