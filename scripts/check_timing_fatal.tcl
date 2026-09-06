# ============================================================================
# check_timing_fatal.tcl — FATAL-гейт тайминга для произвольного чекпоинта
# ============================================================================
# Usage:
#   vivado -mode batch -source scripts/check_timing_fatal.tcl -tclargs [dcp]
#
#   dcp — опционально: путь к checkpoint (impl_1/*.dcp или child impl).
#   Без аргумента: ищет impl_1 проекта (PROJ_DIR_BUILD / PROJ_DIR / build/).
#
# Возвращает exit code:
#   0 — тайминг MET;
#   1 — FATAL (WNS/WHS/WPWS < 0) или чекпоинт/отчёт недоступны.
#
# Конвенция BUG-035 (2026-09-06): битстрим с нарушенным таймингом считается
# фатальным браком; сборка/CI обязаны падать с exit 1. "Следить за таймингами"
# = прогонять этот скрипт на каждом чекпоинте до и после экспорта артефактов.
# ============================================================================

set SELF_DIR [file dirname [file normalize [info script]]]
source [file join $SELF_DIR tcl_timing_lib.tcl]

# ---------- 1. Открыть дизайн --------------------------------------------------
set dcp_arg ""
if {[info exists argv] && [llength $argv] >= 1} {
    set dcp_arg [lindex $argv 0]
}

set opened_here 0
if {$dcp_arg ne ""} {
    if {![file exists $dcp_arg]} {
        puts "ERROR: checkpoint не найден: $dcp_arg"
        exit 1
    }
    open_checkpoint $dcp_arg
    set opened_here 1
} else {
    # дизайн уже открыт (интерактивный режим)?
    if {[catch {current_design} cur] != 0 || $cur eq ""} {
        # ищем impl_1 checkpoint
        set cand [list]
        foreach base [list [expr {[info exists ::env(PROJ_DIR_BUILD)] ? ${::env(PROJ_DIR_BUILD)} : ""}] \
                           [expr {[info exists ::env(PROJ_DIR)] ? ${::env(PROJ_DIR)} : ""}] \
                           [file normalize "$SELF_DIR/../build"]] {
            if {$base eq ""} { continue }
            set cand [glob -nocomplain [file join $base *.runs impl_1 *.dcp]]
            if {[llength $cand] > 0} { break }
        }
        if {[llength $cand] == 0} {
            puts "ERROR: не найден impl_1 checkpoint. Укажите .dcp аргументом:"
            puts "  vivado -mode batch -source scripts/check_timing_fatal.tcl -tclargs <path.dcp>"
            exit 1
        }
        set dcp_arg [lindex [lsort -command {apply {{a b} {string compare [file mtime $a] [file mtime $b]}}} $cand] end]
        puts "=== Найден checkpoint (самый свежий): $dcp_arg ==="
        open_checkpoint $dcp_arg
        set opened_here 1
    }
}

# ---------- 2. Отчёт + гейт ------------------------------------------------------
set rpt_path "[file rootname $dcp_arg]_timing_gate.rpt"
if {$rpt_path eq "_timing_gate.rpt"} { set rpt_path "timing_gate.rpt" }

if {[catch {report_timing_summary -quiet -warn_on_violation -file $rpt_path} rpt_err]} {
    puts "ERROR: report_timing_summary failed: $rpt_err"
    if {$opened_here} { close_design }
    exit 1
}

set summary [::timing::parse_summary_rpt $rpt_path]
set rc [::timing::print_verdict $summary "GATE [file tail $dcp_arg]"]

if {$rc == 0 && $opened_here} {
    puts "=== Отчёт сохранён: $rpt_path ==="
}
if {$opened_here} { close_design }
exit $rc
