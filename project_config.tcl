# ============================================================================
# [СПРАВОЧНЫЙ ФАЙЛ] Конфигурация DFX-варианта.
# Автоматически НЕ подключается ни одним скриптом: значения продублированы
# в scripts/build_dfx.tcl (PROJ_NAME/PART/констрейны/HDL-список) и
# dfx_block_designs/default.tcl. Держится в актуальном состоянии вручную.
# ============================================================================
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
    constraints/pblock.xdc \
}

set dfx_partition_bdc dfx_block_designs/default.tcl
set dfx_partition_cell xdma_ddr3_dfx_i/dfx_partition
set dfx_partition_inst dfx_partition_inst_0

# HDL-файлы DFX Partition встроены в репозиторий
# (см. third_party/m2-artix7-accelerator-card/README.md)
set hdl_sources {
    third_party/m2-artix7-accelerator-card/hdl/common/up_axi.v \
    third_party/m2-artix7-accelerator-card/hdl/common/datamover_ctrl.v \
    third_party/m2-artix7-accelerator-card/hdl/datamover_mm2s_ctrl/axi_datamover_mm2s_ctrl.v \
    third_party/m2-artix7-accelerator-card/hdl/datamover_s2mm_ctrl/axi_datamover_s2mm_ctrl.v \
}
