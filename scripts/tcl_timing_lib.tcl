# ============================================================================
# tcl_timing_lib.tcl — парсер Design Timing Summary + FATAL-гейт (BUG-038)
# ============================================================================
# Чистый Tcl: файл безопасно source-ить в любом интерпретаторе (в т.ч. вне
# Vivado — юнит-тесты). Команды Vivado вызываются только внутри процедур.
#
# Публичный API:
#   ::timing::parse_summary_string  txt      -> list 12 чисел или "" (не найден блок)
#   ::timing::parse_summary_rpt     path     -> то же, но из файла отчёта
#   ::timing::fmt_summary           lst      -> человекочитаемая строка
#   ::timing::is_fatal              lst      -> 1 если WNS<0 || WHS<0 || WPWS<0
#   ::timing::print_verdict         lst label-> печатает PASS/FATAL, возвращает is_fatal
#
# Формат блока (report_timing_summary, Vivado 2018.3+ .. 2025.2):
#     WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints ...
#     -------      -------  ---------------------  ...
#       0.370        0.000                      0               109148 ...
# Поля: wns tns tns_fail tns_total whs ths ths_fail ths_total wpws tpws tpws_fail tpws_total
# Значения могут быть "-inf"/"NA" — трактуются как FATAL/пропуск.
# ============================================================================

namespace eval timing {}

# --- Внутреннее: нормализация числа -----------------------------------------
# Возвращает "num" если это число, "inf" для -inf/inf, "na" иначе.
proc ::timing::_norm {v} {
    set v [string trim $v]
    if {[string match -nocase "*inf*" $v]} { return "inf" }
    if {[regexp {^[-+]?[0-9]+\.?[0-9]*([eE][-+]?[0-9]+)?$} $v]} { return $v }
    return "na"
}

# --- Парсер текста ------------------------------------------------------------
proc ::timing::parse_summary_string {txt} {
    set lines [split $txt "\n"]
    set n [llength $lines]
    for {set i 0} {$i < $n} {incr i} {
        if {[string first "WNS(ns)" [lindex $lines $i]] >= 0} {
            # ищем строку чисел: пропускаем заголовок и разделитель "-----"
            for {set j [expr {$i + 1}]} {$j < [expr {$i + 6}] && $j < $n} {incr j} {
                set ln [string trim [lindex $lines $j]]
                if {$ln eq ""} { continue }
                if {[string first "WNS" $ln] >= 0} { break }
                if {[regexp {^-+[ -]*$} $ln]} { continue }
                set f [regexp -all -inline {\S+} $ln]
                if {[llength $f] >= 10} {
                    set out {}
                    foreach k {0 1 2 3 4 5 6 7 8 9 10 11} {
                        if {$k < [llength $f]} {
                            lappend out [::timing::_norm [lindex $f $k]]
                        } else {
                            lappend out "na"
                        }
                    }
                    return $out
                }
                break
            }
        }
    }
    return ""
}

# --- Парсер файла отчёта ------------------------------------------------------
proc ::timing::parse_summary_rpt {path} {
    if {![file exists $path]} { return "" }
    set fh [open $path r]
    set txt [read $fh]
    close $fh
    return [::timing::parse_summary_string $txt]
}

# --- Форматирование -----------------------------------------------------------
proc ::timing::fmt_summary {lst} {
    if {[llength $lst] != 12} { return "unavailable" }
    lassign $lst wns tns tnsf tnst whs ths thsf thst wpws tpws tpwsf tpwst
    return [format "WNS=%s TNS=%s (fail %s/%s)  WHS=%s THS=%s (fail %s/%s)  WPWS=%s TPWS=%s (fail %s/%s)" \
        $wns $tns $tnsf $tnst $whs $ths $thsf $thst $wpws $tpws $tpwsf $tpwst]
}

# --- FATAL-критерий ------------------------------------------------------------
# WNS<0  -> setup не закрыт;  WHS<0 -> hold не закрыт (чип неработоспособен);
# WPWS<0 -> нарушена мин. ширина импульса клока.
# "-inf" в любом из WNS/WHS/WPWS = фатально; "na" игнорируется.
proc ::timing::is_fatal {lst} {
    if {[llength $lst] != 12} { return 0 }
    foreach {idx} {0 4 8} {
        set v [lindex $lst $idx]
        if {$v eq "inf"} { return 1 }
        if {$v ne "na" && [string is double -strict $v]} {
            if {$v < 0.0} { return 1 }
        }
    }
    return 0
}

# --- Вердикт --------------------------------------------------------------------
proc ::timing::print_verdict {lst {label "TIMING"}} {
    if {[llength $lst] == 0} {
        puts "============================================================"
        puts " ${label}: БЛОК Design Timing Summary НЕ НАЙДЕН"
        puts " (нет клоков? пустой дизайн? отчёт от другого шага?)"
        puts "============================================================"
        return 1
    }
    set fatal [::timing::is_fatal $lst]
    puts " ${label}: [::timing::fmt_summary $lst]"
    if {$fatal} {
        puts "============================================================"
        puts " FATAL: TIMING NOT MET — ${label}"
        puts " Нарушение setup/hold/pulse-width делает битстрим НЕРАБОТОСПОСОБНЫМ."
        puts " Сборка остановлена до экспорта артефактов (BUG-038 convention)."
        puts " Действия:"
        puts "   1) vivado -mode batch -source scripts/timing_report_analysis.tcl \\"
        puts "        -tclargs <checkpoint.dcp>"
        puts "   2) изучить inter-clock таблицу и worst paths (модуль-виновник);"
        puts "   3) исправить констрейнты/RTL (pipelining), пересобрать."
        puts "============================================================"
        return 1
    }
    puts " ${label}: TIMING MET (PASS)"
    return 0
}
