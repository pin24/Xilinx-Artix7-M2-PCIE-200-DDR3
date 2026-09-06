# ============================================================================
# timing_exceptions.xdc — межклоковые исключения (BUG-035, 2026-09-06)
# ============================================================================
# СИМПТОМ, ПРИВЕДШИЙ К СОЗДАНИЮ ФАЙЛА:
#   WNS = -120.809 ns, TNS = -373780 ns (~3093 эндпоинтов, все с почти
#   одинаковым провалом) — классическая сигнатура межклоковой пары,
#   затаймированной как синхронная. До этого файла в проекте НЕ БЫЛО НИ
#   ОДНОГО тайминг-исключения: ни set_clock_groups, ни set_false_path,
#   ни set_max_delay. Дизайн же имеет 4 асинхронных корневых домена.
#
# Корневые домены (взаимно асинхронные, разные физические источники):
#   grp_pcie : pcie_refclk (100 МГц MGTREFCLK) -> txoutclk -> userclk1 (250),
#              userclk2 (125), clk_125mhz/clk_250mhz (pipe_clock XDMA)
#   grp_clk50: сырой clk50 (20 ns, без порождённых — HWICAP icap_clk напрямую)
#   grp_fab  : clk_out1_clk125_core_wiz (125 МГц) -> fabric/RP/TDOT/GPIO/HWICAP S_AXI
#   grp_mig  : clk_out1_clk200_clk_wiz (200 МГц) -> sys_clk_i/clk_ref_i MIG
#              -> ui_clk (100 МГц); (исторический корень mig_refclk, если есть)
#
# Пересечения групп легальны ТОЛЬКО через CDC-структуры:
#   - 2FF синхронизаторы ASYNC_REG (tdot_irq_sync, icap_ctrl req/go/stop/ack/busy);
#   - async FIFO внутри SmartConnect (xdma_axi_smc 250/100/125, xdma_axi_lite_smc 250/125);
#   - IP-внутренние CDC (AXI HWICAP: icap_clk 50 vs s_axi 125; XDMA; MIG PHY).
# Поэтому ВСЕ межгрупповые пути исключаются из STA. ВНУТРИ групп тайминг
# НЕ ослабляется — реальные нарушения (например, длинная комбинация в ядре)
# останутся видимыми в отчётах и поймаются FATAL-гейтом сборки.
#
# Файл идемпотентен: каждая группа собирается в catch, пустые группы
# пропускаются с CRITICAL WARNING (иначе set_clock_groups упадёт).
# ============================================================================

# --- Собираем группы клоков -------------------------------------------------
set tmg_groups [list]
set tmg_names  [list]

# 1. PCIe-дерево: pcie_refclk и все порождённые (txoutclk, userclk1/2, ...)
if {![catch {set tmg_pcie [get_clocks -quiet -include_generated_clocks pcie_refclk]}]} {
    if {[llength $tmg_pcie] > 0} {
        lappend tmg_groups $tmg_pcie
        lappend tmg_names  "pcie"
    } else {
        puts "CRITICAL WARNING: timing_exceptions.xdc: группа pcie пуста (нет клока pcie_refclk)"
    }
}

# 2. Сырой clk50 (HWICAP icap_clk). БЕЗ -include_generated_clocks: порождённые
#    клоки двух clk_wiz относятся к своим группам (fab/mig), а не к корню.
if {![catch {set tmg_clk50 [get_clocks -quiet clk50]}]} {
    if {[llength $tmg_clk50] > 0} {
        lappend tmg_groups $tmg_clk50
        lappend tmg_names  "clk50raw"
    } else {
        puts "CRITICAL WARNING: timing_exceptions.xdc: группа clk50raw пуста (нет клока clk50)"
    }
}

# 3. Fabric 125 МГц: clk_out1_clk125_core_wiz + порождённые (если появятся)
if {![catch {set tmg_fab [get_clocks -quiet -include_generated_clocks clk_out1_clk125_core_wiz]}]} {
    if {[llength $tmg_fab] > 0} {
        lappend tmg_groups $tmg_fab
        lappend tmg_names  "fabric125"
    } else {
        puts "CRITICAL WARNING: timing_exceptions.xdc: группа fabric125 пуста (нет clk_out1_clk125_core_wiz)"
    }
}

# 4. MIG: clk_out1_clk200_clk_wiz + ui_clk (+ исторический mig_refclk, если создан)
if {![catch {set tmg_mig [get_clocks -quiet -include_generated_clocks clk_out1_clk200_clk_wiz]}]} {
    if {[llength $tmg_mig] > 0} {
        if {![catch {set tmg_mref [get_clocks -quiet mig_refclk]}]} {
            if {[llength $tmg_mref] > 0} {
                set tmg_mig [concat $tmg_mig $tmg_mref]
            }
        }
        lappend tmg_groups $tmg_mig
        lappend tmg_names  "mig"
    } else {
        puts "CRITICAL WARNING: timing_exceptions.xdc: группа mig пуста (нет clk_out1_clk200_clk_wiz)"
    }
}

# --- Применяем set_clock_groups только между непустыми группами -------------
if {[llength $tmg_groups] >= 2} {
    set tmg_cmd "set_clock_groups -asynchronous -name async_root_domains"
    foreach tmg_g $tmg_groups {
        append tmg_cmd " -group \{$tmg_g\}"
    }
    puts "INFO: timing_exceptions.xdc: groups = $tmg_names"
    if {[catch {eval $tmg_cmd} tmg_err]} {
        puts "CRITICAL WARNING: timing_exceptions.xdc: set_clock_groups failed: $tmg_err"
    } else {
        puts "INFO: timing_exceptions.xdc: междоменные пути исключены (set_clock_groups -asynchronous)"
    }
} else {
    puts "CRITICAL WARNING: timing_exceptions.xdc: менее 2 непустых групп — исключения НЕ применены"
}

# --- Подстраховка CDC-синхронизаторов ограничением маршрута -----------------
# (после успешных set_clock_groups эти пути уже исключены; ограничение нужно
#  на случай, если какая-то группа не собралась — тогда синхронизатор хотя бы
#  не будет требовать нереального скоу. 10 ns = верхняя граница задержки
#  маршрута между доменами, с большим запасом покрывает любые placement'ы.)
if {![catch {
    set_max_delay -datapath_only -quiet 10.000 \
        -to [get_cells -hierarchical -quiet -filter {NAME =~ "*tdot_irq_sync_reg*"}]
    set_max_delay -datapath_only -quiet 10.000 \
        -to [get_cells -hierarchical -quiet -filter {NAME =~ "*_sync_ff1*"}]
}]} {
    puts "INFO: timing_exceptions.xdc: datapath_only баундсы на CDC-синхронизаторы применены"
}
