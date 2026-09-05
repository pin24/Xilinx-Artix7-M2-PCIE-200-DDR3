# ============================================================================
# [DEPRECATED — легаси не-DFX потока]
# Этот разовый helper относится к старой (не-DFX) интеграции и в активный
# DFX-поток НЕ входит: пути C:/A7_M2/EXAMPLES/XDMA_DDR3 устарели, часть
# файлов (build_all.tcl, build_existing.tcl, xdma_ddr3.bd) отсутствует.
# Активная сборка: scripts/build_dfx.tcl (vivado -mode batch -source ...).
# Оставлен для истории — не использовать в новых сборках.
# ============================================================================
puts "=== Regenerate XDMA IP subcore ==="
open_project C:/A7_M2/EXAMPLES/XDMA_DDR3/m2_artix7_xdma_ddr3/m2_artix7_xdma_ddr3.xpr
open_bd_design [get_files xdma_ddr3.bd]
# Regenerate only the XDMA IP subcore (not the whole BD)
generate_target -force {instantiation_template} [get_files xdma_ddr3.bd]
update_compile_order -fileset sources_1
close_project