# ============================================================================
# mig_refclk_post.tcl — создание mig_refclk после synth_1 (TCL.POST hook)
# ============================================================================
# Вызывается как TCL.POST шага synth_design в build_dfx.tcl.
#
# AUDIT-02: create_clock на MIG IODELAYCTRL REFCLK pin нужно выполнять
# ПОСЛЕ link_design, когда MIG IP развёрнут и pin существует. До synth
# Vivado пишет CRITICAL WARNING [Vivado 12-4739] No valid object(s) found
# for '-objects [get_pins -quiet */u_iodelay_ctrl/u_idelayctrl_*/REFCLK]'.
#
# Здесь мы открываем синтезированный netlist и создаём clock на REFCLK pin.
# ============================================================================
# Reference: Vivado UG912 — get_pins требует развёрнутого netlist.
# ============================================================================

# открыть синтезированный дизайн (если ещё не открыт)
set opened_here 0
if {[catch {current_design} cur] != 0 || $cur eq ""} {
    # Каталог проекта: $::env(PROJ_DIR_BUILD) (выставляет build_dfx.tcl);
    # легаси-совместимость: C:/build_dfx на Windows, build/ внутри репозитория.
    set proj_dir ""
    if {[info exists ::env(PROJ_DIR_BUILD)]} {
        set proj_dir ${::env(PROJ_DIR_BUILD)}
    } elseif {[info exists ::env(PROJ_DIR)]} {
        set proj_dir ${::env(PROJ_DIR)}
    } else {
        set _here [file dirname [file normalize [info script]]]
        set _cand [glob -nocomplain ${_here}/../build/*/*.xpr]
        if {[llength ${_cand}] > 0} {
            set proj_dir [file dirname [lindex ${_cand} 0]]
        } elseif {$tcl_platform(platform) eq "windows"} {
            set proj_dir "C:/build_dfx"
        }
    }
    set synth_dcp ""
    if {${proj_dir} ne ""} {
        set synth_dcp [glob -nocomplain ${proj_dir}/*.runs/synth_1/*.dcp]
    }
    if {[llength $synth_dcp] == 0} {
        puts "ERROR: synth_1 checkpoint not found (PROJ_DIR='${proj_dir}'). Run synth first."
        exit 1
    }
    open_checkpoint [lindex $synth_dcp 0]
    set opened_here 1
}

# найти REFCLK pin MIG IODELAYCTRL
set refclk_pins [get_pins -quiet {*/u_iodelay_ctrl/u_idelayctrl_*/REFCLK}]

if {[llength $refclk_pins] == 0} {
    # fallback: попробовать другой паттерн (Vivado 2025.2 может rename)
    set refclk_pins [get_pins -quiet {*/mig_7series_0/*/u_idelayctrl_*/REFCLK}]
}

if {[llength $refclk_pins] == 0} {
    puts "WARNING: MIG IODELAYCTRL REFCLK pin not found in synth_1 netlist."
    puts "WARNING: mig_refclk not created. This may cause IDELAYCTRL timing issues."
    if {$opened_here} { close_design }
    return
}

# создаём clock (200 MHz = 5 ns period)
set refclk_pin [lindex $refclk_pins 0]

# BUG-035 (2026-09-06): на REFCLK pin УЖЕ приходит propagated clock от
# clk_wiz: clk_out1_clk200_clk_wiz -> mig_7series_0/clk_ref_i ->
# u_iodelay_ctrl/REFCLK (авто-клок MMCM распространяется через BUFG и
# иерархию вплоть до REFCLK). Повторный create_clock плодит ВТОРОЙ
# корневой клок на той же цепи: внутри MIG возникают фиктивные inter-clock
# пары (ICLK=mig_refclk vs ui_clk), на которые НЕ действуют штатные
# исключения MIG XDC — источник необъяснимых тайминг-провалов.
# Решение: создавать mig_refclk ТОЛЬКО если клок на цепи отсутствует
# (легитимный случай — внешний рефклок, а не выход clk_wiz).
set tmg_refclk_net [get_nets -quiet -of_objects $refclk_pin]
set tmg_existing_clk [list]
if {[llength $tmg_refclk_net] > 0} {
    set tmg_existing_clk [get_clocks -quiet -of_objects [lindex $tmg_refclk_net 0]]
}
if {[llength $tmg_existing_clk] > 0} {
    puts "=== SKIP mig_refclk: на REFCLK уже действует propagated clock: $tmg_existing_clk ==="
    puts "=== (дубликатный create_clock порождал фиктивные inter-clock пары, BUG-035) ==="
    if {$opened_here} { close_design }
    return
}

puts "=== Creating mig_refclk (200 MHz, 5.000 ns) on pin: $refclk_pin ==="
create_clock -name mig_refclk -period 5.000 $refclk_pin

# сохранить checkpoint с обновлёнными clock constraints
if {$opened_here} {
    save_checkpoint
    close_design
}

puts "=== MIG_REFCLK CREATED: OK ==="
