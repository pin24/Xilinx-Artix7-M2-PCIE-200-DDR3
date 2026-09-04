# ============================================================================
# gen_bin_mcs.tcl — ТОЛЬКО экспорт артефактов из готового DFX-проекта
# (без пересинтеза): .bin (ICAP) и .mcs (SPI Flash) из завершённого impl_1.
#
# Поиск проекта: $::env(PROJ_DIR_BUILD) / $::env(PROJ_DIR) →
#                ${REPO}/build/*/ → C:/build_dfx (легаси).
#
# Run: vivado -mode batch -source scripts/gen_bin_mcs.tcl
# ============================================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT       [file normalize "${SCRIPT_DIR}/.."]
set proj_name  m2_artix7_xdma_ddr3_dfx
set top        xdma_ddr3_core_top

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
    puts "ERROR: проект ${proj_name}.xpr не найден (PROJ_DIR='${proj_dir}')."
    exit 1
}

open_project ${proj_dir}/${proj_name}/${proj_name}.xpr
open_run impl_1

set ARTIFACTS_DIR "${ROOT}/build/artifacts_dfx"
file mkdir ${ARTIFACTS_DIR}

set bit_path "${ARTIFACTS_DIR}/${top}.bit"
write_bitstream -force -raw_bitfile -bin_file ${bit_path}
write_cfgmem -force -format mcs -size 128 -interface SPIx4 \
    -loadbit "up 0x0 ${bit_path}" "${ARTIFACTS_DIR}/${top}"
puts "BIT: ${bit_path}"
puts "BIN: ${ARTIFACTS_DIR}/${top}.bin"
puts "MCS: ${ARTIFACTS_DIR}/${top}.mcs"

# Частичные битстримы RP (горячая замена без JTAG)
set partial_files [glob -nocomplain \
    ${proj_dir}/*.runs/*/*partial*.bit \
    ${proj_dir}/*.runs/*/*partial*.bin]
foreach pfile ${partial_files} {
    file copy -force ${pfile} ${ARTIFACTS_DIR}/
    puts "PARTIAL: [file tail ${pfile}] -> ${ARTIFACTS_DIR}/"
}

close_project
