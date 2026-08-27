# Probe: синтез compute_dot_par_raw (NUM_MAC=32) отдельно - замерить реальные LUT
set proj_dir C:/A7_M2/EXAMPLES/XDMA_DDR3/scripts/core_probe
set rtl_dir   C:/A7_M2/EXAMPLES/XDMA_DDR3/rtl/block
set npar 32
file mkdir ${proj_dir}
create_project -force core_probe ${proj_dir}/proj -part xc7a200tfbg484-2
set_property top compute_dot_par_raw [current_fileset]
add_files -norecurse \
    ${rtl_dir}/tbyte_add.sv \
    ${rtl_dir}/tbyte_mul.sv \
    ${rtl_dir}/tfadd_raw.sv \
    ${rtl_dir}/tfmul_raw.sv \
    ${rtl_dir}/compute_dot_par_raw.sv
update_compile_order -fileset sources_1
set_property generic NUM_MAC=$npar [current_fileset]
launch_runs synth_1 -jobs 19
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== PROBE SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] != -1} {
    open_run synth_1
    report_utilization -file ${proj_dir}/util_probe.rpt
    report_utilization -hierarchical -file ${proj_dir}/util_probe_hier.rpt
    close_design
}
close_project
