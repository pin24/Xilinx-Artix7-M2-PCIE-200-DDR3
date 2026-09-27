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

# ============================================================================
# icap_clk = 62.5 МГц (кастомный icap_ctrl, rtl/integration/icap_ctrl.sv):
# S_AXI_ACLK(125) /2 через register-toggle + BUFG u_icap_bufg. Derived clock
# от register-toggle Vivado не определяет (no clock) и таймит эти пути как
# несогласованные/ложные, поэтому декларируем явный generated clock:
#   - source = вход BUFG u_icap/u_icap_bufg/I (мастер core_clk 125, period 8 нс)
#   - деление -divide_by 2 → icap_clk 62.5 МГц (period 16 нс)
# Ячейка существует только после синтеза → применяем здесь (PLACE_DESIGN.
# TCL.PRE), а не в constraints/timing_exceptions.tcl.
# Полное имя: top xdma_ddr3_core_top → u_icap → u_icap_bufg.
# ============================================================================
set icap_bufg_o [get_pins -quiet -hierarchical -filter {NAME =~ *u_icap_bufg/O}]
if {${icap_bufg_o} ne ""} {
    set icap_bufg_i [get_pins -quiet -hierarchical \
        -filter {NAME =~ *u_icap_bufg/I}]
    if {${icap_bufg_i} ne ""} {
        catch {create_generated_clock -name icap_clk \
            -source [lindex ${icap_bufg_i} 0] -divide_by 2 \
            [lindex ${icap_bufg_o} 0]}
    }
}
if {[get_clocks -quiet icap_clk] ne ""} {
    puts "INFO: create_generated_clock icap_clk (62.5 МГц) создан на ${icap_bufg_o}"
} else {
    puts "WARNING: icap_clk BUFG (u_icap/u_icap_bufg) не найден — generated clock НЕ создан"
}

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

# 2. Сырой clk50 (физический вход clk200/clk125 wiz; кастомный icap_ctrl
#    НЕ использует clk50 — он делит core_clk внутри, см. группу icap_clk)
set clk50_g [get_clocks -quiet clk50]
add_grp $clk50_g "clk50raw"

# 3. Fabric 125 МГц (наш RTL)
set fab_g [get_clocks -quiet clk_out1_xdma_ddr3_dfx_clk125_core_wiz_0]
add_grp $fab_g "fabric125"

# 4. MIG 200 → ui_clk/pll
set mig_g [get_clocks -quiet clk_out1_xdma_ddr3_dfx_clk200_clk_wiz_0]
add_grp $mig_g "mig200"

# 5. icap_clk (62.5 МГц, кастомный icap_ctrl) — ОТДЕЛЬНАЯ асинхронная группа.
# Хотя icap_clk физически производен от core_clk (fabric125), переход между
# S_AXI_ACLK(125) и icap_clk(62.5) — асинхронный toggle-handshake через 2FF
# (*ASYNC_REG*), поэтому ему запрещено быть синхронной парой с любым доменом.
set icap_g [get_clocks -quiet icap_clk]
add_grp $icap_g "icap_clk(62.5)"

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

# ---- GTPE2 LOC: IP XDC отключён (build_dfx.tcl) — Vivado сам разместит GT --#-
puts "INFO: GTPE2 LOC не назначаем — IP XDC отключён (12-2285 более не актуален)"
puts "=== timing_exceptions_post.tcl DONE ==="