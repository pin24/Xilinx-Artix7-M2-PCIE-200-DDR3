# ============================================================================
# [DEPRECATED — легаси не-DFX потока]
# Этот разовый helper относится к старой (не-DFX) интеграции и в активный
# DFX-поток НЕ входит: пути C:/A7_M2/EXAMPLES/XDMA_DDR3 устарели, часть
# файлов (build_all.tcl, build_existing.tcl, xdma_ddr3.bd) отсутствует.
# Активная сборка: scripts/build_dfx.tcl (vivado -mode batch -source ...).
# Оставлен для истории — не использовать в новых сборках.
# ============================================================================
# ============================================================================
# add_tdot_axi4_bd.tcl - модификация BD: второй мастер (S01_AXI) на axi_smc
# для прямого доступа ядра tdot_axi4 к DDR3/BRAM.
# Run: vivado -mode batch -source scripts/add_tdot_axi4_bd.tcl
# ============================================================================
set proj_dir  C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name m2_artix7_xdma_ddr3

open_project ${proj_dir}/${proj_name}/${proj_name}.xpr
set bd [get_files xdma_ddr3.bd]
open_bd_design $bd

# ---- axi_smc: 2 slave-порта ----
set_property -dict [list CONFIG.NUM_SI 2] [get_bd_cells axi_smc]

# ---- внешний интерфейсный порт (Slave: к нему подключается M_AXI tdot_axi4) ----
set exist [get_bd_intf_ports -quiet M_AXI_TDOT]
if {$exist eq ""} {
    create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_TDOT
}
set_property -dict [list \
    CONFIG.PROTOCOL AXI4 \
    CONFIG.DATA_WIDTH 64 \
    CONFIG.ADDR_WIDTH 32 \
    CONFIG.NUM_READ_OUTSTANDING 2 \
    CONFIG.NUM_WRITE_OUTSTANDING 2 \
    CONFIG.FREQ_HZ 125000000 \
] [get_bd_intf_ports M_AXI_TDOT]

# ---- подключаем S01_AXI к внешнему порту ----
connect_bd_intf_net [get_bd_intf_pins axi_smc/S01_AXI] [get_bd_intf_ports M_AXI_TDOT]

# ---- связываем порт с тактовым портом axi_aclk (125 МГц) ----
set_property -dict [list CONFIG.ASSOCIATED_BUSIF {M_AXI_TDOT}] [get_bd_pins xdma_0/axi_aclk]

# ---- адресные сегменты для нового адресного пространства ----
set addr_space [get_bd_addr_spaces M_AXI_TDOT]
assign_bd_address -offset 0x80000000 -range 0x10000000 \
    -target_address_space $addr_space \
    [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force
assign_bd_address -offset 0x00000000 -range 0x00002000 \
    -target_address_space $addr_space \
    [get_bd_addr_segs axi_bram_ctrl_0/S_AXI/Mem0] -force

# ---- валидация и сохранение ----
validate_bd_design
save_bd_design
regenerate_bd_layout

puts "=== BD modified: M_AXI_TDOT -> axi_smc/S01_AXI (DDR3 0x8000_0000, BRAM 0x0) ==="
close_project
