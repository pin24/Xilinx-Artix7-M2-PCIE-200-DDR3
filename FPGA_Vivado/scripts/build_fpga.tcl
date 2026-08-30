###############################################################################
# build_fpga.tcl — Полная сборка XDMA + MIG + DFX + tdot_axi4 (TFloat48)
# Основа: https://github.com/rigoorozco/m2-artix7-accelerator-card
# Адаптация: tdot_axi4 вместо DataMovers в DFX RP
#
# Запуск: vivado -mode batch -source build_fpga.tcl
###############################################################################

set PART        [lindex $argv 0]
if {$PART eq ""} { set PART "xc7a200tfbg484-2" }

set PROJ_DIR    [file normalize [file dirname [info script]]/..]
set PROJ_NAME   "m2_artix7_tdot"
set BUILD_DIR   "${PROJ_DIR}/build"
set HDL_DIR     "${PROJ_DIR}/hdl"
set SCRIPTS_DIR "${PROJ_DIR}/scripts"
set CONSTRS_DIR "${PROJ_DIR}/constraints"

puts "=== XDMA DDR3 V2 BUILD ==="
puts "Part:   $PART"
puts "Output: ${BUILD_DIR}/${PROJ_NAME}"

# ======================== 1. ПРОЕКТ ========================
puts "=== 1. CREATE PROJECT ==="
create_project -force ${PROJ_NAME} ${BUILD_DIR}/${PROJ_NAME} -part ${PART}

# ======================== 2. RTL ========================
puts "=== 2. ADD RTL SOURCES ==="
read_verilog -sv ${HDL_DIR}/block/tbyte_add.sv
read_verilog -sv ${HDL_DIR}/block/tbyte_mul.sv
read_verilog -sv ${HDL_DIR}/block/tfadd_raw.sv
read_verilog -sv ${HDL_DIR}/block/tfmul_raw.sv
read_verilog -sv ${HDL_DIR}/block/compute_dot_par_raw.sv
read_verilog -sv ${HDL_DIR}/integration/tdot_axi4.sv
read_verilog    ${HDL_DIR}/integration/tdot_axi4_wrapper.v
read_verilog -sv ${HDL_DIR}/integration/xdma_ddr3_core_top.sv
update_compile_order -fileset sources_1

# ======================== 3. КОНСТРЕЙНТЫ ========================
puts "=== 3. ADD CONSTRAINTS ==="
if {[file exists ${CONSTRS_DIR}/pins.xdc]} { add_files -fileset constrs_1 ${CONSTRS_DIR}/pins.xdc }
if {[file exists ${CONSTRS_DIR}/pcie_lanes_early.xdc]} { add_files -fileset constrs_1 ${CONSTRS_DIR}/pcie_lanes_early.xdc }
set early_xdc [get_files -all -quiet *pcie_lanes_early.xdc]
if {$early_xdc ne ""} { set_property PROCESSING_ORDER EARLY $early_xdc }
set pcie_xdc [get_files -all -quiet *PCIE_X0Y0.xdc]
if {$pcie_xdc ne ""} { set_property PROCESSING_ORDER NORMAL $pcie_xdc }

# ======================== 4. BD ========================
puts "=== 4. CREATE BLOCK DESIGN ==="
# Сначала создаём DFX Partition BD (RP = tdot_axi4)
source ${SCRIPTS_DIR}/dfx_partition_tdot.tcl

# Потом статический BD (XDMA, MIG, HWICAP, DFX Socket)
source ${SCRIPTS_DIR}/block_design_top.tcl

puts "=== BD complete ==="

# ======================== 5. WRAPPER ========================
puts "=== 5. GENERATE WRAPPER ==="
make_wrapper -files [get_files *xdma_ddr3_dfx.bd] -top -force
set_property top xdma_ddr3_dfx_wrapper [current_fileset]
update_compile_order -fileset sources_1
update_compile_order -fileset constrs_1

# ======================== 6. СИНТЕЗ ========================
puts "=== 6. SYNTHESIS ==="
reset_run synth_1
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTHESIS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    error "SYNTHESIS FAILED"
}

# ======================== 7. IMPL ========================
puts "=== 7. IMPLEMENTATION ==="
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set st2 [get_property STATUS [get_runs impl_1]]
puts "=== IMPLEMENTATION: $st2 ==="
if {[string first "complete" [string tolower $st2]] == -1} {
    error "IMPLEMENTATION FAILED"
}

# ======================== 8. BITSTREAM ========================
puts "=== 8. BITSTREAMS ==="
open_run impl_1
set bit_out "${BUILD_DIR}/${PROJ_NAME}/${PROJ_NAME}.runs/impl_1/xdma_ddr3_dfx_wrapper.bit"
write_bitstream -force -raw_bitfile -bin_file ${bit_out}
write_cfgmem -force -format mcs -size 128 -interface SPIx4 -loadbit "up 0x0 ${bit_out}" [file rootname ${bit_out}]

puts ""
puts "============================================"
puts "=== BUILD COMPLETE ==="
puts "BIT: ${bit_out}"
puts "BIN: [file rootname ${bit_out}].bin"
puts "MCS: [file rootname ${bit_out}].mcs"
puts "============================================"
close_project