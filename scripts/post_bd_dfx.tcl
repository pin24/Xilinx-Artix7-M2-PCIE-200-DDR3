# ============================================================================
# post_bd_dfx.tcl — постобработка DFX Block Design
# ============================================================================
# После переноса создания всех внешних AXI-портов (M_AXI_TDOT,
# S_AXI_TDOT_REGS, S_AXI_ICAP_REGS, S_AXI_XADC_REGS), их подключения и
# адресации в xdma_ddr3_dfx_bd.tcl, этот скрипт выполняет ТОЛЬКО:
#   - экспорт такта PCIe-домена (axi_aclk_out / axi_aresetn_out / axi_aclk_in)
#   - экспорт fabric-домена 125 МГц (clk_core_out / core_resetn_out, BUG-034)
#   - очистку legacy M_AXI_ICAP
#   - подключение tdot_irq планировщика TDOT к xdma_0/usr_irq_req (MSI-X, вектор 0)
#   - финальную валидацию
#
# ВАЖНО (BUG-035): НЕ трогать FREQ_HZ/ASSOCIATED_BUSIF на пинах SmartConnect
# и не пересоздавать порты — это ломает validate (BD 41-237). Домены
# авто-выводятся Vivado из FREQ_HZ внешних портов (125 → fabric).
#
# Идемпотентно: можно вызывать многократно.
# Вызывается из build_dfx.tcl (шаг 2c).
# ============================================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]

# ---------- 0. Открыть проект/BD (идемпотентно) ----------
set opened_here 0
if {[catch {current_project}] != 0} {
    set proj_list ""
    if {[info exists ::env(PROJ_DIR_BUILD)]} {
        set proj_list [glob -nocomplain ${::env(PROJ_DIR_BUILD)}/*.xpr]
    }
    if {$proj_list eq ""} {
        set proj_list [glob -nocomplain ${SCRIPT_DIR}/../build/*/*.xpr]
    }
    if {$proj_list eq ""} {
        set proj_list [glob -nocomplain C:/build_dfx/*.xpr]
    }
    if {$proj_list eq ""} {
        puts "ERROR: проект не найден. Сначала запустите build_dfx.tcl шаг 1."
        exit 1
    }
    set proj_path [lindex $proj_list 0]
    puts "=== opening project: $proj_path ==="
    open_project $proj_path
    set opened_here 1
}
if {[llength [get_bd_designs -quiet]] == 0} {
    set bd_files [get_files *.bd]
    if {$bd_files eq ""} {
        puts "ERROR: BD-файл не найден в проекте."
        exit 1
    }
    open_bd_design [lindex $bd_files 0]
}

# ============================================================================
# 5. Экспорт такта PCIe-домена (axi_aclk_out / axi_aresetn_out / axi_aclk_in)
# ============================================================================
puts "=== 5. Экспорт такта (axi_aclk_out / axi_aresetn_out / axi_aclk_in) ==="

if {[get_bd_ports -quiet axi_aclk_out] eq ""} {
    create_bd_port -dir O axi_aclk_out
}
if {[get_bd_ports -quiet axi_aresetn_out] eq ""} {
    create_bd_port -dir O axi_aresetn_out
}
if {[get_bd_ports -quiet axi_aclk_in] eq ""} {
    create_bd_port -dir I -type clk axi_aclk_in
}
# loopback от axi_aclk_out: при XDMA 64-бит это 250 МГц (BUG-034)
set_property -dict [list CONFIG.FREQ_HZ 250000000] [get_bd_ports axi_aclk_in]

proc _clk_connect {port_name pin_name} {
    set port [get_bd_ports -quiet $port_name]
    set pin  [get_bd_pins  -quiet $pin_name]
    if {$port eq "" || $pin eq ""} { return }
    # Идемпотентно: если порт уже подключён к сети — пропускаем (порт мог быть
    # создан и подключён в xdma_ddr3_dfx_bd.tcl, например clk_core_out).
    set pnet [get_bd_nets -quiet -of_objects $port]
    if {[llength $pnet] > 0} {
        puts "=== $port_name already connected (skip) ==="
        return
    }
    set npin [get_bd_nets -quiet -of_objects $pin]
    if {[llength $npin] == 0} {
        connect_bd_net $port $pin
        puts "=== $pin_name -> $port_name (new) ==="
    } else {
        set existing_net [lindex $npin 0]
        connect_bd_net -net $existing_net $port
        puts "=== $pin_name -> $port_name (joined to existing net $existing_net) ==="
    }
}
_clk_connect axi_aclk_out    xdma_0/axi_aclk
_clk_connect axi_aresetn_out xdma_0/axi_aresetn

# ============================================================================
# 5b. Экспорт fabric-домена 125 МГц (BUG-034)
# ============================================================================
puts "=== 5b. Экспорт fabric-домена (clk_core_out / core_resetn_out) ==="

if {[get_bd_ports -quiet clk_core_out] eq ""} {
    create_bd_port -dir O -type clk -freq_hz 125000000 clk_core_out
}
if {[get_bd_ports -quiet core_resetn_out] eq ""} {
    create_bd_port -dir O core_resetn_out
}
_clk_connect clk_core_out    clk125_core_wiz/clk_out1
_clk_connect core_resetn_out rst_core_125M/peripheral_aresetn

# ============================================================================
# 5c. tdot_irq — IRQ планировщика TDOT -> xdma_0/usr_irq_req (MSI-X вектор 0)
# ============================================================================
# tdot_axi4 выставляет УРОВЕНЬ (sched_irq, держится до irq_ack хоста);
# 2-FF синхронизация уже сделана в xdma_ddr3_core_top (домен axi_aclk 250).
# BUG-049: usr_irq_req в XDMA-конфиге MSI-X-only (pf0_interrupt_pin=NONE) —
# пин шириной 1 бит. Подключаем tdot_irq НАПРЯМУЮ (1 бит → 1 бит),
# без xlconcat/xlconstant (BD 41-2383 width mismatch 1 vs 16).
puts "=== 5c. tdot_irq -> xdma_0/usr_irq_req[0] ==="

if {[get_bd_ports -quiet tdot_irq] eq ""} {
    create_bd_port -dir I -type intr tdot_irq
}
if {[get_bd_pins -quiet xdma_0/usr_irq_req] ne ""} {
    connect_bd_net [get_bd_ports tdot_irq] [get_bd_pins xdma_0/usr_irq_req]
    puts " tdot_irq -> usr_irq_req[0] (MSI-X, 1-bit direct)"
} else {
    puts " WARNING: xdma_0/usr_irq_req not found (MSI-X only) — IRQ not connected"
}

# ============================================================================
# 6. Очистка legacy M_AXI_ICAP (если есть)
# ============================================================================
puts "=== 6. Очистка legacy M_AXI_ICAP ==="
set legacy_icap [get_bd_intf_ports -quiet M_AXI_ICAP]
if {$legacy_icap ne ""} {
    set legacy_intf_nets [get_bd_intf_nets -quiet -of_objects $legacy_icap]
    foreach inet $legacy_intf_nets { delete_bd_objs $inet }
    set legacy_nets [get_bd_nets -quiet -of_objects $legacy_icap]
    foreach net $legacy_nets { delete_bd_objs $net }
    delete_bd_objs $legacy_icap
    puts "=== удалён legacy M_AXI_ICAP ==="
}

# ============================================================================
# 7. Валидация и сохранение
# ============================================================================
puts "=== 7. Валидация BD ==="
validate_bd_design
save_bd_design

puts "============================================"
puts " POST-BD DFX: OK"
puts "============================================"
puts " xdma_axi_smc.S02 → M_AXI_TDOT @ DDR3 0x80000000"
puts " xdma_axi_lite_smc.M03 → S_AXI_TDOT_REGS @ 0x40003000"
puts " xdma_axi_lite_smc.M04 → S_AXI_ICAP_REGS @ 0x40004000"
puts " xdma_axi_lite_smc.M05 → S_AXI_XADC_REGS @ 0x46000000"
puts " clock: axi_aclk_out/aresetn_out (O, XDMA 250), axi_aclk_in (I)"
puts " clock: clk_core_out/core_resetn_out (O, fabric 125 МГц)"
puts " irq:   tdot_irq -> usr_irq_req[0] (MSI-X vector 0, In1..15=0)"
puts "============================================"

if {$opened_here} { close_project }