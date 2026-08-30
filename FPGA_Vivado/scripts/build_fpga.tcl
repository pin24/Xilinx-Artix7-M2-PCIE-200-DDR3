###############################################################################
# build_fpga.tcl — сборка: XDMA + MIG + DFX + HWICAP + tdot_axi4
# Запуск: vivado -mode batch -source build_fpga.tcl
###############################################################################
set PART "xc7a200tfbg484-2"
set ROOT "C:/A7_M2/EXAMPLES/XDMA_DDR3_V2"
set PROJ "m2_artix7_tdot"
set BUILD "${ROOT}/FPGA_Vivado/build/${PROJ}"

puts "=== 1. Create project ==="
create_project -force ${PROJ} ${BUILD} -part ${PART}

puts "=== 2. Add RTL ==="
read_verilog -sv ${ROOT}/FPGA_Vivado/hdl/block/tbyte_add.sv
read_verilog -sv ${ROOT}/FPGA_Vivado/hdl/block/tbyte_mul.sv
read_verilog -sv ${ROOT}/FPGA_Vivado/hdl/block/tfadd_raw.sv
read_verilog -sv ${ROOT}/FPGA_Vivado/hdl/block/tfmul_raw.sv
read_verilog -sv ${ROOT}/FPGA_Vivado/hdl/block/compute_dot_par_raw.sv
read_verilog -sv ${ROOT}/FPGA_Vivado/hdl/integration/tdot_axi4.sv
read_verilog    ${ROOT}/FPGA_Vivado/hdl/integration/tdot_axi4_wrapper.v
update_compile_order -fileset sources_1

puts "=== 3. Constraints ==="
add_files -fileset constrs_1 ${ROOT}/FPGA_Vivado/constraints/pins.xdc
add_files -fileset constrs_1 ${ROOT}/FPGA_Vivado/constraints/pcie_lanes_early.xdc
add_files -fileset constrs_1 ${ROOT}/FPGA_Vivado/xdma_ddr3_dfx/constraints/pins.xdc
add_files -fileset constrs_1 ${ROOT}/FPGA_Vivado/xdma_ddr3_dfx/constraints/pcie_lanes_early.xdc
set_property PROCESSING_ORDER EARLY [get_files -all *pcie_lanes_early.xdc]

puts "=== 4. DFX Partition ==="
create_bd_design dfx_partition
current_bd_design dfx_partition

set rp_M_AXI [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 rp_M_AXI ]
set_property -dict [list CONFIG.ADDR_WIDTH {32} CONFIG.DATA_WIDTH {64} CONFIG.PROTOCOL {AXI4}] $rp_M_AXI

set rp_S_AXI [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 rp_S_AXI ]
set_property -dict [list CONFIG.ADDR_WIDTH {8} CONFIG.DATA_WIDTH {32} CONFIG.PROTOCOL {AXI4LITE}] $rp_S_AXI

set clk [ create_bd_port -dir I -type clk clk ]
set rp_resetn [ create_bd_port -dir I rp_resetn ]

create_bd_cell -type module -reference tdot_axi4_wrapper tdot_0
set_property CONFIG.NUM_MAC {32} [get_bd_cells tdot_0]

set rp_s_regslice [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 rp_s_regslice ]
set rp_m_regslice [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 rp_m_regslice ]

connect_bd_intf_net [get_bd_intf_ports rp_S_AXI] [get_bd_intf_pins rp_s_regslice/S_AXI]
connect_bd_intf_net [get_bd_intf_pins rp_s_regslice/M_AXI] [get_bd_intf_pins tdot_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins tdot_0/M_AXI] [get_bd_intf_pins rp_m_regslice/S_AXI]
connect_bd_intf_net [get_bd_intf_pins rp_m_regslice/M_AXI] [get_bd_intf_ports rp_M_AXI]

connect_bd_net [get_bd_ports clk] [get_bd_pins tdot_0/S_AXI_ACLK] [get_bd_pins tdot_0/M_AXI_ACLK] [get_bd_pins rp_s_regslice/aclk] [get_bd_pins rp_m_regslice/aclk]
connect_bd_net [get_bd_ports rp_resetn] [get_bd_pins tdot_0/S_AXI_ARESETN] [get_bd_pins tdot_0/M_AXI_ARESETN] [get_bd_pins rp_s_regslice/aresetn] [get_bd_pins rp_m_regslice/aresetn]

assign_bd_address -offset 0x00000000 -range 0x10000000 -target_address_space [get_bd_addr_spaces tdot_0/M_AXI] [get_bd_addr_segs rp_M_AXI/Reg] -force
assign_bd_address -offset 0x40010000 -range 0x00001000 -target_address_space [get_bd_addr_spaces rp_S_AXI] [get_bd_addr_segs tdot_0/S_AXI/reg0] -force

validate_bd_design
save_bd_design
puts "=== DFX PARTITION OK ==="

puts "=== 5. Static BD ==="
create_bd_design xdma_ddr3_dfx
current_bd_design xdma_ddr3_dfx

puts " + XDMA"
set xdma [create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.1 xdma_0]
set_property -dict [list CONFIG.pf0_bar0_scale {Megabytes} CONFIG.pf0_bar0_size {128} CONFIG.pciebar2axibar_axil_master 0x40000000 CONFIG.xdma_axi_intf_mm {AXI_Memory_Mapped} CONFIG.xdma_rnum_chnl {2} CONFIG.xdma_wnum_chnl {2} CONFIG.axilite_master_en {true}] $xdma

puts " + MIG"
set mig [create_bd_cell -type ip -vlnv xilinx.com:ip:mig_7series:4.2 mig_7series_0]
file mkdir ${BUILD}/${PROJ}.srcs/sources_1/bd/xdma_ddr3_dfx/ipconfig
set_property -dict [list CONFIG.XML_INPUT_FILE ${ROOT}/FPGA_Vivado/xdma_ddr3_dfx/constraints/mig.prj] $mig

puts " + HWICAP"
set hwicap [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_hwicap:3.0 axi_hwicap_0]
set_property -dict [list CONFIG.C_INCLUDE_STARTUP {true} CONFIG.C_WRITE_FIFO_DEPTH {1024}] $hwicap

puts " + GPIO"
set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0]
set_property CONFIG.C_GPIO_WIDTH {3} $gpio

puts " + SmartConnects"
set smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 xdma_axi_smc]
set_property CONFIG.NUM_SI {2} $smc

set lsmc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 xdma_axi_lite_smc]
set_property CONFIG.NUM_SI {1} $lsmc

puts " + util_ds_buf"
set clk_buf [create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_0]
set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} $clk_buf

puts " + proc_sys_reset"
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

puts " + dfx_partition"
create_bd_cell -type container -reference dfx_partition dfx_partition

puts "=== 6. Connect ==="

puts "=== 7. Connect ==="
connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI_LITE] [get_bd_intf_pins xdma_axi_lite_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins xdma_axi_lite_smc/M00_AXI] [get_bd_intf_pins axi_hwicap_0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins xdma_axi_lite_smc/M01_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins xdma_axi_lite_smc/M02_AXI] [get_bd_intf_pins dfx_partition/rp_S_AXI]

connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI] [get_bd_intf_pins xdma_axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins xdma_axi_smc/S01_AXI] [get_bd_intf_pins dfx_partition/rp_M_AXI]
connect_bd_intf_net [get_bd_intf_pins xdma_axi_smc/M00_AXI] [get_bd_intf_pins mig_7series_0/S_AXI]

connect_bd_net [get_bd_pins xdma_0/axi_aclk] [get_bd_pins xdma_axi_smc/aclk] [get_bd_pins xdma_axi_lite_smc/aclk] [get_bd_pins axi_hwicap_0/s_axi_aclk] [get_bd_pins axi_gpio_0/s_axi_aclk] [get_bd_pins dfx_partition/clk] [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins xdma_0/axi_aresetn] [get_bd_pins xdma_axi_smc/aresetn] [get_bd_pins xdma_axi_lite_smc/aresetn] [get_bd_pins axi_hwicap_0/s_axi_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn] [get_bd_pins dfx_partition/rp_resetn]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins mig_7series_0/aresetn]
connect_bd_net [get_bd_pins xdma_0/sys_rst_n] [get_bd_pins mig_7series_0/sys_rst]
connect_bd_intf_net [get_bd_intf_pins util_ds_buf_0/IBUF_OUT] [get_bd_intf_pins xdma_0/sys_clk]

# PCIe ports
foreach {dir name pin} {Slave pcie_7x_mgt_rtl_0_rxn xdma_0/pcie_7x_mgt_rtl_rxn Slave pcie_7x_mgt_rtl_0_rxp xdma_0/pcie_7x_mgt_rtl_rxp Master pcie_7x_mgt_rtl_0_txn xdma_0/pcie_7x_mgt_rtl_txn Master pcie_7x_mgt_rtl_0_txp xdma_0/pcie_7x_mgt_rtl_txp} {
    set p [create_bd_intf_port -mode ${dir} -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 ${name}]
    connect_bd_intf_net [get_bd_intf_ports ${name}] [get_bd_intf_pins ${pin}]
}

# Addresses
assign_bd_address -offset 0x00000000 -range 0x10000000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI] [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force
assign_bd_address -offset 0x00000000 -range 0x10000000 -target_address_space [get_bd_addr_spaces dfx_partition/rp_M_AXI] [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force
assign_bd_address -offset 0x40001000 -range 0x00001000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs axi_hwicap_0/S_AXI_LITE/Reg] -force
assign_bd_address -offset 0x40000000 -range 0x00001000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force

validate_bd_design
save_bd_design
puts "=== BD DONE ==="

puts "=== 8. Wrapper ==="
make_wrapper -files [get_files xdma_ddr3_dfx.bd] -top -force
set_property top xdma_ddr3_dfx_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "=== WRAPPER DONE ==="