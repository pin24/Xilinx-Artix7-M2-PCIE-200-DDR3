# ============================================================================
# gen_bitstream.tcl — полный цикл для СУЩЕСТВУЮЩЕГО DFX-проекта:
#   synth → impl → write_bitstream → экспорт артефактов
# Генерирует: .bit (JTAG/Flash), .bin (ICAP), .mcs (SPI Flash)
#           + частичные битстримы RP (*partial*) для горячей замены без JTAG.
#
# Поиск проекта (в порядке приоритета):
#   1) $::env(PROJ_DIR_BUILD) / $::env(PROJ_DIR)
#   2) ${REPO}/build/*/ (Linux-дефолт build_dfx.tcl)
#   3) C:/build_dfx/    (Windows-дефолт build_dfx.tcl)
#
# Run: vivado -mode batch -source scripts/gen_bitstream.tcl
# Примечание: создание проекта с нуля — scripts/build_dfx.tcl.
# ============================================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT       [file normalize "${SCRIPT_DIR}/.."]
set proj_name  m2_artix7_xdma_ddr3_dfx
set top_name   xdma_ddr3_core_top

set proj_dir ""
if {[info exists ::env(PROJ_DIR_BUILD)]} {
    set proj_dir ${::env(PROJ_DIR_BUILD)}
} elseif {[info exists ::env(PROJ_DIR)]} {
    set proj_dir ${::env(PROJ_DIR)}
} else {
    set cand [glob -nocomplain ${ROOT}/build/*/${proj_name}.xpr]
    if {[llength ${cand}] == 0} { set cand [glob -nocomplain C:/build_dfx/${proj_name}.xpr] }
    if {[llength ${cand}] > 0} { set proj_dir [file dirname [lindex ${cand} 0]] }
}
if {${proj_dir} eq "" || ![file exists ${proj_dir}/${proj_name}.xpr]} {
    puts "ERROR: проект ${proj_name}.xpr не найден."
    puts "Сначала выполните: vivado -mode batch -source scripts/build_dfx.tcl"
    exit 1
}
puts "=== Открытие проекта: ${proj_dir}/${proj_name}.xpr ==="
open_project ${proj_dir}/${proj_name}/${proj_name}.xpr

set_property top ${top_name} [current_fileset]
update_compile_order -fileset sources_1
update_compile_order -fileset constrs_1

# ---- 1. Синтез ----
puts "=== SYNTHESIS ==="
reset_run synth_1 -quiet
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    puts "=== SYNTHESIS FAILED ==="
    close_project
    exit 1
}

# ---- 2. Имплементация до write_bitstream ----
puts "=== IMPLEMENTATION ==="
catch {set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]}
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set st2 [get_property STATUS [get_runs impl_1]]
puts "=== IMPL STATUS: $st2 ==="
if {[string first "complete" [string tolower $st2]] == -1} {
    puts "=== IMPLEMENTATION FAILED ==="
    close_project
    exit 1
}

# ---- 3. Экспорт артефактов ----
set ARTIFACTS_DIR "${ROOT}/build/artifacts_dfx"
file mkdir ${ARTIFACTS_DIR}

puts "=== WRITE BITSTREAM (.bit) ==="
set bit_path "${ARTIFACTS_DIR}/${top_name}.bit"
write_bitstream -force ${bit_path}
puts "BIT: ${bit_path}"

puts "=== WRITE RAW BITSTREAM (.bin, ICAP) ==="
set bin_path "${ARTIFACTS_DIR}/${top_name}.bin"
write_bitstream -force -raw_bitfile -bin_file ${bin_path}
puts "BIN (ICAP): ${bin_path}"

puts "=== WRITE CFGMEM (.mcs, SPI Flash MT25QL128) ==="
set mcs_path "${ARTIFACTS_DIR}/${top_name}"
write_cfgmem -force -format mcs -size 128 -interface SPIx4 \
    -loadbit "up 0x0 ${bit_path}" \
    ${mcs_path}
puts "MCS: ${mcs_path}.mcs"

# ---- 4. Частичные битстримы RP (горячая замена без JTAG) ----
puts "=== COLLECT PARTIAL BITSTREAMS (RP) ==="
set partial_files [glob -nocomplain \
    ${proj_dir}/*.runs/*/*partial*.bit \
    ${proj_dir}/*.runs/*/*partial*.bin]
if {[llength ${partial_files}] == 0} {
    puts " WARNING: частичные битстримы не найдены в ${proj_dir}.runs/"
} else {
    foreach pfile ${partial_files} {
        file copy -force ${pfile} ${ARTIFACTS_DIR}/
        puts " PARTIAL: [file tail ${pfile}] -> ${ARTIFACTS_DIR}/"
    }
}

# ---- 5. Итог ----
puts "=== DONE ==="
puts "BIT  (JTAG/Flash): ${bit_path}"
puts "BIN  (ICAP):       ${bin_path}"
puts "MCS  (SPI Flash):  ${mcs_path}.mcs"
puts "PARTIAL (RP swap): ${ARTIFACTS_DIR}/*partial* -> pytorch_layer/dfx_swap.py"
close_project
