# ============================================================================
# timing_report_analysis.tcl — детальный разбор критического пути (BUG-038)
# ============================================================================
# Usage:
#   vivado -mode batch -source scripts/timing_report_analysis.tcl -tclargs [dcp] [outdir]
#
#   dcp    — опционально: checkpoint (impl_1 / child impl). Без аргумента
#            используется уже открытый дизайн или ищется impl_1 проекта.
#   outdir — опционально: каталог для отчётов (дефолт: ./timing_analysis_out).
#
# Что делает (эквивалент GUI: Reports -> Report Timing Summary + разбор):
#   1. Design Timing Summary: WNS/TNS/WHS/THS/WPWS + FATAL-вердикт.
#   2. Clock Summary + Inter-Clock Table — ГДЕ именно провал (какая пара).
#   3. Топ-32 setup-пути: стартовый/конечный регистр, требование, задержка,
#      уровни логики, модуль-виновник (иерархическая атрибуция) —
#      "с какого модуля начать оптимизацию".
#   4. Группировка худших эндпоинтов по иерархии (топ-10 модулей по числу
#      нарушений) — приоритизация pipelining'а.
#   5. report_design_analysis -logic_level_distribution — глубина логики.
#   6. report_clock_interactions + report_cdc — проверка исключений.
# Exit code всегда 0 (анализ, не гейт). Для гейта — check_timing_fatal.tcl.
# ============================================================================

set SELF_DIR [file dirname [file normalize [info script]]]
source [file join $SELF_DIR tcl_timing_lib.tcl]

# ---------- Аргументы ------------------------------------------------------------
set dcp_arg ""
set outdir_arg "./timing_analysis_out"
if {[info exists argv] && [llength $argv] >= 1} { set dcp_arg [lindex $argv 0] }
if {[info exists argv] && [llength $argv] >= 2} { set outdir_arg [lindex $argv 1] }
file mkdir $outdir_arg

# ---------- Открытие дизайна -------------------------------------------------------
set opened_here 0
if {$dcp_arg ne ""} {
    if {![file exists $dcp_arg]} {
        puts "ERROR: checkpoint не найден: $dcp_arg"
        exit 1
    }
    open_checkpoint $dcp_arg
    set opened_here 1
} elseif {[catch {current_design} cur] != 0 || $cur eq ""} {
    set cand [list]
    foreach base [list [expr {[info exists ::env(PROJ_DIR_BUILD)] ? ${::env(PROJ_DIR_BUILD)} : ""}] \
                       [file normalize "$SELF_DIR/../build"]] {
        if {$base eq ""} { continue }
        set cand [glob -nocomplain [file join $base *.runs impl_1 *.dcp]]
        if {[llength $cand] > 0} { break }
    }
    if {[llength $cand] == 0} {
        puts "ERROR: дизайн не открыт и impl_1 checkpoint не найден."
        puts "  vivado -mode batch -source scripts/timing_report_analysis.tcl -tclargs <path.dcp>"
        exit 1
    }
    set dcp_arg [lindex $cand end]
    puts "=== Открываю impl_1 checkpoint: $dcp_arg ==="
    open_checkpoint $dcp_arg
    set opened_here 1
}

set rpt_all [file join $outdir_arg timing_analysis.rpt]

# ---------- 1-2. Полный отчёт: summary + clocks + inter-clock ----------------------
puts "============================================================"
puts " TIMING DEEP-DIVE: [file tail [file normalize [info script]]]"
puts "============================================================"

if {[catch {report_timing_summary -quiet -warn_on_violation -report_unconstrained -file $rpt_all} rerr]} {
    puts "ERROR: report_timing_summary failed: $rerr"
    if {$opened_here} { close_design }
    exit 1
}

# вырезаем ключевые секции в stdout
set fh [open $rpt_all r]
set txt [read $fh]
close $fh
set lines [split $txt "\n"]

proc ::ta::dump_section {lines marker maxlines} {
    set n [llength $lines]
    for {set i 0} {$i < $n} {incr i} {
        if {[string first $marker [lindex $lines $i]] >= 0} {
            set end [expr {$i + $maxlines}]
            if {$end > $n} { set end $n }
            for {set j $i} {$j < $end} {incr j} {
                set ln [string trimright [lindex $lines $j]]
                if {[string first "Timing Report" $ln] == 0} { break }
                puts "  $ln"
            }
            return
        }
    }
}

puts ""
puts "--- Design Timing Summary ---"
set summary [::timing::parse_summary_string $txt]
catch {::timing::print_verdict $summary "FULL DESIGN"}
puts ""
puts "--- Clock Summary ---"
::ta::dump_section $lines "| Clock Summary" 20
puts ""
puts "--- Inter Clock Table (провал живёт ЗДЕСЬ, если пара не исключена) ---"
::ta::dump_section $lines "| Inter Clock Table" 30
puts ""

# ---------- 3. Худшие setup-пути + атрибуция модулей --------------------------------
puts "--- TOP-32 WORST SETUP PATHS (кандидаты на pipelining) ---"
set wpaths [list]
catch {set wpaths [get_timing_paths -quiet -delay_type max -max_paths 32 -nworst 1]} perr
array unset mod_cnt
array unset mod_slack
set k 0
foreach p $wpaths {
    set sl  [get_property SLACK $p]
    set sp  ""
    set ep  ""
    catch {set sp [get_property STARTPOINT_PIN $p]}
    catch {set ep [get_property ENDPOINT_PIN $p]}
    set req "na"
    set dly "na"
    set lvl "na"
    catch {set req [format %.3f [get_property REQUIREMENT $p]]}
    catch {set dly [format %.3f [get_property DATAPATH_DELAY $p]]}
    catch {set lvl [get_property LOGIC_LEVELS $p]}
    puts [format "  #%02d slack %8.3f ns | req %s | data %s | levels %s" $k $sl $req $dly $lvl]
    puts "       from: $sp"
    puts "       to  : $ep"
    # модуль = первые 4 сегмента иерархии ячейки эндпоинта
    set cell ""
    catch {set cell [get_cells -quiet -of_objects [get_pins -quiet $ep]]}
    if {$cell eq ""} { set cell $ep }
    set segs [lrange [split $cell "/"] 0 3]
    set mod [join $segs "/"]
    if {[info exists mod_cnt($mod)]} {
        incr mod_cnt($mod)
        if {$sl < $mod_slack($mod)} { set mod_slack($mod) $sl }
    } else {
        set mod_cnt($mod) 1
        set mod_slack($mod) $sl
    }
    incr k
}
puts ""
puts "--- МОДУЛИ-ВИНОВНИКИ (топ-10 по числу худших эндпоинтов) ---"
puts "  (кол-во худших путей | худший slack | модуль) — начинать с первого:"
set pairs {}
foreach m [array names mod_cnt] {
    lappend pairs [list $mod_cnt($m) $mod_slack($m) $m]
}
set pairs [lsort -integer -decreasing -index 0 $pairs]
set pi 0
foreach pr $pairs {
    if {$pi >= 10} { break }
    puts [format "  %4d путей | worst %8.3f ns | %s" [lindex $pr 0] [lindex $pr 1] [lindex $pr 2]]
    incr pi
}

# ---------- 4. Худшие hold-пути -------------------------------------------------------
puts ""
puts "--- TOP-5 WORST HOLD PATHS ---"
set hpaths [list]
catch {set hpaths [get_timing_paths -quiet -delay_type min -max_paths 5 -nworst 1]} herr
set k 0
foreach p $hpaths {
    set sl [get_property SLACK $p]
    set sp ""; set ep ""
    catch {set sp [get_property STARTPOINT_PIN $p]}
    catch {set ep [get_property ENDPOINT_PIN $p]}
    puts [format "  #%d hold slack %8.3f ns: %s -> %s" $k $sl $sp $ep]
    incr k
}

# ---------- 5. Распределение глубины логики (pipelining-гид) --------------------------
puts ""
puts "--- LOGIC LEVEL DISTRIBUTION (report_design_analysis) ---"
catch {report_design_analysis -logic_level_distribution -file [file join $outdir_arg design_analysis.rpt]} daerr
if {[info exists daerr] && $daerr ne ""} {
    puts "  (design_analysis недоступен: $daerr)"
} else {
    puts "  сохранено: [file join $outdir_arg design_analysis.rpt]"
}

# ---------- 6. Взаимодействия клоков + CDC --------------------------------------------
catch {report_clock_interactions -file [file join $outdir_arg clock_interactions.rpt]}
catch {report_cdc -file [file join $outdir_arg cdc.rpt]}
puts "  report_clock_interactions -> [file join $outdir_arg clock_interactions.rpt]"
puts "  report_cdc               -> [file join $outdir_arg cdc.rpt]"
puts ""
puts "=== Полный отчёт: $rpt_all ==="
puts "=== Гейт (FAIL/OK) отдельно: vivado -mode batch -source scripts/check_timing_fatal.tcl -tclargs <dcp> ==="

if {$opened_here} { close_design }
exit 0
