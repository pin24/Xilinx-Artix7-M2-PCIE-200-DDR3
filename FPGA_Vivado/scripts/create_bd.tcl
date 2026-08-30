################################################################
# create_bd.tcl — создаёт BD: XDMA + tdot_axi4 + MIG DDR3 + HWICAP
# Вызывается из clean_build.tcl
################################################################
set scripts_vivado_version 2021.2
set design_name xdma_ddr3_dfx

create_bd_design $design_name
current_bd_design $design_name

# ====== XDMA IP ======
set xdma_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.1 xdma_0 ]
set_property -dict [list \
    CONFIG.pf0_bar0_scale {Megabytes} \
    CONFIG.pf0_bar0_size {128} \
    CONFIG.pf0_bar2_scale {Megabytes} \
    CONFIG.pf0_bar2_size {256} \
    CONFIG.pciebar2axibar_axil_master {0x40000000} \
    CONFIG.xdma_axi_intf_mm {AXI_Memory_Mapped} \
    CONFIG.xdma_rnum_chnl {2} \
    CONFIG.xdma_wnum_chnl {2} \
    CONFIG.axilite_master_en {true} \
] $xdma_0

# ====== tdot_axi4 (RTL, через Verilog wrapper) ======
set tdot [ create_bd_cell -type module -reference tdot_axi4_wrapper tdot_0 ]
set_property -dict [list CONFIG.NUM_MAC {32}] $tdot

# ====== AXI SmartConnect (для M_AXI → DDR3) ======
set smc [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc ]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $smc

# ====== AXI-Lite SmartConnect (для M_AXI_LITE → tdot) ======
set lite_smc [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_lite_smc ]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $lite_smc

# ====== Подключения ======
# XDMA M_AXI_LITE → lite_smc → tdot S_AXI
connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI_LITE] [get_bd_intf_pins axi_lite_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_lite_smc/M00_AXI] [get_bd_intf_pins tdot_0/S_AXI]

# XDMA M_AXI → smc → (MIG DDR3 будет позже)
connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI] [get_bd_intf_pins axi_smc/S00_AXI]

# tdot M_AXI → smc
connect_bd_intf_net [get_bd_intf_pins tdot_0/M_AXI] [get_bd_intf_pins axi_smc/S01_AXI]

# ====== Часы и сброс ======
connect_bd_net [get_bd_pins xdma_0/axi_aclk] \
    [get_bd_pins tdot_0/S_AXI_ACLK] \
    [get_bd_pins tdot_0/M_AXI_ACLK] \
    [get_bd_pins axi_smc/aclk] \
    [get_bd_pins axi_lite_smc/aclk]

connect_bd_net [get_bd_pins xdma_0/axi_aresetn] \
    [get_bd_pins tdot_0/S_AXI_ARESETN] \
    [get_bd_pins tdot_0/M_AXI_ARESETN] \
    [get_bd_pins axi_smc/aresetn] \
    [get_bd_pins axi_lite_smc/aresetn]

# ====== Адреса ======
assign_bd_address -offset 0x40010000 -range 0x1000 \
    -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] \
    [get_bd_addr_segs tdot_0/S_AXI/reg0] -force

assign_bd_address -offset 0x00000000 -range 0x10000000 \
    -target_address_space [get_bd_addr_spaces tdot_0/M_AXI] \
    [get_bd_addr_segs axi_smc/S01_AXI/Mem0] -force

assign_bd_address -offset 0x00000000 -range 0x10000000 \
    -target_address_space [get_bd_addr_spaces xdma_0/M_AXI] \
    [get_bd_addr_segs axi_smc/S00_AXI/Mem0] -force

# ====== PCIe порты ======
set pcie_rxn [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pcie_7x_mgt_rtl_0_rxn ]
set pcie_rxp [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pcie_7x_mgt_rtl_0_rxp ]
set pcie_txn [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pcie_7x_mgt_rtl_0_txn ]
set pcie_txp [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pcie_7x_mgt_rtl_0_txp ]
connect_bd_intf_net [get_bd_intf_ports pcie_7x_mgt_rtl_0_rxn] [get_bd_intf_pins xdma_0/pcie_7x_mgt_rtl_rxn]
connect_bd_intf_net [get_bd_intf_ports pcie_7x_mgt_rtl_0_rxp] [get_bd_intf_pins xdma_0/pcie_7x_mgt_rtl_rxp]
connect_bd_intf_net [get_bd_intf_pins xdma_0/pcie_7x_mgt_rtl_txn] [get_bd_intf_ports pcie_7x_mgt_rtl_0_txn]
connect_bd_intf_net [get_bd_intf_pins xdma_0/pcie_7x_mgt_rtl_txp] [get_bd_intf_ports pcie_7x_mgt_rtl_0_txp]

# ====== Валидация ======
validate_bd_design
save_bd_design
puts "=== BD: xdma + tdot_axi4 created ==="