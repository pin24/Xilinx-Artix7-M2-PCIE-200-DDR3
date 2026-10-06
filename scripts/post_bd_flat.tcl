# ============================================================================
# post_bd_flat.tcl — постобработка FLAT (no-DFX) Block Design
# ============================================================================
# Образец: post_bd_dfx.tcl, но БЕЗ всякой DFX-механики (нет dfx_partition,
# dfx_socket, apertures, partial reconfiguration). Этот скрипт выполняет:
#   - каноническое повторное назначение адресов (идемпотентно):
#       GPIO 0x40020000, MM2S 0x40010000, S2MM 0x40018000,
#       TDOT 0x40023000, XADC 0x46000000, DDR3 0x80000000
#   - экспорт такта PCIe-домена (axi_aclk_out / axi_aresetn_out / axi_aclk_in)
#   - экспорт fabric-домена 125 МГц (clk_core_out / core_resetn_out, BUG-034)
#   - подключение tdot_irq планировщика TDOT к xdma_0/usr_irq_req (MSI-X, вектор 0)
#   - make_wrapper (имя модуля xdma_ddr3_dfx, как ждёт RTL-top) + file copy
#   - финальную валидацию и сохранение
#
# Идемпотентно: можно вызывать многократно.
# Вызывается из build_flat.tcl (шаг 2c).
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
        set proj_list [glob -nocomplain C:/build_flat/*.xpr]
    }
    if {$proj_list eq ""} {
        puts "ERROR: проект не найден. Сначала запустите build_flat.tcl шаг 1."
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
# 1. Канонические адреса (идемпотентно; дублирует build_flat.tcl шаг 2d —
#    повторное назначение безопасно из-за delete_bd_objs + assign -force)
# ============================================================================
puts "=== 1. КАНОНИЧЕСКИЕ АДРЕСА (flat) ==="

# BAR0 = 128 MB (покрывает всё AXI-Lite окно 0x40000000-0x47FFFFFF)
catch {set_property -dict [list \
    CONFIG.pf0_bar0_scale {Megabytes} \
    CONFIG.pf0_bar0_size {128} \
    CONFIG.axilite_master_scale {Megabytes} \
    CONFIG.axilite_master_size {128} \
] [get_bd_cells xdma_0]}

set as_lite [get_bd_addr_spaces xdma_0/M_AXI_LITE]

# GPIO: 0x40020000
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_gpio_0_Reg}]
assign_bd_address -offset 0x40020000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force

# MM2S ctrl: 0x40010000
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_datamover_mm2s_c_0_reg0}]
assign_bd_address -offset 0x40010000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs axi_datamover_mm2s_c_0/s_axi/reg0] -force

# S2MM ctrl: 0x40018000
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_datamover_s2mm_c_0_reg0}]
assign_bd_address -offset 0x40018000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs axi_datamover_s2mm_c_0/s_axi/reg0] -force

# TDOT: 0x40023000
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_TDOT_REGS_Reg}]
assign_bd_address -offset 0x40023000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs S_AXI_TDOT_REGS/Reg] -force

# XADC: 0x46000000
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_XADC_REGS_Reg}]
assign_bd_address -offset 0x46000000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs S_AXI_XADC_REGS/Reg] -force

# DDR3: 0x80000000 (для всех высокоскоростных мастеров xdma_axi_smc)
foreach _sp {xdma_0/M_AXI axi_datamover_0/Data_MM2S axi_datamover_1/Data_S2MM} {
    catch {delete_bd_objs -quiet [get_bd_addr_segs -quiet ${_sp}/SEG_mig_7series_0_memaddr]}
}
catch {delete_bd_objs -quiet [get_bd_addr_segs -quiet M_AXI_TDOT/SEG_mig_7series_0_memaddr]}
if {[catch {
    assign_bd_address -offset 0x80000000 -range 0x10000000 \
        -target_address_space [get_bd_addr_spaces xdma_0/M_AXI] \
        [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force
    assign_bd_address -offset 0x80000000 -range 0x10000000 \
        -target_address_space [get_bd_addr_spaces axi_datamover_0/Data_MM2S] \
        [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force
    assign_bd_address -offset 0x80000000 -range 0x10000000 \
        -target_address_space [get_bd_addr_spaces axi_datamover_1/Data_S2MM] \
        [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force
    assign_bd_address -offset 0x80000000 -range 0x10000000 \
        -target_address_space [get_bd_addr_spaces M_AXI_TDOT] \
        [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force
} _err_ddr]} {
    puts " WARNING: пере-назначение DDR3 не удалось: $_err_ddr (уже назначено в xdma_ddr3_bd.tcl)"
}

# ============================================================================
# 2. Экспорт такта PCIe-домена (axi_aclk_out / axi_aresetn_out / axi_aclk_in)
# ============================================================================
puts "=== 2. Экспорт такта (axi_aclk_out / axi_aresetn_out / axi_aclk_in) ==="

if {[get_bd_ports -quiet axi_aclk_out] eq ""} {
    create_bd_port -dir O axi_aclk_out
}
if {[get_bd_ports -quiet axi_aresetn_out] eq ""} {
    create_bd_port -dir O axi_aresetn_out
}
if {[get_bd_ports -quiet axi_aclk_in] eq ""} {
    create_bd_port -dir I -type clk axi_aclk_in
}
set_property -dict [list CONFIG.FREQ_HZ 125000000] [get_bd_ports axi_aclk_in]

proc _clk_connect {port_name pin_name} {
    set port [get_bd_ports -quiet $port_name]
    set pin  [get_bd_pins  -quiet $pin_name]
    if {$port eq "" || $pin eq ""} { return }
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
# 2b. Экспорт fabric-домена 125 МГц (clk_core_out / core_resetn_out, BUG-034)
# ============================================================================
puts "=== 2b. Экспорт fabric-домена (clk_core_out / core_resetn_out) ==="

if {[get_bd_ports -quiet clk_core_out] eq ""} {
    create_bd_port -dir O -type clk -freq_hz 125000000 clk_core_out
}
if {[get_bd_ports -quiet core_resetn_out] eq ""} {
    create_bd_port -dir O core_resetn_out
}
_clk_connect clk_core_out    clk125_core_wiz/clk_out1
_clk_connect core_resetn_out rst_core_125M/peripheral_aresetn

# ============================================================================
# 3. tdot_irq — IRQ планировщика TDOT -> xdma_0/usr_irq_req (MSI-X вектор 0)
# ============================================================================
puts "=== 3. tdot_irq -> xdma_0/usr_irq_req[0] ==="

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
# 4. make_wrapper (модуль xdma_ddr3_dfx) + file copy
# ============================================================================
puts "=== 4. make_wrapper (xdma_ddr3_dfx) ==="
if {[llength [get_files -quiet xdma_ddr3_dfx.bd]] > 0} {
    make_wrapper -files [get_files xdma_ddr3_dfx.bd] -top -force
    set wrapper_file ""
    foreach _g [glob -nocomplain ${::env(PROJ_DIR_BUILD)}/m2_artix7_xdma_flat.gen/sources_1/bd/xdma_ddr3_dfx/hdl/xdma_ddr3_dfx_wrapper.v] {
        set wrapper_file $_g
    }
    if {${wrapper_file} eq ""} {
        foreach _g [glob -nocomplain ${::env(PROJ_DIR_BUILD)}/*.gen/sources_1/bd/xdma_ddr3_dfx/hdl/xdma_ddr3_dfx_wrapper.v] {
            set wrapper_file $_g
        }
    }
    if {${wrapper_file} eq ""} {
        set wrapper_file [lsearch -inline [get_files -quiet xdma_ddr3_dfx_wrapper.v] true]
    }
    if {${wrapper_file} ne ""} {
        set dst "${SCRIPT_DIR}/../build/xdma_ddr3_dfx_wrapper.v"
        catch {file mkdir [file dirname ${dst}]}
        catch {file copy -force ${wrapper_file} ${dst}}
        puts " wrapper: ${wrapper_file} -> ${dst}"
    } else {
        puts " WARNING: файл обёртки не найден — пропускаю file copy"
    }
} else {
    puts " WARNING: xdma_ddr3_dfx.bd не найден — make_wrapper пропущен"
}

# ============================================================================
# 5. Валидация и сохранение
# ============================================================================
puts "=== 5. Валидация BD ==="
validate_bd_design
save_bd_design

puts "============================================"
puts " POST-BD FLAT: OK"
puts "============================================"
puts " xdma_axi_smc.S03 → M_AXI_TDOT @ DDR3 0x80000000 / BRAM 0x10000000"
puts " xdma_axi_smc.S01/S02 → DataMover MM2S/S2MM @ DDR3 0x80000000"
puts " xdma_axi_lite_smc.M03 → S_AXI_TDOT_REGS @ 0x40023000"
puts " xdma_axi_lite_smc.M04 → S_AXI_XADC_REGS @ 0x46000000"
puts " xdma_axi_lite_smc.M01/M02 → MM2S/S2MM ctrl @ 0x40010000 / 0x40018000"
puts " xdma_axi_lite_smc.M00 → GPIO @ 0x40020000"
puts " clock: axi_aclk_out/aresetn_out (O, XDMA 125), axi_aclk_in (I)"
puts " clock: clk_core_out/core_resetn_out (O, fabric 125 МГц)"
puts " irq:   tdot_irq -> usr_irq_req[0] (MSI-X vector 0)"
puts "============================================"

if {$opened_here} { close_project }