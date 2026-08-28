# ============================================================================
# build_all.tcl — ПОЛНАЯ СБОРКА (без generate_target — сохраняет XDMA IP)
# ============================================================================
set proj_dir    C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name   m2_artix7_xdma_ddr3
set pins_xdc    C:/A7_M2/EXAMPLES/XDMA_DDR3/constraints/xdma_ddr3_pins.xdc
set early_xdc   C:/A7_M2/EXAMPLES/XDMA_DDR3/constraints/xdma_ddr3_early.xdc
set int_dir     C:/A7_M2/EXAMPLES/XDMA_DDR3/rtl/integration
set block_dir   C:/A7_M2/EXAMPLES/XDMA_DDR3/rtl/block
set top_name    xdma_ddr3_core_top
set NUM_MAC     32

puts "=== 1. OPEN PROJECT ==="
open_project ${proj_dir}/${proj_name}/${proj_name}.xpr
set_property top ${top_name} [current_fileset]

puts "=== 2. ADD RTL FILES ==="
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

puts "=== 3. CONSTRAINTS ==="
set cf [get_files -all -quiet xdma_ddr3_pins.xdc]
if {$cf eq ""} { add_files -fileset constrs_1 ${pins_xdc} }
set ef [get_files -all -quiet xdma_ddr3_early.xdc]
if {$ef eq ""} { add_files -fileset constrs_1 ${early_xdc} }
set_property PROCESSING_ORDER EARLY [get_files ${early_xdc}]
set_property PROCESSING_ORDER NORMAL [get_files ${pins_xdc}]

puts "=== 4. SET BAR0 128MB ==="
open_bd_design [get_files xdma_ddr3.bd]
set_property -dict [list \
    CONFIG.pf0_bar0_scale {Megabytes} \
    CONFIG.pf0_bar0_size {128} \
] [get_bd_cells xdma_0]

puts "=== 5. SET ADDRESSES ==="
set_property -dict [list CONFIG.C_S_AXI_ADDR_WIDTH 12] [get_bd_cells axi_gpio_0]
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_gpio_0_Reg}]
assign_bd_address -offset 0x40000000 -range 0x1000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force

delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_TDOT_REGS_Reg}]
assign_bd_address -offset 0x40001000 -range 0x1000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs S_AXI_TDOT_REGS/Reg] -force

set icap_port [get_bd_intf_ports -quiet S_AXI_ICAP_REGS]
if {$icap_port eq ""} {
    set_property -dict [list CONFIG.NUM_MI 3] [get_bd_cells xdma_0_axi_periph]
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_ICAP_REGS
    set_property -dict [list CONFIG.PROTOCOL AXI4LITE CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 8 CONFIG.FREQ_HZ 125000000] [get_bd_intf_ports S_AXI_ICAP_REGS]
    connect_bd_intf_net [get_bd_intf_pins xdma_0_axi_periph/M02_AXI] [get_bd_intf_ports S_AXI_ICAP_REGS]
    connect_bd_net [get_bd_pins xdma_0_axi_periph/M02_ACLK] [get_bd_pins xdma_0/axi_aclk]
    connect_bd_net [get_bd_pins xdma_0_axi_periph/M02_ARESETN] [get_bd_pins xdma_0/axi_aresetn]
}
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_ICAP_REGS_Reg}]
assign_bd_address -offset 0x40002000 -range 0x1000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs S_AXI_ICAP_REGS/Reg] -force

validate_bd_design
save_bd_design
puts "=== BD: GPIO 0x40000000, TDOT 0x40001000, ICAP 0x40002000 ==="

puts "=== 6. EXPORT CLOCK FROM BD (axi_aclk_out / axi_aresetn_out / axi_aclk_in) ==="
# идемпотентно: создаёт/подключает порты, если их ещё нет; BD уже открыт и сохранён
source ${proj_dir}/scripts/fix_bd_clock_export.tcl

puts "=== 7. REGENERATE WRAPPER (preserve IP cores) ==="
make_wrapper -files [get_files xdma_ddr3.bd] -top -force
update_compile_order -fileset sources_1
update_compile_order -fileset constrs_1

puts "=== 8. RESET RUNS ==="
# NOTE: каталоги runs/synth_1 и runs/impl_1 руками НЕ удалять — после
# file delete -force Vivado падал с "Run synth_1 needs to be reset before
# launching" (см. build/vivado_build.log:121). Достаточно reset_run.
reset_run synth_1 -quiet
reset_run impl_1 -quiet

puts "=== 9. SYNTHESIS ==="
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
launch_runs synth_1 -jobs 19
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    puts "=== SYNTHESIS FAILED ==="
    close_project; exit 1
}

puts "=== 10. IMPLEMENTATION + BITSTREAM ==="
launch_runs impl_1 -to_step write_bitstream -jobs 19
wait_on_run impl_1
set st2 [get_property STATUS [get_runs impl_1]]
puts "=== IMPL STATUS: $st2 ==="
if {[string first "complete" [string tolower $st2]] == -1} {
    puts "=== IMPLEMENTATION FAILED ==="
    close_project; exit 1
}

puts "=== 11. WRITE BITSTREAMS ==="
open_run impl_1
set bit_path "${proj_dir}/${proj_name}/${proj_name}.runs/impl_1/${top_name}.bit"
set bin_path "${proj_dir}/${proj_name}/${proj_name}.runs/impl_1/${top_name}.bin"
set mcs_path "${proj_dir}/${proj_name}/${proj_name}.runs/impl_1/${top_name}"
write_bitstream -force -raw_bitfile -bin_file ${bit_path}
write_cfgmem -force -format mcs -size 128 -interface SPIx4 -loadbit "up 0x0 ${bit_path}" ${mcs_path}
puts "DONE: BIT=${bit_path}  BIN=${bin_path}  MCS=${mcs_path}.mcs"
close_project