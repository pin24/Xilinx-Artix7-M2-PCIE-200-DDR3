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
    set synth_dcp [glob -nocomplain C:/build_dfx/m2_artix7_xdma_ddr3_dfx.runs/synth_1/*.dcp]
    if {[llength $synth_dcp] == 0} {
        puts "ERROR: synth_1 checkpoint not found. Run synth first."
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
puts "=== Creating mig_refclk (200 MHz, 5.000 ns) on pin: $refclk_pin ==="
create_clock -name mig_refclk -period 5.000 $refclk_pin

# сохранить checkpoint с обновлёнными clock constraints
if {$opened_here} {
    save_checkpoint
    close_design
}

puts "=== MIG_REFCLK CREATED: OK ==="
