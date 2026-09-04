# ============================================================================
# pblock.xdc — Pblock для DFX Reconfigurable Partition (RP)
# ============================================================================
# RP = xdma_ddr3_dfx_i/dfx_partition (Block Design Container с DataMover)
#
# HDPR-8 fix: RESET_AFTER_RECONFIG=TRUE обеспечивает загрузку INIT-значений
# регистров после Dynamic Function eXchange. Без этого FIFO-регистры внутри
# DataMover (axi_datamover_0/1, 1136 шт.) остаются в неизвестном состоянии
# после reconfig → DataMover loopback demo работать не будет.
#
# Требование Vivado: pblock ranges должны быть frame-aligned. Текущие
# диапазоны (SLICE_X82Y1:SLICE_X163Y249 и т.д.) frame-aligned.
# ============================================================================

create_pblock pblock_rm
set_property SNAPPING_MODE ON [get_pblocks pblock_rm]
set_property RESET_AFTER_RECONFIG TRUE [get_pblocks pblock_rm]
add_cells_to_pblock [get_pblocks pblock_rm] [get_cells -quiet [list xdma_ddr3_dfx_i/dfx_partition]]
resize_pblock [get_pblocks pblock_rm] -add {SLICE_X62Y50:SLICE_X81Y249}
resize_pblock [get_pblocks pblock_rm] -add {DSP48_X3Y20:DSP48_X6Y99}
resize_pblock [get_pblocks pblock_rm] -add {RAMB18_X4Y20:RAMB18_X6Y99}
resize_pblock [get_pblocks pblock_rm] -add {RAMB36_X4Y10:RAMB36_X6Y49}

