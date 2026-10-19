# ============================================================================
# [СПРАВОЧНЫЙ ФАЙЛ] Конфигурация flat-варианта.
# Автоматически НЕ подключается ни одним скриптом: значения продублированы
# в scripts/build_flat.tcl (PROJ_NAME/PART/констрейны/HDL-список). Весь
# старый DFX-конвейер удалён — осталась ТОЛЬКО flat-сборка.
# Держится в актуальном состоянии вручную.
# ============================================================================
#
# Project specific configurations (flat variant)
# Use with build_flat.tcl
#

set proj_name m2_artix7_xdma_flat
set part_name xc7a200tfbg484-2
set block_design scripts/xdma_ddr3_bd.tcl
set post_bd_script scripts/post_bd_flat.tcl

set constraints {
    constraints/xdma_ddr3_pins.xdc     \
    constraints/xdma_ddr3_early.xdc    \
    constraints/pblock_flat_tdot.xdc   \
}

# HDL-файлы DataMover встроены в репозиторий
# (см. third_party/m2-artix7-accelerator-card/README.md)
set hdl_sources {
    third_party/m2-artix7-accelerator-card/hdl/common/up_axi.v \
    third_party/m2-artix7-accelerator-card/hdl/common/datamover_ctrl.v \
    third_party/m2-artix7-accelerator-card/hdl/datamover_mm2s_ctrl/axi_datamover_mm2s_ctrl.v \
    third_party/m2-artix7-accelerator-card/hdl/datamover_s2mm_ctrl/axi_datamover_s2mm_ctrl.v \
}
