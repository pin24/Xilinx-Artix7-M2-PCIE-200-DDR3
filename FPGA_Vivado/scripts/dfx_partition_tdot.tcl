################################################################
# dfx_partition_tdot.tcl — RP с tdot_axi4 (TFloat48 вычислитель)
# Замена axis_data_fifo_0 на tdot_axi4 в DFX Partition
# Формат: reference default.tcl, но без DataMovers
################################################################
set scripts_vivado_version 2021.2
set current_vivado_version [version -short]
if { [string first $scripts_vivado_version $current_vivado_version] == -1 } {
    puts "WARNING: script for $scripts_vivado_version, running $current_vivado_version"
}

set design_name dfx_partition

create_bd_design $design_name
current_bd_design $design_name

# ====== RP интерфейсы ======
set rp_M_AXI [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 rp_M_AXI ]
set_property -dict [list \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.DATA_WIDTH {64} \
    CONFIG.FREQ_HZ {125000000} \
    CONFIG.PROTOCOL {AXI4} \
] $rp_M_AXI

set rp_S_AXI [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 rp_S_AXI ]
set_property -dict [list \
    CONFIG.ADDR_WIDTH {8} \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.FREQ_HZ {125000000} \
    CONFIG.PROTOCOL {AXI4LITE} \
] $rp_S_AXI

set clk [ create_bd_port -dir I -type clk -freq_hz 125000000 clk ]
set_property -dict [list CONFIG.ASSOCIATED_BUSIF {rp_M_AXI:rp_S_AXI} CONFIG.ASSOCIATED_RESET {rp_resetn}] $clk
set rp_resetn [ create_bd_port -dir I rp_resetn ]

# ====== tdot_axi4 (RTL module reference, через Verilog wrapper) ======
create_bd_cell -type module -reference tdot_axi4_wrapper tdot_0
set_property -dict [list CONFIG.NUM_MAC {32}] [get_bd_cells tdot_0]

# ====== Register slices (для изоляции RP границы) ======
set rp_s_axi_regslice [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 rp_s_axi_regslice ]
set_property -dict [list \
    CONFIG.ADDR_WIDTH {8} CONFIG.DATA_WIDTH {32} \
    CONFIG.PROTOCOL {AXI4LITE} \
    CONFIG.REG_AR {1} CONFIG.REG_AW {1} CONFIG.REG_B {1} CONFIG.REG_R {1} CONFIG.REG_W {1} \
] $rp_s_axi_regslice

set rp_m_axi_regslice [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 rp_m_axi_regslice ]
set_property -dict [list \
    CONFIG.ADDR_WIDTH {32} CONFIG.DATA_WIDTH {64} \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.REG_AR {1} CONFIG.REG_AW {1} CONFIG.REG_B {1} CONFIG.REG_R {1} CONFIG.REG_W {1} \
] $rp_m_axi_regslice

# ====== Подключения ======
# rp_S_AXI → regslice → tdot_0.S_AXI
connect_bd_intf_net [get_bd_intf_ports rp_S_AXI] [get_bd_intf_pins rp_s_axi_regslice/S_AXI]
connect_bd_intf_net [get_bd_intf_pins rp_s_axi_regslice/M_AXI] [get_bd_intf_pins tdot_0/S_AXI]

# tdot_0.M_AXI → regslice → rp_M_AXI
connect_bd_intf_net [get_bd_intf_pins tdot_0/M_AXI] [get_bd_intf_pins rp_m_axi_regslice/S_AXI]
connect_bd_intf_net [get_bd_intf_pins rp_m_axi_regslice/M_AXI] [get_bd_intf_ports rp_M_AXI]

# Тактовые и сброс
connect_bd_net [get_bd_ports clk] \
    [get_bd_pins tdot_0/S_AXI_ACLK] \
    [get_bd_pins tdot_0/M_AXI_ACLK] \
    [get_bd_pins rp_s_axi_regslice/aclk] \
    [get_bd_pins rp_m_axi_regslice/aclk]

connect_bd_net [get_bd_ports rp_resetn] \
    [get_bd_pins tdot_0/S_AXI_ARESETN] \
    [get_bd_pins tdot_0/M_AXI_ARESETN] \
    [get_bd_pins rp_s_axi_regslice/aresetn] \
    [get_bd_pins rp_m_axi_regslice/aresetn]

# ====== Адреса ======
# tdot M_AXI → rp_M_AXI → DDR3 (через статику)
assign_bd_address -offset 0x00000000 -range 0x10000000 \
    -target_address_space [get_bd_addr_spaces tdot_0/M_AXI] \
    [get_bd_addr_segs rp_M_AXI/Reg] -force

# rp_S_AXI → tdot CSRs @ 0x40010000
assign_bd_address -offset 0x40010000 -range 0x00001000 \
    -target_address_space [get_bd_addr_spaces rp_S_AXI] \
    [get_bd_addr_segs tdot_0/S_AXI/reg0] -force

validate_bd_design
save_bd_design
puts "=== dfx_partition_tdot created ==="