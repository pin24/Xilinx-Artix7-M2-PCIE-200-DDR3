# ============================================================================
# synth_par_raw.tcl - блочный синтез compute_dot_par_raw (NUM_MAC) + тайминг
# ============================================================================
# Назначение: быстрый A/B-харнесс блока dot-ядра (умножители + ДЕРЕВО tfadd_raw)
# без полной DFX-сборки. Даёт util_parraw<N>.rpt и timing_parraw<N>.rpt.
#
# ИСПРАВЛЕНИЯ (Task 19, 2026-09-06, после DECISION-001):
#   1. Пути из корня репозитория (было: хардкод C:/A7_M2/... — ломался при
#      переносе репо; ROOT вычисляется как в scripts/build_dfx.tcl).
#   2. NUM_MAC через -tclargs (было: жёстко 64). Поддержанные формы:
#         vivado -mode batch -source synth_par_raw.tcl -tclargs 32
#         ... -tclargs NUM_MAC=32     ... -tclargs NUM_MAC 32
#      (урок BUG-033: оболочка может разрезать '=' — принимаем все формы).
#   3. ГЛАВНОЕ: добавлен create_clock 125 МГц (8.000 ns) на порт clk.
#      Раньше клоков не было → report_timing_summary НЕОТТАЙМИРОВАН
#      (WNS/TNS пустые) и «тайминг-отчёт» блока ничего не измерял.
#   4. Вердикт через scripts/tcl_timing_lib.tcl (тот же парсер, что в
#      FATAL-гейте полной сборки): WNS/WHS/WPWS < 0 → exit 1.
#      Правило проекта (BUG-038): прогон без тайминг-вердикта не считается
#      завершённым. Это харнесс для пайплайнинга ДЕРЕВА tfadd_raw —
#      сравнение "до/после" по WNS/TNS/LUT делается ЭТИМ скриптом.
# ============================================================================
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT       [file normalize "${SCRIPT_DIR}/../.."]
set rtl_dir    "${ROOT}/rtl/block"
set lib_dir    "${ROOT}/scripts"
set PART       "xc7a200tfbg484-2"

# Каталог проекта блока: переносимо, короткий корень на Windows (MAX_PATH).
if {[info exists ::env(PROJ_DIR)] && ${::env(PROJ_DIR)} ne ""} {
    set proj_dir [file normalize "${::env(PROJ_DIR)}/block_synth_raw"]
} elseif {$tcl_platform(platform) eq "windows"} {
    set proj_dir "C:/synth_block_raw"
} else {
    set proj_dir "${ROOT}/build/block_synth_raw"
}

# --- NUM_MAC / JOBS из tclargs (все формы; урок BUG-033) ---
set npar 32
set jobs 8
if {$argc > 0} {
    for {set i 0} {$i < $argc} {incr i} {
        set a [lindex $argv $i]
        if {[regexp {^(NUM_MAC)?=?(\d+)$} $a -> k v]} {
            set npar $v
        } elseif {[regexp {^JOBS?=?(\d+)$} $a -> v]} {
            set jobs $v
        } elseif {$a eq "NUM_MAC" || $a eq "-NUM_MAC"} {
            incr i
            if {$i < $argc && [regexp {^\d+$} [lindex $argv $i]]} {
                set npar [lindex $argv $i]
            }
        }
    }
}
puts "=== synth_par_raw: NUM_MAC=${npar} JOBS=${jobs} ==="
puts "=== ROOT=${ROOT} ==="
puts "=== PROJ=${proj_dir} ==="

file mkdir ${proj_dir}
create_project -force par_raw_synth ${proj_dir} -part ${PART}
set_property top compute_dot_par_raw [current_fileset]

add_files -norecurse \
    ${rtl_dir}/tbyte_add.sv \
    ${rtl_dir}/tbyte_mul.sv \
    ${rtl_dir}/tfadd_raw.sv \
    ${rtl_dir}/tfmul_raw.sv \
    ${rtl_dir}/compute_dot_par_raw.sv

update_compile_order -fileset sources_1
set_property generic NUM_MAC=${npar} [current_fileset]

launch_runs synth_1 -jobs ${jobs}
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    puts "=== SYNTHESIS FAILED ==="
    close_project
    exit 1
}

puts "=== SYNTHESIS OK: отчёты ==="
open_run synth_1
# Клок создаётся ПОСЛЕ open_run (в batch-сессии create_clock до launch_runs
# в проектный прогон НЕ попадает). Внутриблочная цель — fabric 125 МГц,
# как в полной сборке (clk125_core_wiz): requirement 8.000 ns.
create_clock -period 8.000 -name clk_fab125 -waveform {0.000 4.000} [get_ports clk]
report_utilization    -file ${proj_dir}/util_parraw${npar}.rpt
report_timing_summary -file ${proj_dir}/timing_parraw${npar}.rpt

# --- Вердикт тайминга (та же библиотека, что FATAL-гейт сборки) ---
source ${lib_dir}/tcl_timing_lib.tcl
set tlst [::timing::parse_summary_rpt ${proj_dir}/timing_parraw${npar}.rpt]
set rc   [::timing::print_verdict $tlst "BLOCK TIMING (NUM_MAC=${npar}, 125 МГц)"]
if {$rc != 0 || [::timing::is_fatal $tlst]} {
    puts "=== BLOCK TIMING FATAL: compute_dot_par_raw(NUM_MAC=${npar}) не закрывает 125 МГц ==="
    puts "=== Это ожидаемо для последовательного дерева tfadd_raw; сравнивай по worst-пути ==="
    report_timing -max_paths 10 -nworst 1 -file ${proj_dir}/timing_worst10.rpt
    close_design
    close_project
    exit 1
}
puts "=== BLOCK TIMING MET: compute_dot_par_raw(NUM_MAC=${npar}) @ 125 МГц ==="
close_design
close_project
exit 0
