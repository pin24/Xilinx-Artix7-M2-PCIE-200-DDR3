################################################################
# clean_build.tcl — ПОЛНАЯ сборка TFloat48 вычислителя
# Создаёт проект + BD (XDMA + MIG) + RTL top-level с tdot_axi4
# → synth → impl → bitstream
# Запуск: vivado -mode batch -source FPGA_Vivado/scripts/clean_build.tcl
################################################################
set proj_dir    C:/A7_M2/EXAMPLES/XDMA_DDR3_V2
set proj_name   m2_artix7_tdot
set part        xc7a200tfbg484-2
set int_dir     ${proj_dir}/FPGA_Vivado/hdl/integration
set block_dir   ${proj_dir}/FPGA_Vivado/hdl/block
set scripts_dir ${proj_dir}/FPGA_Vivado/scripts
set pins_xdc    ${proj_dir}/FPGA_Vivado/constraints/pins.xdc
set early_xdc   ${proj_dir}/FPGA_Vivado/constraints/pcie_lanes_early.xdc
set build_dir   ${proj_dir}/FPGA_Vivado/build/${proj_name}
set top_name    xdma_ddr3_core_top

puts "=== 1. CREATE PROJECT ==="
create_project ${proj_name} ${build_dir} -part ${part} -force

puts "=== 2. ADD RTL SOURCES ==="
read_verilog -sv ${block_dir}/tbyte_add.sv
read_verilog -sv ${block_dir}/tbyte_mul.sv
read_verilog -sv ${block_dir}/tfadd_raw.sv
read_verilog -sv ${block_dir}/tfmul_raw.sv
read_verilog -sv ${block_dir}/compute_dot_par_raw.sv
read_verilog -sv ${int_dir}/tdot_axi4.sv
read_verilog -sv ${int_dir}/xdma_ddr3_core_top.sv
update_compile_order -fileset sources_1

puts "=== 3. ADD CONSTRAINTS ==="
add_files -fileset constrs_1 ${pins_xdc}
add_files -fileset constrs_1 ${early_xdc}
set_property PROCESSING_ORDER EARLY [get_files ${early_xdc}]

puts "=== 4. CREATE BD (XDMA + MIG) ==="
create_bd_design xdma_ddr3
current_bd_design xdma_ddr3

# XDMA IP
set xdma [ create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.1 xdma_0 ]
set_property -dict [list \
    CONFIG.pf0_bar0_scale {Megabytes} \
    CONFIG.pf0_bar0_size {128} \
    CONFIG.pciebar2axibar_axil_master {0x40000000} \
    CONFIG.xdma_axi_intf_mm {AXI_Memory_Mapped} \
    CONFIG.xdma_rnum_chnl {2} \
    CONFIG.xdma_wnum_chnl {2} \
    CONFIG.axilite_master_en {true} \
] $xdma

# MIG DDR3
set mig [ create_bd_cell -type ip -vlnv xilinx.com:ip:mig_7series:4.2 mig_7series_0 ]

# SmartConnect (M_AXI → MIG, M_AXI_LITE → external)
set smc [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc ]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $smc

# PCIe refclk buffer
set clk_buf [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf ]
set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDSGTE}] $clk_buf

# Reset
set rst [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_mig_7series_0_100M ]

# Подключения
connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI] [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins mig_7series_0/S_AXI]

# PCIe refclk
connect_bd_intf_net [get_bd_intf_pins util_ds_buf/IBUF_DS_ODIV2] [get_bd_intf_pins xdma_0/sys_clk_gt]
connect_bd_intf_net [get_bd_intf_pins util_ds_buf/IBUF_OUT] [get_bd_intf_pins xdma_0/sys_clk]
connect_bd_net [get_bd_pins xdma_0/sys_rst_n] [get_bd_pins mig_7series_0/sys_rst]

# AXI-Lite порты наружу (для tdot_axi4 в top-level)
set s_axi_tdot [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_TDOT_REGS ]
set_property -dict [list CONFIG.PROTOCOL AXI4LITE CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 8] $s_axi_tdot
connect_bd_intf_net [get_bd_intf_ports S_AXI_TDOT_REGS] [get_bd_intf_pins xdma_0/M_AXI_LITE]

# AXI-мастер порт наружу (для tdot_axi4 M_AXI)
set m_axi_tdot [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_TDOT ]
set_property -dict [list CONFIG.PROTOCOL AXI4 CONFIG.DATA_WIDTH 64 CONFIG.ADDR_WIDTH 32] $m_axi_tdot
connect_bd_intf_net [get_bd_intf_ports M_AXI_TDOT] [get_bd_intf_pins axi_smc/S01_AXI]

# PCIe порты
set pcie_rxn [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pcie_7x_mgt_rtl_0_rxn ]
set pcie_rxp [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pcie_7x_mgt_rtl_0_rxp ]
set pcie_txn [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pcie_7x_mgt_rtl_0_txn ]
set pcie_txp [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pcie_7x_mgt_rtl_0_txp ]
connect_bd_intf_net [get_bd_intf_ports pcie_7x_mgt_rtl_0_rxn] [get_bd_intf_pins xdma_0/pcie_7x_mgt_rtl_rxn]
connect_bd_intf_net [get_bd_intf_ports pcie_7x_mgt_rtl_0_rxp] [get_bd_intf_pins xdma_0/pcie_7x_mgt_rtl_rxp]
connect_bd_intf_net [get_bd_intf_pins xdma_0/pcie_7x_mgt_rtl_txn] [get_bd_intf_ports pcie_7x_mgt_rtl_0_txn]
connect_bd_intf_net [get_bd_intf_pins xdma_0/pcie_7x_mgt_rtl_txp] [get_bd_intf_ports pcie_7x_mgt_rtl_0_txp]

# Часы и сброс
connect_bd_net [get_bd_pins xdma_0/axi_aclk] [get_bd_pins axi_smc/aclk]
connect_bd_net [get_bd_pins xdma_0/axi_aresetn] [get_bd_pins axi_smc/aresetn]

# Дифференциальный рефклок
connect_bd_intf_net [get_bd_intf_pins util_ds_buf/CLK_IN_D] [get_bd_intf_ports diff_clock_rtl_0_clk_n]

# Адреса
assign_bd_address -offset 0x00000000 -range 0x10000000 \
    -target_address_space [get_bd_addr_spaces xdma_0/M_AXI] \
    [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force

validate_bd_design
save_bd_design
puts "=== BD created ==="

puts "=== 5. GENERATE WRAPPER ==="
make_wrapper -files [get_files xdma_ddr3.bd] -top -force
set_property top ${top_name} [current_fileset]
update_compile_order -fileset sources_1

puts "=== 6. SYNTHESIS ==="
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
puts "=== SYNTH: [get_property STATUS [get_runs synth_1]] ==="

puts "=== 7. IMPLEMENTATION ==="
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "=== IMPL: [get_property STATUS [get_runs impl_1]] ==="

puts "=== 8. WRITE BITSTREAM ==="
open_run impl_1
write_bitstream -force ${build_dir}/${proj_name}.runs/impl_1/${top_name}.bit
write_bitstream -force -bin_file ${build_dir}/${proj_name}.runs/impl_1/${top_name}.bit

puts "=== DONE ==="
puts "BIT: ${build_dir}/${proj_name}.runs/impl_1/${top_name}.bit"
puts "BIN: ${build_dir}/${proj_name}.runs/impl_1/${top_name}.bin"
close_project