# ============================================================================
# gen_bin_mcs.tcl - re-export .bit/.bin/.mcs (+ RP partials) from an EXISTING
# impl_1 run, WITHOUT re-synthesis. Makes the Makefile target `make artifacts`
# work (E-10 in driver/ERROR-FIX-LOG.md: the script referenced by the Makefile
# was missing).
#
# Usage:  vivado.bat -mode batch -source scripts/gen_bin_mcs.tcl
# Requires: project already built at C:/build_dfx (run `make build` first).
# ============================================================================
set PROJ_DIR  "C:/build_dfx"
set PROJ_NAME "m2_artix7_xdma_ddr3_dfx"
set TOP_NAME  "xdma_ddr3_core_top"
set ROOT      [file normalize [file join [file dirname [info script]] ..]]
set ARTIFACTS_DIR [file join ${ROOT} build artifacts_dfx]

set xpr [file join ${PROJ_DIR} ${PROJ_NAME}.xpr]
if {![file exists ${xpr}]} {
    puts "ERROR: project not found: ${xpr} - run 'make build' first"
    exit 1
}

open_project ${xpr}
open_run impl_1

file mkdir ${ARTIFACTS_DIR}
set bit_file [file join ${ARTIFACTS_DIR} "${TOP_NAME}.bit"]
write_bitstream -force -raw_bitfile -bin_file ${bit_file}
write_cfgmem -force -format mcs -size 128 -interface SPIx4 \
    -loadbit "up 0x0 ${bit_file}" [file join ${ARTIFACTS_DIR} "${TOP_NAME}.mcs"]

foreach rpt {utilization.txt timing_summary.rpt} {
    set src ""
    catch { set src [get_property DIRECTORY [get_runs impl_1]]/${rpt} }
    if {[file exists ${src}]} {
        file copy -force ${src} [file join ${ARTIFACTS_DIR} ${rpt}]
    }
}

foreach p [glob -nocomplain ${PROJ_DIR}.runs/*/*partial*.bit ${PROJ_DIR}.runs/*/*partial*.bin] {
    file copy -force ${p} ${ARTIFACTS_DIR}
}

puts "=== ARTIFACTS EXPORTED: ${ARTIFACTS_DIR} ==="
exit 0
