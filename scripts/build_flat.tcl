# ============================================================================
# build_flat.tcl — FULL FLAT (no-DFX) build of the project
#
# Creates a project from scratch, builds the FLAT BD (xdma_ddr3_bd.tcl),
# posts it (post_bd_flat.tcl), adds RTL + third_party HDL, constraints,
# runs synth + impl + bitstream + write_cfgmem (mcs size 128 SPIx4).
#
# Launch:
#   vivado.bat -mode batch -source scripts/build_flat.tcl
#
# Optional args (via -tclargs):
#   NUM_MAC=<16|32|64>   (default 16)
#   ADDERS=<N>           (default 4)
#   JOBS=<N>             (default 8)
#   SKIP_SYNTH=1         (only create the project, no build)
#
# Project: m2_artix7_xdma_flat, dir C:/build_flat
# Artifacts: build/artifacts_flat
#
# NO DFX machinery: no dfx_partition.bd, no apertures, no pblock, no partial
# reconfiguration, no child gate, no dfx_runtime, no DFX socket.
# ============================================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT       [file normalize "${SCRIPT_DIR}/.."]
set PROJ_NAME  "m2_artix7_xdma_flat"
# Project dir (portable): PROJ_DIR env wins; else C:/build_flat on Windows
# (short root to avoid MAX_PATH), else ${ROOT}/build/flat_proj.
if {[info exists ::env(PROJ_DIR)] && ${::env(PROJ_DIR)} ne ""} {
    set PROJ_DIR [file normalize ${::env(PROJ_DIR)}]
} elseif {$tcl_platform(platform) eq "windows"} {
    set PROJ_DIR "C:/build_flat"
} else {
    set PROJ_DIR [file normalize "${ROOT}/build/flat_proj"]
}
set ::env(PROJ_DIR_BUILD) ${PROJ_DIR}
set PART       "xc7a200tfbg484-2"
set TOP_NAME   "xdma_ddr3_core_top"
set ARTIFACTS_DIR "${ROOT}/build/artifacts_flat"

set NUM_MAC     16
set ADDERS      4
set JOBS        8
set SKIP_SYNTH  0

# ----------------------------------------------------------------------------
# Argument parsing, robust to shell '=' stripping (BUG-033).
# Supports: KEY=VALUE | KEY VALUE | -KEY VALUE (NUM_MAC/ADDERS/JOBS/SKIP_SYNTH).
# ----------------------------------------------------------------------------
set _nargs [llength $argv]
for {set _i 0} {$_i < $_nargs} {incr _i} {
    set _arg  [lindex $argv $_i]
    set _argn [string trimleft $_arg -]
    set _next [lindex $argv [expr {$_i + 1}]]
    if {[regexp {^(NUM_MAC|ADDERS|JOBS|SKIP_SYNTH)=(\d+)$} $_argn -> _k _v]} {
        set $_k $_v
        continue
    }
    if {[lsearch -exact {NUM_MAC ADDERS JOBS SKIP_SYNTH} $_argn] >= 0 && [regexp {^\d+$} $_next]} {
        set $_argn $_next
        incr _i
        continue
    }
}

puts "============================================================"
puts " BUILD_FLAT CONFIGURATION"
puts "============================================================"
puts " ROOT       : ${ROOT}"
puts " PROJ_DIR   : ${PROJ_DIR}"
puts " PART       : ${PART}"
puts " TOP        : ${TOP_NAME}"
puts " ARGS (raw) : ${argv}"
puts " NUM_MAC    : ${NUM_MAC}"
puts " ADDERS     : ${ADDERS}"
puts " JOBS       : ${JOBS}"
puts " SKIP_SYNTH : ${SKIP_SYNTH}"
puts "============================================================"

# ---------- 1. Create project (full cache cleanup) ----------
puts "=== 1. CREATE PROJECT ==="
file mkdir [file dirname ${PROJ_DIR}]

set CLEANUP_DIRS [list \
    ${PROJ_DIR} \
    [file normalize "${PROJ_DIR}.cache"] \
    [file normalize "${PROJ_DIR}.gen"] \
    [file normalize "${PROJ_DIR}.hw"] \
    [file normalize "${PROJ_DIR}.ip_user_files"] \
    [file normalize "${PROJ_DIR}.sim"] \
    [file normalize "[file dirname ${PROJ_DIR}]/.Xil"] \
]

set cleanup_failed 0
foreach dir_to_clean ${CLEANUP_DIRS} {
    if {[file exists ${dir_to_clean}]} {
        puts "=== Cleaning: ${dir_to_clean} ==="
        if {[catch {file delete -force ${dir_to_clean}} err]} {
            puts "WARNING: Cannot delete ${dir_to_clean}: $err"
            set cleanup_failed 1
        }
    }
}

if {$cleanup_failed} {
    puts ""
    puts "============================================================"
    puts " CLEANUP FAILED — files locked by another process"
    puts "------------------------------------------------------------"
    puts " 1. Close all Vivado: taskkill /f /im vivado.exe /im vivado.bat"
    puts " 2. rmdir /s /q ${PROJ_DIR}"
    puts " 3. Re-run: scripts\\build_flat.tcl"
    puts "============================================================"
    catch {close_project}
    exit 1
}

create_project -force ${PROJ_NAME} ${PROJ_DIR} -part ${PART}
set_property target_language Verilog [current_project]
set_property target_simulator XSim [current_project]

# ---------- 2a. Add HDL of inlined DataMover control modules ----------
puts "=== 2a. ADD FLAT INLINED HDL (up_axi + datamover_ctrl) ==="
set HDL_DIR "${ROOT}/third_party/m2-artix7-accelerator-card/hdl"
add_files -norecurse \
    ${HDL_DIR}/common/up_axi.v \
    ${HDL_DIR}/common/datamover_ctrl.v \
    ${HDL_DIR}/datamover_mm2s_ctrl/axi_datamover_mm2s_ctrl.v \
    ${HDL_DIR}/datamover_s2mm_ctrl/axi_datamover_s2mm_ctrl.v

# The module-referenced ctrl blocks (axi_datamover_mm2s_c_0 / s2mm_c_0) live in
# these files; they must be added BEFORE sourcing the BD script so BD can
# resolve can_resolve_reference.
set_property top ${TOP_NAME} [current_fileset]

# ---------- 2b. Create FLAT BD (xdma_ddr3_bd.tcl) ----------
puts "=== 2b. CREATE FLAT BD (xdma_ddr3_bd.tcl) ==="
source ${ROOT}/scripts/xdma_ddr3_bd.tcl

# ---------- 2c. Post-process FLAT BD (clock/irq export) ----------
puts "=== 2c. POST-PROCESS FLAT BD (post_bd_flat.tcl) ==="
open_bd_design [get_files xdma_ddr3_dfx.bd]
source ${ROOT}/scripts/post_bd_flat.tcl

# ---------- 2d. Configure BAR0 and re-assert canonical addresses ----------
puts "=== 2d. CONFIGURE BD: BAR0=128MB, ADDRESSES ==="
open_bd_design [get_files xdma_ddr3_dfx.bd]

set_property -dict [list \
    CONFIG.pf0_bar0_scale {Megabytes} \
    CONFIG.pf0_bar0_size {128} \
    CONFIG.axilite_master_scale {Megabytes} \
    CONFIG.axilite_master_size {128} \
] [get_bd_cells xdma_0]

set as_lite [get_bd_addr_spaces xdma_0/M_AXI_LITE]

# GPIO: 0x40020000
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_gpio_0_Reg}]
assign_bd_address -offset 0x40020000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force

# mm2s ctrl: 0x40010000
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_datamover_mm2s_c_0_reg0}]
assign_bd_address -offset 0x40010000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs axi_datamover_mm2s_c_0/s_axi/reg0] -force

# s2mm ctrl: 0x40018000
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_datamover_s2mm_c_0_reg0}]
assign_bd_address -offset 0x40018000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs axi_datamover_s2mm_c_0/s_axi/reg0] -force

# TDOT: 0x40023000
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_TDOT_REGS_Reg}]
assign_bd_address -offset 0x40023000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs S_AXI_TDOT_REGS/Reg] -force

# XADC: 0x46000000
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_XADC_REGS_Reg}]
assign_bd_address -offset 0x46000000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs S_AXI_XADC_REGS/Reg] -force

validate_bd_design
save_bd_design

# ---------- 3. Add RTL of the ternary core ----------
puts "=== 3. ADD RTL ==="
add_files -norecurse \
    ${ROOT}/rtl/block/tbyte_add.sv \
    ${ROOT}/rtl/block/tbyte_mul.sv \
    ${ROOT}/rtl/block/tfadd_raw.sv \
    ${ROOT}/rtl/block/tfadd48.sv \
    ${ROOT}/rtl/block/tfmul_raw.sv \
    ${ROOT}/rtl/block/compute_dot_par_raw.sv \
    ${ROOT}/rtl/integration/tdot_axi4.sv \
    ${ROOT}/rtl/integration/xadc_temp.sv \
    ${ROOT}/rtl/integration/xadc_prim.sv \
    ${ROOT}/rtl/integration/xdma_ddr3_core_top.sv \
    ${ROOT}/rtl/diag/diag_axi_sniffer.sv
# NOTE: icap_ctrl.sv / spi_over_pcie.sv are intentionally NOT added — the flat
# top RTL does not instantiate them. The files remain in the tree, unused.

set_property generic NUM_MAC=${NUM_MAC} [current_fileset]
set_property generic ADDERS=${ADDERS} [current_fileset]

# ---------- 4. Constraints (no pblock in flat) ----------
puts "=== 4. ADD CONSTRAINTS ==="
set pins_xdc   ${ROOT}/constraints/xdma_ddr3_pins.xdc
set early_xdc  ${ROOT}/constraints/xdma_ddr3_early.xdc
add_files -fileset constrs_1 ${pins_xdc}
add_files -fileset constrs_1 ${early_xdc}
set_property PROCESSING_ORDER EARLY  [get_files ${early_xdc}]
set_property PROCESSING_ORDER NORMAL [get_files ${pins_xdc}]
# pblock.xdc is NOT added: it exists only for DFX partial-reconfiguration
# (RP partitioning). Flat build has no RP. (File left in tree, unused.)
update_compile_order -fileset constrs_1

# Vivado 2025.2 DRC REQP-123 benign trigger for clk200_clk_wiz
set_property SEVERITY {Warning} [get_drc_checks REQP-123]

# ---------- 5. Regenerate wrapper ----------
puts "=== 5. REGENERATE WRAPPER ==="
make_wrapper -files [get_files xdma_ddr3_dfx.bd] -top -force
set_property top ${TOP_NAME} [current_fileset]
update_compile_order -fileset sources_1
update_compile_order -fileset constrs_1

# ---------- 6. Demote PCIe IP XDC ----------
puts "=== 6. DEMOTE PCIE IP XDC ==="
set pcie_ip_xdc [get_files -all -quiet *PCIE_X0Y0.xdc]
if {$pcie_ip_xdc ne ""} {
    set_property PROCESSING_ORDER NORMAL ${pcie_ip_xdc}
    puts "=== PCIE IP xdc set to NORMAL (pre-synth): ${pcie_ip_xdc} ==="
} else {
    puts "=== PCIE IP xdc not found yet (will retry after synth) ==="
}

if {${SKIP_SYNTH}} {
    puts "=== SKIP_SYNTH=1 — exiting before synth ==="
    close_project
    exit 0
}

# ---------- 7. Synthesis ----------
puts "=== 7. SYNTHESIS ==="
reset_run synth_1 -quiet
reset_run impl_1 -quiet
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
# BUG-047: apply set_clock_groups in PLACE_DESIGN.TCL.PRE (clocks exist in DCP).
set_property STEPS.PLACE_DESIGN.TCL.PRE ${ROOT}/scripts/timing_exceptions_post.tcl [get_runs impl_1]

launch_runs synth_1 -jobs ${JOBS}
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    puts "=== SYNTHESIS FAILED ==="
    close_project
    exit 1
}

# PCIe IP XDC demotion post-synth + GT LOC disable (BUG-051)
set pcie_ip_xdc [get_files -all -quiet *PCIE_X0Y0.xdc]
if {$pcie_ip_xdc ne ""} {
    set_property PROCESSING_ORDER NORMAL ${pcie_ip_xdc}
    set_property IS_ENABLED false ${pcie_ip_xdc}
    puts "=== PCIE IP xdc set to NORMAL + DISABLED (post-synth): ${pcie_ip_xdc} ==="
} else {
    puts "=== WARNING: PCIE IP xdc STILL not found after synth ==="
}

# ---------- 8. Implementation + Bitstream ----------
puts "=== 8. IMPLEMENTATION + BITSTREAM ==="
current_run [get_runs impl_1]
catch {set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]}
launch_runs impl_1 -to_step write_bitstream -jobs ${JOBS}
wait_on_run impl_1
set st2 [get_property STATUS [get_runs impl_1]]
puts "=== IMPL STATUS: $st2 ==="
if {[string first "complete" [string tolower $st2]] == -1} {
    puts "=== IMPLEMENTATION FAILED ==="
    close_project
    exit 1
}

# ---------- 8.5 FATAL TIMING GATE (BUG-038) ----------
# Flat design has no partial/RP implementations — gate only the top-level
# routed design. WNS/WHS/WPWS < 0 => build is FATAL, artifacts not exported.
puts "=== 8.5 FATAL TIMING GATE (BUG-038) ==="
source ${ROOT}/scripts/tcl_timing_lib.tcl
file mkdir ${ARTIFACTS_DIR}

if {[catch {open_run impl_1} gate_open_err]} {
    puts "ERROR: open_run impl_1 failed: ${gate_open_err}"
    close_project
    exit 1
}

set gate_fail 0
set all_viol [get_timing_paths -quiet -delay_type max -max_paths 0 -nworst 1 -slack_lesser_than 0]
if {[llength ${all_viol}] > 0} {
    set ws [get_property SLACK [lindex ${all_viol} 0]]
    set n_viol [llength ${all_viol}]
    puts "=== FATAL: ТАЙМИНГ НЕ ЗАКРЫТ по всему дизайну (WNS=${ws} ns, paths=${n_viol}) ==="
    set gate_fail 1
    set dom_pairs {}
    set diag_paths [get_timing_paths -quiet -delay_type max -max_paths 400 -nworst 1 -slack_lesser_than 0]
    foreach dp ${diag_paths} {
        set dsc ""; set dec ""
        catch {set dsc [get_property START_CLK ${dp}]}
        catch {set dec [get_property END_CLK   ${dp}]}
        if {${dsc} ne ""} { set dsc [get_property NAME ${dsc}] }
        if {${dec} ne ""} { set dec [get_property NAME ${dec}] }
        lappend dom_pairs "[format {START_CLK=%s END_CLK=%s} ${dsc} ${dec}]"
    }
    set seen {}
    set dom_unique {}
    foreach p ${dom_pairs} {
        if {[lsearch -exact ${seen} ${p}] == -1} {
            lappend seen       ${p}
            lappend dom_unique ${p}
        }
    }
    puts "=== Затронутые домены (START→END) ==="
    foreach d ${dom_unique} { puts "    ${d}" }
} else {
    puts "=== FATAL GATE: ТАЙМИНГ MET по ВСЕМ доменам (0 violations) ==="
}

if {${gate_fail}} {
    report_timing_summary -quiet -file ${ARTIFACTS_DIR}/timing_FATAL.rpt
    set wpaths [get_timing_paths -quiet -delay_type max -max_paths 10 -nworst 1 -slack_lesser_than 0]
    set wi 0
    foreach wp ${wpaths} {
        set wsp ""; set wep ""
        catch {set wsp [get_property STARTPOINT_PIN ${wp}]}
        catch {set wep [get_property ENDPOINT_PIN ${wp}]}
        puts [format "  FATAL PATH #%d slack %s ns: %s -> %s" \
            ${wi} [get_property SLACK ${wp}] ${wsp} ${wep}]
        incr wi
    }
    puts "=== FATAL: тайминг не закрыт — артефакты НЕ экспортируются (timing_FATAL.rpt) ==="
    close_project
    exit 1
}

# ---------- 9. Export artifacts (no partials in flat) ----------
puts "=== 9. EXPORT ARTIFACTS ==="
if {[catch {current_design} _cur_dsn] != 0 || ${_cur_dsn} eq ""} {
    open_run impl_1
}

file mkdir ${ARTIFACTS_DIR}

set bit_file "${ARTIFACTS_DIR}/${TOP_NAME}.bit"
set mcs_file "${ARTIFACTS_DIR}/${TOP_NAME}.mcs"

write_bitstream -force -raw_bitfile -bin_file ${bit_file}
write_cfgmem -force -format mcs -size 128 -interface SPIx4 \
    -loadbit "up 0x0 ${bit_file}" ${mcs_file}

foreach rpt {utilization.txt timing_summary.rpt} {
    set src ""
    catch { set src [get_property DIRECTORY [get_runs impl_1]]/${rpt} }
    if {[file exists ${src}]} {
        file copy -force ${src} ${ARTIFACTS_DIR}/${rpt}
    }
}

close_project

puts "============================================================"
puts " BUILD_FLAT COMPLETE"
puts "============================================================"
puts " Bitstream : ${bit_file}"
puts " MCS       : ${mcs_file}"
puts " Artifacts : ${ARTIFACTS_DIR}"
puts " No partial / DFX artifacts (flat design)."
puts "============================================================"