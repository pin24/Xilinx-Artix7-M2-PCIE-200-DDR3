# ============================================================================
# timing_exceptions_post.tcl — применение set_clock_groups ПОСЛЕ синтеза
# ============================================================================
# BUG-047: timing_exceptions.tcl содержит if/foreach/lappend — не парсится
# как .xdc (Designutils 20-1307). Но и read_xdc -tcl на этапе чтения
# констрейнов НЕ видит порождённые клоки BD (MMCM ещё не элаборирован).
# Поэтому применяем исключения в TCL.POST шага synth_1 (все клоки есть).
#
# Реальные имена клоков (2025.2, отчёт timing_summary_routed):
#   fabric : clk_out1_xdma_ddr3_dfx_clk125_core_wiz_0        (125 МГц)
#   mig200 : clk_out1_xdma_ddr3_dfx_clk200_clk_wiz_0         (200 МГц)
#   clk50  : clk50                                           (50 МГц)
#   pcie   : pcie_refclk (100) -> userclk1 (250), userclk2 (125),
#            clk_125mhz_x0y0, clk_250mhz_x0y0 (XDMA pipe clocks)
# ============================================================================

set root_pcie    [get_clocks -quiet pcie_refclk]
set root_clk50   [get_clocks -quiet clk50]
set root_fab     [get_clocks -quiet clk_out1_xdma_ddr3_dfx_clk125_core_wiz_0]
set root_mig     [get_clocks -quiet clk_out1_xdma_ddr3_dfx_clk200_clk_wiz_0]

set groups {}
set names {}

proc add_grp {clklist name} {
    if {[llength $clklist] > 0} {
        lappend ::groups $clklist
        lappend ::names $name
    } else {
        puts "WARNING: timing post: группа $name пуста"
    }
}

if {[llength $root_pcie] > 0} {
    set pcie_all [get_clocks -quiet -include_generated_clocks pcie_refclk]
    add_grp $pcie_all "pcie+generated"
}
add_grp $root_clk50 "clk50raw"
add_grp $root_fab   "fabric125"
add_grp $root_mig   "mig200"

if {[llength $groups] >= 2} {
    set cmd "set_clock_groups -asynchronous -name async_root_domains"
    foreach g $groups {
        append cmd " -group \{$g\}"
    }
    puts "INFO: timing post: группы = $names"
    if {[catch {eval $cmd} err]} {
        puts "CRITICAL WARNING: timing post: set_clock_groups failed: $err"
    } else {
        puts "INFO: timing post: междоменные пути исключены (set_clock_groups -asynchronous)"
    }
} else {
    puts "CRITICAL WARNING: timing post: менее 2 непустых групп — исключения НЕ применены"
}

# CDC-синхронизаторы: баунд на маршрут (подстраховка)
if {![catch {
    set_max_delay -datapath_only -quiet 10.000 \
        -to [get_cells -hierarchical -quiet -filter {NAME =~ "*tdot_irq_sync_reg*"}]
    set_max_delay -datapath_only -quiet 10.000 \
        -to [get_cells -hierarchical -quiet -filter {NAME =~ "*_sync_ff1*"}]
    puts "INFO: timing post: datapath_only баундсы на CDC применены"
}]} { }

puts "=== timing_exceptions_post.tcl DONE ==="

# ---- GTPE2_CHANNEL LOC (динамический поиск, BUG-047) ----
# XDMA Gen2 x4 на Artix-7: lanes 0-3 = GTPE2_CHANNEL_X0Y4-7.
# Жёсткие пути в early.xdc ломаются при смене версии IP (12-2285).
set gt_cells [get_cells -hierarchical -quiet \
    -filter {PRIMITIVE_TYPE =~ *.GTPE2_CHANNEL.* && INST_NAME =~ *pipe_lane*}]
if {[llength $gt_cells] >= 4} {
    set_property LOC GTPE2_CHANNEL_X0Y4 [lindex $gt_cells 0]
    set_property LOC GTPE2_CHANNEL_X0Y5 [lindex $gt_cells 1]
    set_property LOC GTPE2_CHANNEL_X0Y6 [lindex $gt_cells 2]
    set_property LOC GTPE2_CHANNEL_X0Y7 [lindex $gt_cells 3]
    puts "INFO: GTPE2_CHANNEL LOC assigned via dynamic search"
} else {
    puts "CRITICAL WARNING: only [llength $gt_cells] GTPE2_CHANNEL cells found (need >=4)"
}