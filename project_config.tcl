#
# Project specific configurations (DFX variant)
# Use with build_dfx.tcl
#

set proj_name m2_artix7_xdma_ddr3_dfx
set part_name xc7a200tfbg484-2
set block_design scripts/xdma_ddr3_dfx_bd.tcl
set post_bd_script scripts/post_bd_dfx.tcl

set constraints {
    constraints/xdma_ddr3_pins.xdc \
    constraints/xdma_ddr3_early.xdc \
}

set dfx_partition_bdc dfx_block_designs/default.tcl
set dfx_partition_cell xdma_ddr3_dfx_i/dfx_partition
set dfx_partition_inst dfx_partition_inst_0

set hdl_sources {
    ../../m2-artix7-accelerator-card-develop/hdl/common/up_axi.v \
    ../../m2-artix7-accelerator-card-develop/hdl/common/datamover_ctrl.v \
    ../../m2-artix7-accelerator-card-develop/hdl/datamover_mm2s_ctrl/axi_datamover_mm2s_ctrl.v \
    ../../m2-artix7-accelerator-card-develop/hdl/datamover_s2mm_ctrl/axi_datamover_s2mm_ctrl.v \
}