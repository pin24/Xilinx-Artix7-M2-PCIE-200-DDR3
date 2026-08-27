# ============================================================================
# resize_bar0.tcl
# Увеличивает BAR0 XDMA IP с 128KB до 128MB, чтобы покрыть все AXI-Lite
# адреса (включая XADC 0x46000000).
# Запуск: vivado -mode batch -source scripts/resize_bar0.tcl
# ============================================================================
set proj_dir C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name m2_artix7_xdma_ddr3

open_project ${proj_dir}/${proj_name}/${proj_name}.xpr

# ----- 1. Open BD -----
puts "=== Opening BD ==="
set bd [get_files xdma_ddr3.bd]
open_bd_design $bd

# ----- 2. Меняем BAR0 в XDMA IP -----
puts "=== Resizing BAR0: 128KB -> 128MB ==="
set xdma [get_bd_cells xdma_0]
set_property -dict [list \
    CONFIG.pf0_bar0_scale {Megabytes} \
    CONFIG.pf0_bar0_size {128} \
] $xdma

puts "=== BAR0 now 128MB (covers 0x40000000-0x47FFFFFF) ==="

# ----- 2. Переустанавливаем адреса AXI-Lite периферии -----
# После изменения BAR0, Vivado автоматически переразмечает адреса,
# но для гарантии удаляем и пересоздаём сегменты
set as_lite [get_bd_addr_spaces xdma_0/M_AXI_LITE]

# GPIO
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_gpio_0_Reg}]
assign_bd_address -offset 0x40000000 -range 0x1000 -target_address_space $as_lite \
    [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force

# TDOT_REGS
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_TDOT_REGS_Reg}]
assign_bd_address -offset 0x40001000 -range 0x1000 -target_address_space $as_lite \
    [get_bd_addr_segs S_AXI_TDOT_REGS/Reg] -force

# ICAP
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_ICAP_REGS_Reg}]
if {[get_bd_intf_ports -quiet S_AXI_ICAP_REGS] ne ""} {
    assign_bd_address -offset 0x40002000 -range 0x1000 -target_address_space $as_lite \
        [get_bd_addr_segs S_AXI_ICAP_REGS/Reg] -force
}

# XADC (теперь ВЛЕЗАЕТ в 128MB BAR0)
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_XADC_REGS_Reg}]
if {[get_bd_intf_ports -quiet S_AXI_XADC_REGS] ne ""} {
    assign_bd_address -offset 0x46000000 -range 0x1000 -target_address_space $as_lite \
        [get_bd_addr_segs S_AXI_XADC_REGS/Reg] -force
}

puts "=== Addresses reassigned ==="
puts "  GPIO:  0x40000000 (4K)"
puts "  TDOT:  0x40001000 (4K)"
puts "  ICAP:  0x40002000 (4K)"
puts "  XADC:  0x46000000 (4K)  <-- NOW ACCESSIBLE via BAR0"

# ----- 3. Валидация и обновление -----
validate_bd_design
save_bd_design
regenerate_bd_layout

puts "=== Regenerating BD wrapper ==="
make_wrapper -files [get_files xdma_ddr3.bd] -top
update_compile_order -fileset sources_1
update_compile_order -fileset constrs_1

# ----- 4. Полный синтез и битстрим -----
puts "=== Running synthesis ==="
launch_runs synth_1 -jobs 4
wait_on_run synth_1

puts "=== Running implementation ==="
launch_runs impl_1 -jobs 4
wait_on_run impl_1

puts "=== Generating bitstream ==="
open_run impl_1
write_bitstream -force ${proj_dir}/build/${proj_name}.bit
write_cfgmem -format MCS -size 128 -interface SMAPx32 \
    -loadbit "up 0x0 ${proj_dir}/build/${proj_name}.bit" \
    ${proj_dir}/build/${proj_name}.mcs

puts "=== DONE ==="
puts "Files:"
puts "  ${proj_dir}/build/${proj_name}.bit"
puts "  ${proj_dir}/build/${proj_name}.mcs"
close_project