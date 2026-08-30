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

# FIX-6 (P1-4): demote the PCIe IP's pcie2_ip-PCIE_X0Y0.xdc to NORMAL so
# our early XDC (xdma_ddr3_early.xdc with reversed lane order) takes
# precedence. Without this, the IP's default EARLY XDC competes with ours
# and "first build doesn't take the early constraints" (see reference
# README.md "Non-standard PCIe Lanes" section). Pattern matches
# build_xdma_ddr3.tcl:35-41, synth_with_core.tcl:49-52, build_existing.tcl:29-33,
# build_full_bitstream.tcl:55-58, synth_with_icap.tcl:44-46, and reference
# scripts/tcl/full.tcl:92-93 (rigoorozco/m2-artix7-accelerator-card).
# Run before synth (best-effort: file may not exist yet) AND re-run after
# synth (see block below) to guarantee the property sticks.
set pcie_ip_xdc [get_files -all -quiet *PCIE_X0Y0.xdc]
if {$pcie_ip_xdc ne ""} {
    set_property PROCESSING_ORDER NORMAL ${pcie_ip_xdc}
    puts "=== PCIE IP xdc set to NORMAL (pre-synth): ${pcie_ip_xdc} ==="
} else {
    puts "=== PCIE IP xdc not found yet (will retry after synth) ==="
}

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

# FIX-5 RTL-1/RTL-2: создаём S_AXI_XADC_REGS на M03 @ 0x46000000, чтобы BD wrapper
# имел порты S_AXI_XADC_REGS_*, которые подключает xdma_ddr3_core_top.sv (инстанция u_xadc).
# Адрес канонический (docs/ADDRESS_MAP.md §2, resize_bar0.tcl:52).
set xadc_port [get_bd_intf_ports -quiet S_AXI_XADC_REGS]
if {$xadc_port eq ""} {
    set_property -dict [list CONFIG.NUM_MI 4] [get_bd_cells xdma_0_axi_periph]
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_XADC_REGS
    set_property -dict [list CONFIG.PROTOCOL AXI4LITE CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 8 CONFIG.FREQ_HZ 125000000] [get_bd_intf_ports S_AXI_XADC_REGS]
    connect_bd_intf_net [get_bd_intf_pins xdma_0_axi_periph/M03_AXI] [get_bd_intf_ports S_AXI_XADC_REGS]
    connect_bd_net [get_bd_pins xdma_0_axi_periph/M03_ACLK] [get_bd_pins xdma_0/axi_aclk]
    connect_bd_net [get_bd_pins xdma_0_axi_periph/M03_ARESETN] [get_bd_pins xdma_0/axi_aresetn]
    # ASSOCIATED_BUSIF: привязать S_AXI_XADC_REGS к клоковому домену xdma_0/axi_aclk
    set old_assoc [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins xdma_0/axi_aclk]]
    if {[string first "S_AXI_XADC_REGS" $old_assoc] == -1} {
        set new_assoc [string trim "$old_assoc S_AXI_XADC_REGS"]
        set_property -dict [list CONFIG.ASSOCIATED_BUSIF $new_assoc] [get_bd_pins xdma_0/axi_aclk]
    }
}
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_XADC_REGS_Reg}]
assign_bd_address -offset 0x46000000 -range 0x1000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs S_AXI_XADC_REGS/Reg] -force

# FIX-5 RTL-3: cleanup legacy M_AXI_ICAP (ANALYSIS_AND_SPEC_FIX.md B-3).
# Удаляем посторонний порт M_AXI_ICAP (64-бит мастер от старой схемы «ICAP как мастер»),
# иначе wrapper его экспортирует, а top-level не подключает → CRITICAL WARNING в impl.
set legacy_icap [get_bd_intf_ports -quiet M_AXI_ICAP]
if {$legacy_icap ne ""} {
    set legacy_intf_nets [get_bd_intf_nets -quiet -of_objects $legacy_icap]
    foreach inet $legacy_intf_nets { delete_bd_objs $inet }
    set legacy_nets [get_bd_nets -quiet -of_objects $legacy_icap]
    foreach net $legacy_nets { delete_bd_objs $net }
    delete_bd_objs $legacy_icap
    puts "=== FIX-5 RTL-3: удалён legacy BD-порт M_AXI_ICAP ==="
}

validate_bd_design
save_bd_design
puts "=== BD: GPIO 0x40000000, TDOT 0x40001000, ICAP 0x40002000, XADC 0x46000000 ==="

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

# FIX-6 (P1-4): re-apply PCIE IP XDC demotion after synthesis. The IP's
# pcie2_ip-PCIE_X0Y0.xdc is generated during OOC synthesis; before synth
# the file may not exist on disk. After synth, it definitely exists, so
# this is the deterministic point to demote it to NORMAL before impl.
# This matches reference scripts/tcl/full.tcl:92-93 exactly:
#   set_property PROCESSING_ORDER NORMAL [get_files -all .../pcie2_ip-PCIE_X0Y0.xdc]
set pcie_ip_xdc [get_files -all -quiet *PCIE_X0Y0.xdc]
if {$pcie_ip_xdc ne ""} {
    set_property PROCESSING_ORDER NORMAL ${pcie_ip_xdc}
    puts "=== PCIE IP xdc set to NORMAL (post-synth): ${pcie_ip_xdc} ==="
} else {
    puts "=== WARNING: PCIE IP xdc STILL not found after synth — lane LOC may be wrong! ==="
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