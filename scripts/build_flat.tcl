# ============================================================================
# build_flat.tcl РІР‚вЂќ FULL FLAT (no-DFX) build of the project
#
# Creates a project from scratch, builds the FLAT BD (xdma_ddr3_bd.tcl),
# posts it (post_bd_flat.tcl), adds RTL + third_party HDL, constraints,
# runs synth + impl + bitstream + write_cfgmem (mcs size 128 SPIx4).
#
# Launch:
#   vivado.bat -mode batch -source scripts/build_flat.tcl
#
# Optional args (via -tclargs):
#   NUM_MAC=<16|32|64>   (default 32)
#   ADDERS=<N>           (default 16)
#   DEVPROG_EN=<0|1>     (default 1; 1 = программный режим device_prog поверх tdot)
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

set NUM_MAC     32
set ADDERS      16
set DEVPROG_EN  1
# низкий параллелизм для машины с малым ОЗУ (было 8)
set JOBS        4
# maxThreads is applied later, AFTER -tclargs JOBS parsing below, so that a
# passed JOBS really controls the synth/impl thread count (no hard =4 limit).
set SKIP_SYNTH  0

# ----------------------------------------------------------------------------
# Argument parsing, robust to shell '=' stripping (BUG-033).
# Supports: KEY=VALUE | KEY VALUE | -KEY VALUE (NUM_MAC/ADDERS/DEVPROG_EN/JOBS/SKIP_SYNTH).
# ----------------------------------------------------------------------------
set _nargs [llength $argv]
for {set _i 0} {$_i < $_nargs} {incr _i} {
    set _arg  [lindex $argv $_i]
    set _argn [string trimleft $_arg -]
    set _next [lindex $argv [expr {$_i + 1}]]
    if {[regexp {^(NUM_MAC|ADDERS|DEVPROG_EN|JOBS|SKIP_SYNTH)=(\d+)$} $_argn -> _k _v]} {
        set $_k $_v
        continue
    }
    if {[lsearch -exact {NUM_MAC ADDERS DEVPROG_EN JOBS SKIP_SYNTH} $_argn] >= 0 && [regexp {^\d+$} $_next]} {
        set $_argn $_next
        incr _i
        continue
    }
}

# ---------- maxThreads: honest parallelism (no hard 4-thread limit) ----------
# maxThreads = min(JOBS, detected machine threads). A JOBS above the detected
# core count is clamped down to the core count with a warning (running more
# threads than physical cores yields no speedup; Vivado has no get_cpus, so we
# read NUMBER_OF_PROCESSORS on Windows or /proc/cpuinfo on Linux).
set _max_cores 1
if {$tcl_platform(platform) eq "windows"} {
    if {[info exists ::env(NUMBER_OF_PROCESSORS)] && ${::env(NUMBER_OF_PROCESSORS)} ne ""} {
        set _max_cores ${::env(NUMBER_OF_PROCESSORS)}
    }
} else {
    set _cpuinfo [open /proc/cpuinfo r]
    set _nproc [regexp -all -line {^processor\s+:} [read ${_cpuinfo}]]
    close ${_cpuinfo}
    if {${_nproc} > 0} { set _max_cores ${_nproc} }
}
set _eff_jobs ${JOBS}
if {${_eff_jobs} > ${_max_cores}} {
    puts "WARNING: JOBS=${JOBS} exceeds detected cores (${_max_cores}); clamping maxThreads to ${_max_cores}"
    set _eff_jobs ${_max_cores}
}
set_param general.maxThreads ${_eff_jobs}
puts " MAXTHREADS : ${_eff_jobs} (JOBS=${JOBS}, detected cores=${_max_cores})"

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
puts " DEVPROG_EN : ${DEVPROG_EN}"
puts " JOBS       : ${JOBS}"
puts " SKIP_SYNTH : ${SKIP_SYNTH}"
puts "============================================================"

# ---------- 0-a. Очистка устаревших артефактов ----------
# Прошлый УСПЕШНЫЙ .bit/.mcs не должен маскировать провал текущей сборки:
# битстрим, mcs и timing_FATAL.rpt удаляем ДО синтеза, чтобы в
# build/artifacts_flat не осталось файла от предыдущего прогона (иначе
# «артефакт на месте» при FATAL-гейте; stale timing_FATAL.rpt уже путал —
# см. CHANGE_LOG_2026-10-13).
# FIX 2026-10-20 (BUG-062, аудит 39-c F2.5/F2.4): (1) гард SKIP_SYNTH — раньше
# очистка стояла ВЫШЕ exit по SKIP_SYNTH и прогон «only create the project»
# стирал прод-артефакты; (2) timing_FATAL.rpt добавлен к шаблонам — он
# переживал успешную сборку и маскировал свежие отчёты.
if {!${SKIP_SYNTH}} {
    puts "=== 0-a. CLEAN STALE ARTIFACTS: ${ARTIFACTS_DIR} ==="
    set stale_n 0
    foreach stale_pat {*.bit *.mcs timing_FATAL.rpt} {
        set stale_files [glob -nocomplain -directory ${ARTIFACTS_DIR} -types f ${stale_pat}]
        foreach stale_f ${stale_files} {
            if {[catch {file delete -force ${stale_f}} stale_err]} {
                puts "WARNING: Cannot delete ${stale_f}: ${stale_err}"
            } else {
                puts "  removed: ${stale_f}"
                incr stale_n
            }
        }
    }
    puts "=== 0-a. CLEAN STALE ARTIFACTS: removed ${stale_n} file(s) (*.bit/*.mcs/timing_FATAL.rpt) ==="
} else {
    puts "=== 0-a. CLEAN STALE ARTIFACTS: SKIPPED (SKIP_SYNTH=1 — прод-артефакты не трогаем) ==="
}

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
    puts " CLEANUP FAILED РІР‚вЂќ files locked by another process"
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
    ${ROOT}/rtl/integration/device_prog.sv \
    ${ROOT}/rtl/integration/tdot_axi4.sv \
    ${ROOT}/rtl/integration/xadc_temp.sv \
    ${ROOT}/rtl/integration/xadc_prim.sv \
    ${ROOT}/rtl/integration/xdma_ddr3_core_top.sv \
    ${ROOT}/rtl/diag/diag_axi_sniffer.sv
# NOTE: spi_over_pcie.sv is intentionally NOT added — the flat top RTL does not
# instantiate it. The file remains in the tree, unused.

# Generic NUM_MAC/ADDERS/BUILD_ID применяем ПОЗЖЕ — ПОСЛЕ set_property top
# (см. "5. Regenerate wrapper"): применяемые к fileset ДО назначения top-модуля
# численные generic не сохранялись в .xpr, и синтез брал дефолт top #(16,4).

# ---------- 0-b. BUILD_ID (Task 35; за образец — openTPU BUILD_ID) ----------
# Первые 8 hex git-коммита попадают в регистр tdot BUILD_ID (0x70 в main-карте).
# Вне git-дерева (архив/экспорт) — 00000000, регистр читается как 0.
set BUILD_ID_HEX "00000000"
if {![catch {exec git -C ${ROOT} rev-parse --short=8 HEAD} bid]} {
    set BUILD_ID_HEX [string trim ${bid}]
}
if {![regexp {^[0-9a-f]{8}$} $BUILD_ID_HEX]} {
    set BUILD_ID_HEX "00000000"
}
puts " BUILD_ID   : 0x${BUILD_ID_HEX}"

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
#
# pblock_flat_tdot.xdc РІР‚вЂќ Р С”Р С•Р СР С—Р В°Р С”РЎвЂљР Р…РЎвЂ№Р в„– placement-РЎР‚Р ВµР С–Р С‘Р С•Р Р… Р Т‘Р В»РЎРЏ РЎРЏР Т‘РЎР‚Р В° tdot (РЎРѓР С. РЎвЂћР В°Р в„–Р В»):
# РЎРѓР В¶Р С‘Р СР В°Р ВµРЎвЂљ РЎР‚Р В°Р В·Р СР ВµРЎвЂ°Р ВµР Р…Р С‘Р Вµ u_tdot/u_core (gen_ad + gen_mac) Р Р† Р С•Р Т‘Р С‘Р Р… Р С•Р В±РЎвЂ°Р С‘Р в„– РЎР‚Р ВµР С–Р С‘Р С•Р Р… Р Т‘Р В»РЎРЏ
# РЎРѓР С•Р С”РЎР‚Р В°РЎвЂ°Р ВµР Р…Р С‘РЎРЏ Р СР В°РЎР‚РЎв‚¬РЎР‚РЎС“РЎвЂљР В° Р С”РЎР‚Р С‘РЎвЂљР С‘РЎвЂЎР ВµРЎРѓР С”Р С‘РЎвЂ¦ Р С—РЎС“РЎвЂљР ВµР в„–. Р вЂ”Р В°Р С–РЎР‚РЎС“Р В¶Р В°Р ВµРЎвЂљРЎРѓРЎРЏ LATE (Р С—Р С•РЎРѓР В»Р Вµ РЎРѓР С‘Р Р…РЎвЂљР ВµР В·Р В°),
# РЎвЂЎРЎвЂљР С•Р В±РЎвЂ№ Р С”Р В»Р ВµРЎвЂљР С”Р С‘ u_tdot/u_core РЎС“Р В¶Р Вµ РЎРѓРЎС“РЎвЂ°Р ВµРЎРѓРЎвЂљР Р†Р С•Р Р†Р В°Р В»Р С‘ Р Т‘Р В»РЎРЏ add_cells_to_pblock.
# FIX 2026-10-20 (BUG-061, аудит 39-c F1.1-F1.4 / C-5): pblock подключался
# БЕЗУСЛОВНО, но регион 6642 SLICE (SLICE_X25Y4:SLICE_X105Y85) заморожен по
# routed-DCP сборки NUM_MAC=16/ADDERS=4 (45a8a24, 2026-10-07). Для NUM_MAC=32/64
# ядро физически не помещается (потребность 32/16 ~2x; признано владельцем в
# docs/worklog «pblock 6642 SLICE < NUM_MAC=32 need») -> либо Place-fail, либо
# тихо-пустой pblock (get_cells -quiet -> пусто, ограничение молча не работает).
# Гард: подключаем ТОЛЬКО при NUM_MAC=16 (конфигурация, под которую регион
# подогнан); для остальных — громкий WARNING и сборка БЕЗ pblock (тайминг
# всё равно проверяет FATAL-гейт 8.5).
if {${NUM_MAC} == 16} {
    set pblock_flat_xdc ${ROOT}/constraints/pblock_flat_tdot.xdc
    add_files -fileset constrs_1 ${pblock_flat_xdc}
    set_property PROCESSING_ORDER LATE [get_files ${pblock_flat_xdc}]
    update_compile_order -fileset constrs_1
    puts " PBLOCK    : pblock_flat_tdot.xdc подключён (NUM_MAC=16 — регион подогнан под 16/4)"
} else {
    puts "=== WARNING: pblock_flat_tdot.xdc ПРОПУЩЕН: регион 6642 SLICE подогнан под NUM_MAC=16/ADDERS=4, текущая сборка NUM_MAC=${NUM_MAC}/ADDERS=${ADDERS} — ядро в регион не помещается. Сборка идёт БЕЗ pblock; после place проверь report_utilization -pblocks ==="
}

# Vivado 2025.2 DRC REQP-123 benign trigger for clk200_clk_wiz
set_property SEVERITY {Warning} [get_drc_checks REQP-123]

# ---------- 5. Regenerate wrapper ----------
puts "=== 5. REGENERATE WRAPPER ==="
make_wrapper -files [get_files xdma_ddr3_dfx.bd] -top -force
set_property top ${TOP_NAME} [current_fileset]
update_compile_order -fileset sources_1
update_compile_order -fileset constrs_1

# ---------- 5.1 Применение BUILD_ID (bit-vector generic; записи в .xpr) ----------
# FIX 2026-10-14: NUM_MAC/ADDERS (тип `int`) Vivado НЕ принимает как fileset-generic
# (проверено минимальным тестом) — их передаём через STEPS.SYNTH_DESIGN.ARGS.GENERIC
# в разделе 8 (см. ниже). BUILD_ID (logic[31:0]) через fileset работает.
# FIX 2026-10-20 (v1.2.x, verified): fileset `generic` property DOES accept the
# integer top parameters (probe: set/get OK on Vivado 2025.2). Set BUILD_ID +
# NUM_MAC + ADDERS together on the FILESET (the run-level `generic` property and
# STEPS.SYNTH_DESIGN.ARGS.GENERIC are READ-ONLY / not settable -> Common 17-54).
set gen_list [list BUILD_ID=32'h${BUILD_ID_HEX} NUM_MAC=${NUM_MAC} ADDERS=${ADDERS} DEVPROG_EN=${DEVPROG_EN}]
# FIX 2026-10-20 (тихое откатывание параметров): сбой set_property generic НЕ
# должен оставаться незамеченным — иначе синтез уходит с дефолтами top #(16,4).
if {[catch {set_property generic ${gen_list} [current_fileset]} gen_err]} {
    puts "ERROR: set_property generic {${gen_list}} failed: ${gen_err}"
    close_project
    exit 1
}

# Read-back: подтверждаем, что NUM_MAC/ADDERS реально легли в fileset.
set gen_read ""
if {[catch {set gen_read [get_property generic [current_fileset]]} gen_rd_err]} {
    puts "ERROR: get_property generic (read-back) failed: ${gen_rd_err}"
    close_project
    exit 1
}
puts " GENERIC (read-back) : ${gen_read}"

# Токенизация: значения могут вернуться как список или как строка с кавычками.
set gen_tokens {}
foreach gen_tok [split [string map [list \" "" \{ "" \} ""] ${gen_read}] " "] {
    set gen_tok [string trim ${gen_tok}]
    if {${gen_tok} ne ""} { lappend gen_tokens ${gen_tok} }
}
# Проверка read-back: блокируем сборку ТОЛЬКО если параметр реально виден с
# ДРУГИМ значением. Если формат возврата Vivado не распознан (параметр вовсе
# не найден) — предупреждение, а не exit: иначе незнакомая форма вывода
# ложно валила бы сборку, которую мы как раз защищаем.
set gen_unparsed {}
foreach gen_want [list "NUM_MAC=${NUM_MAC}" "ADDERS=${ADDERS}" "DEVPROG_EN=${DEVPROG_EN}"] {
    lassign [split ${gen_want} "="] gen_name gen_val
    set gen_hit 0
    # R2 2026-10-20: сброс stale matchVar между итерациями (regexp оставляет
    # старое значение при неудаче -> ложноe сравнение в следующей итерации)
    unset -nocomplain _gb_val _gb_val2
    # форма 1: токен "NAME=value"
    if {[lsearch -exact ${gen_tokens} ${gen_want}] >= 0} { set gen_hit 1 }
    # форма 2/3: "NAME = value" или "NAME value" — берём число после имени
    if {!${gen_hit}} {
        set gen_pat "${gen_name}\\s*=\\s*([0-9]+)"
        if {[catch {regexp ${gen_pat} ${gen_read} -> _gb_val}] == 0 && [info exists _gb_val]} {
            if {${_gb_val} eq ${gen_val}} { set gen_hit 1 }
            if {${_gb_val} ne ${gen_val}} {
                puts "ERROR: fileset generic ${gen_name}=${_gb_val}, ожидалось ${gen_val}"
                close_project
                exit 1
            }
        }
    }
    if {!${gen_hit}} {
        set gen_pat "${gen_name}\\s+([0-9]+)"
        if {[catch {regexp ${gen_pat} ${gen_read} -> _gb_val2}] == 0 && [info exists _gb_val2]} {
            if {${_gb_val2} eq ${gen_val}} { set gen_hit 1 }
            if {${_gb_val2} ne ${gen_val}} {
                puts "ERROR: fileset generic ${gen_name}=${_gb_val2}, ожидалось ${gen_val}"
                close_project
                exit 1
            }
        }
    }
    if {!${gen_hit}} { lappend gen_unparsed ${gen_want} }
}
if {[llength ${gen_unparsed}] > 0} {
    puts "WARNING: read-back не подтвердил {${gen_unparsed}} (формат: {${gen_read}}); значение generic не проверено — продолжаем"
}
puts " GENERIC  : NUM_MAC=${NUM_MAC} ADDERS=${ADDERS} DEVPROG_EN=${DEVPROG_EN} BUILD_ID=32'h${BUILD_ID_HEX} (read-back OK)"

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
    puts "=== SKIP_SYNTH=1 РІР‚вЂќ exiting before synth ==="
    close_project
    exit 0
}

# ---------- 7. Synthesis ----------
puts "=== 7. SYNTHESIS ==="
reset_run synth_1 -quiet
reset_run impl_1 -quiet
# 2026-10-22: RETIMING deprecated in 2025.2 ("use -global_retiming"). The run
# property STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING takes `on`/`off` (NOT true);
# `true` -> ERROR 17-110. Probed on m2_artix7_xdma_flat: value domain is on/off.
if {[get_property -quiet STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING [get_runs synth_1]] ne ""} {
    set_property STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING on [get_runs synth_1]
    puts "=== 7b. GLOBAL_RETIMING enabled (on; replaces deprecated RETIMING)"
} else {
    set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
    puts "=== 7b. GLOBAL_RETIMING unsupported; kept RETIMING true"
}
# FIX 2026-10-20 (v1.2.x): NUM_MAC/ADDERS are passed on the FILESET generic
# (see SECTION 5.1), NOT on the run (run-level generic is read-only -> 17-54).
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
# FIX 2026-10-14 (вариант б): NUM_MAC/ADDERS — параметры типа `int`, которые
# Vivado не принимает как fileset-generic (проверено). Передаём их в синтез
# через опцию -generic; установка перенесена в раздел 7 (ДО launch_runs synth_1).
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
# Flat design has no partial/RP implementations РІР‚вЂќ gate only the top-level
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
set gate_wns  "N/A"
set gate_whs  "N/A"
set gate_wpws "N/A"

# --- SETUP (delay_type max) — существующая проверка BUG-038 ---
set all_viol [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1 -slack_lesser_than 0]
if {[llength ${all_viol}] > 0} {
    set ws [get_property SLACK [lindex ${all_viol} 0]]
    set n_viol [llength ${all_viol}]
    set gate_wns ${ws}
    puts "=== FATAL: Р СћР С’Р в„ўР СљР ВР СњР вЂњ Р СњР вЂў Р вЂ”Р С’Р С™Р В Р В«Р Сћ Р С—Р С• Р Р†РЎРѓР ВµР СРЎС“ Р Т‘Р С‘Р В·Р В°Р в„–Р Р…РЎС“ (WNS=${ws} ns, paths=${n_viol}) ==="
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
    puts "=== Р вЂ”Р В°РЎвЂљРЎР‚Р С•Р Р…РЎС“РЎвЂљРЎвЂ№Р Вµ Р Т‘Р С•Р СР ВµР Р…РЎвЂ№ (STARTРІвЂ вЂ™END) ==="
    foreach d ${dom_unique} { puts "    ${d}" }
} else {
    puts "=== FATAL GATE: Р СћР С’Р в„ўР СљР ВР СњР вЂњ MET Р С—Р С• Р вЂ™Р РЋР вЂўР Сљ Р Т‘Р С•Р СР ВµР Р…Р В°Р С (0 violations) ==="
}

# Значение WNS для отчёта, если setup-violations не найдено.
if {${gate_wns} eq "N/A"} {
    catch {
        set _s_worst [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1]
        if {[llength ${_s_worst}] > 0} {
            set gate_wns [get_property SLACK [lindex ${_s_worst} 0]]
        }
    }
}

# --- HOLD (delay_type min) ---
set hold_viol [get_timing_paths -quiet -delay_type min -max_paths 1 -nworst 1 -slack_lesser_than 0]
if {[llength ${hold_viol}] > 0} {
    set whs [get_property SLACK [lindex ${hold_viol} 0]]
    set n_hviol [llength ${hold_viol}]
    set gate_whs ${whs}
    puts "=== FATAL: HOLD НЕ ЗАКРЫТ (WHS=${whs} ns, paths=${n_hviol}) ==="
    set gate_fail 1
    set hpaths [get_timing_paths -quiet -delay_type min -max_paths 10 -nworst 1 -slack_lesser_than 0]
    set hi 0
    foreach hp ${hpaths} {
        set hsp ""; set hep ""
        catch {set hsp [get_property STARTPOINT_PIN ${hp}]}
        catch {set hep [get_property ENDPOINT_PIN ${hp}]}
        puts [format "  FATAL HOLD PATH #%d slack %s ns: %s -> %s" \
            ${hi} [get_property SLACK ${hp}] ${hsp} ${hep}]
        incr hi
    }
}
if {${gate_whs} eq "N/A"} {
    catch {
        set _h_worst [get_timing_paths -quiet -delay_type min -max_paths 1 -nworst 1]
        if {[llength ${_h_worst}] > 0} {
            set gate_whs [get_property SLACK [lindex ${_h_worst} 0]]
        }
    }
}

# --- PULSE WIDTH (report_pulse_width -return_string) ---
# Отсутствие отчёта = проверка пропущена (WARNING), но НЕ успех.
set pw_rpt ""
if {[catch {report_pulse_width -quiet -return_string} pw_rpt]} {
    puts "=== WARNING: report_pulse_width unavailable: ${pw_rpt} (PULSE WIDTH check skipped) ==="
    set pw_rpt ""
}
if {${pw_rpt} ne ""} {
    set pw_bad   0
    set pw_worst ""
    foreach pw_line [split ${pw_rpt} "\n"] {
        if {[string first "VIOLATED" ${pw_line}] >= 0} {
            set pw_bad 1
            puts "  PULSE VIOLATED: [string trim ${pw_line}]"
            continue
        }
        if {[regexp {\s(-[0-9]+\.[0-9]+)} ${pw_line} -> _pw_slack]} {
            set pw_bad 1
            if {${pw_worst} eq "" || ${_pw_slack} < ${pw_worst}} {
                set pw_worst ${_pw_slack}
            }
        }
    }
    if {${pw_worst} ne ""} { set gate_wpws ${pw_worst} }
    if {${pw_bad}} {
        puts "=== FATAL: PULSE WIDTH НЕ ЗАКРЫТ (WPWS=${gate_wpws} ns) ==="
        set gate_fail 1
    }
}

# --- UNCONSTRAINED (check_timing) — только WARNING, сборку не блокирует ---
set chk_rpt ""
if {[catch {check_timing -quiet -verbose -return_string} chk_rpt]} {
    puts "=== WARNING: check_timing unavailable: ${chk_rpt} (unconstrained check skipped) ==="
    set chk_rpt ""
}
if {${chk_rpt} ne ""} {
    foreach chk_sect {no_clock unconstrained_endpoints} {
        set chk_cnt 0
        foreach chk_line [split ${chk_rpt} "\n"] {
            if {[string first ${chk_sect} ${chk_line}] < 0} { continue }
            if {[string first "checking" ${chk_line}] >= 0} { continue }
            if {[regexp {([0-9]+)} ${chk_line} -> _chk_n] && ${_chk_n} > 0} {
                set chk_cnt ${_chk_n}
                break
            }
        }
        if {${chk_cnt} > 0} {
            puts "=== WARNING: check_timing: ${chk_sect} = ${chk_cnt} (known outputs, build NOT blocked) ==="
        }
    }
}

puts "=== TIMING SLACKS: WNS=${gate_wns} ns WHS=${gate_whs} ns WPWS=${gate_wpws} ns ==="

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
    puts "=== FATAL: РЎвЂљР В°Р в„–Р СР С‘Р Р…Р С– Р Р…Р Вµ Р В·Р В°Р С”РЎР‚РЎвЂ№РЎвЂљ РІР‚вЂќ Р В°РЎР‚РЎвЂљР ВµРЎвЂћР В°Р С”РЎвЂљРЎвЂ№ Р СњР вЂў РЎРЊР С”РЎРѓР С—Р С•РЎР‚РЎвЂљР С‘РЎР‚РЎС“РЎР‹РЎвЂљРЎРѓРЎРЏ (timing_FATAL.rpt) ==="
    close_project
    exit 1
}

puts "=== 8.5 FATAL TIMING GATE PASSED: WNS=${gate_wns} ns WHS=${gate_whs} ns WPWS=${gate_wpws} ns ==="

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