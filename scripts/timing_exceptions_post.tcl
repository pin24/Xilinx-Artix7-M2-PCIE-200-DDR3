# ============================================================================
# timing_exceptions_post.tcl — применение set_clock_groups ПОСЛЕ синтеза
# ============================================================================
# BUG-047: НЕ парсится как .xdc (Designutils 20-1307). Применяем в TCL.POST
# synth_1, когда все клоки уже существуют.
#
# РЕАЛЬНЫЕ имена клоков (диагностика 2026-09-09 с готового impl_1):
#   fab125   : clk_out1_xdma_ddr3_dfx_clk125_core_wiz_0   (125 МГц, period=8.0)
#   mig200   : clk_out1_xdma_ddr3_dfx_clk200_clk_wiz_0    (200 МГц, period=5.0)
#   clk50    : clk50                                      (50 МГц, period=20)
#   pcie     : pcie_refclk (100) -> txoutclk_x0y0 (100) -> mmcm_fb ->
#              userclk1/userclk2 (250/125), clk_125mhz_x0y0, clk_250mhz_x0y0,
#              clk_125mhz_mux_x0y0, clk_250mhz_mux_x0y0 (XDMA pipe clocks)
# ============================================================================

puts "=== timing_exceptions_post.tcl START ==="

set groups {}
set names {}

proc add_grp {clklist name} {
    if {[llength $clklist] > 0} {
        lappend ::groups $clklist
        lappend ::names $name
        puts "INFO: группа $name: [llength $clklist] клок(ов)"
    } else {
        puts "WARNING: группа $name пуста"
    }
}

# 1. PCIe-дерево (все XDMA клоки — асинхронно от всего остального)
set pcie_all [get_clocks -quiet -include_generated_clocks pcie_refclk]
add_grp $pcie_all "pcie+generated"

# 2. Сырой clk50 (HWICAP icap_clk)
set clk50_g [get_clocks -quiet clk50]
add_grp $clk50_g "clk50raw"

# 3. Fabric 125 МГц (наш RTL)
set fab_g [get_clocks -quiet clk_out1_xdma_ddr3_dfx_clk125_core_wiz_0]
add_grp $fab_g "fabric125"

# 4. MIG 200 → ui_clk/pll
set mig_g [get_clocks -quiet clk_out1_xdma_ddr3_dfx_clk200_clk_wiz_0]
add_grp $mig_g "mig200"

if {[llength $groups] >= 2} {
    set cmd "set_clock_groups -asynchronous -name async_root_domains"
    foreach g $groups {
        append cmd " -group \{$g\}"
    }
    puts "INFO: группы = $names"
    if {[catch {eval $cmd} err]} {
        puts "CRITICAL WARNING: set_clock_groups failed: $err"
    } else {
        puts "INFO: междоменные пути исключены (set_clock_groups -asynchronous)"
    }
} else {
    puts "CRITICAL WARNING: менее 2 непустых групп — исключения НЕ применены"
}

# CDC-синхронизаторы: баунд на маршрут (подстраховка)
if {![catch {
    set_max_delay -datapath_only -quiet 10.000 \
        -to [get_cells -hierarchical -quiet -filter {NAME =~ "*tdot_irq_sync_reg*"}]
    set_max_delay -datapath_only -quiet 10.000 \
        -to [get_cells -hierarchical -quiet -filter {NAME =~ "*_sync_ff1*"}]
    puts "INFO: datapath_only баундсы на CDC применены"
}]} { }

puts "=== timing_exceptions_post.tcl DONE ==="

# ---- GTPE2_CHANNEL LOC (BUG-051) ----
# IP-шный PCIE_X0Y0.xdc отключён в build_dfx.tcl (IS_ENABLED false).
# Здесь задаём правильные LOC: lane[0..3] → GTP_X0Y7/6/5/4 (схема M.2).
set gt_cells [get_cells -hierarchical -quiet \
    -filter {PRIMITIVE_TYPE =~ *.GTPE2_CHANNEL.* && INST_NAME =~ *pipe_lane*}]
if {[llength $gt_cells] >= 4} {
    set_property LOC GTPE2_CHANNEL_X0Y7 [lindex $gt_cells 0]
    set_property LOC GTPE2_CHANNEL_X0Y6 [lindex $gt_cells 1]
    set_property LOC GTPE2_CHANNEL_X0Y5 [lindex $gt_cells 2]
    set_property LOC GTPE2_CHANNEL_X0Y4 [lindex $gt_cells 3]
    puts "INFO: GTPE2 LOC assigned: lane[0..3] → GTP_X0Y7/Y6/Y5/Y4"
} else {
    puts "CRITICAL WARNING: only [llength $gt_cells] GTPE2 cells found (нельзя применить LOC)"
}
puts "=== timing_exceptions_post.tcl DONE ==="