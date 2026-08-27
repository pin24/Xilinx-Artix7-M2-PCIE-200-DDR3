set rtl_dir C:/A7_M2/EXAMPLES/XDMA_DDR3/rtl/block
set proj_dir C:/A7_M2/EXAMPLES/XDMA_DDR3/rtl/block/synth_check
file mkdir ${proj_dir}
create_project -force add_synth ${proj_dir} -part xc7a200tfbg484-2
set_property top tbyte_add [current_fileset]
add_files -norecurse ${rtl_dir}/tbyte_add.sv
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 19
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] != -1} {
    open_run synth_1
    report_utilization -file ${proj_dir}/util_tbyte_add.rpt
    close_design
}
close_project
