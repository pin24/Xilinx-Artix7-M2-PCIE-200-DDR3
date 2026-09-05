# ============================================================================
# post_bd_dfx.tcl — постобработка DFX Block Design
# ============================================================================
# Добавляет в xdma_ddr3_dfx.bd:
#   M_AXI_TDOT      (tdot_axi4 AXI4 master → xdma_axi_smc/S02_AXI)
#   S_AXI_TDOT_REGS (tdot_axi4 AXI-Lite slave → xdma_axi_lite_smc/M03)
#   S_AXI_ICAP_REGS (icap_ctrl AXI-Lite slave → xdma_axi_lite_smc/M04)
#   S_AXI_XADC_REGS (xadc_temp AXI-Lite slave → xdma_axi_lite_smc/M05)
#   axi_aclk_out / axi_aresetn_out / axi_aclk_in (экспорт такта PCIe-домена)
#   clk_core_out / core_resetn_out (экспорт fabric-домена 125 МГц, BUG-034)
#   Апертуры DFX Partition + карта адресов
#
# Идемпотентно: можно вызывать многократно.
# Запуск: vivado -mode batch -source scripts/post_bd_dfx.tcl
# Вызывается из build_dfx.tcl (шаг 2b).
#
# ВАЖНО (BUG-017 из ERROR_HISTORY.md):
# CLK_DOMAIN на внешних портах НЕ задаётся — Vivado 2025.2 auto-derive его
# из подключённого SmartConnect. Задание CLK_DOMAIN={xdma_0/axi_aclk}
# приводило к mismatch с wrapper-именем xdma_ddr3_dfx_xdma_0_0_axi_aclk.
# ============================================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]

# ---------- 0. Открыть проект/BD (идемпотентно) ----------
set opened_here 0
if {[catch {current_project}] != 0} {
    # Поиск .xpr в порядке приоритета:
    #   1) $::env(PROJ_DIR_BUILD) — выставляется build_dfx.tcl;
    #   2) ${SCRIPT_DIR}/../build/ (Linux-дефолт build_dfx.tcl);
    #   3) C:/build_dfx (Windows-дефолт build_dfx.tcl, легаси-совместимость).
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
# 1. M_AXI_TDOT — AXI4 master от tdot_axi4 к DDR3
# ============================================================================
puts "=== 1. M_AXI_TDOT (slave порт → xdma_axi_smc/S02_AXI) ==="

set tdot_m_port [get_bd_intf_ports -quiet M_AXI_TDOT]
if {$tdot_m_port eq ""} {
    create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_TDOT
}
# НЕ задаём CLK_DOMAIN — Vivado auto-derive из подключённого SmartConnect.
# Задание CLK_DOMAIN={xdma_0/axi_aclk} приводило к mismatch (BUG-017).
set_property -dict [list \
    CONFIG.PROTOCOL AXI4 \
    CONFIG.DATA_WIDTH 64 \
    CONFIG.ADDR_WIDTH 32 \
    CONFIG.NUM_READ_OUTSTANDING 2 \
    CONFIG.NUM_WRITE_OUTSTANDING 2 \
    CONFIG.FREQ_HZ 125000000 \
] [get_bd_intf_ports M_AXI_TDOT]

# xdma_axi_smc: 3 slave порта (S00=XDMA, S01=DFX socket, S02=M_AXI_TDOT)
set_property -dict [list CONFIG.NUM_SI 3] [get_bd_cells xdma_axi_smc]
connect_bd_intf_net [get_bd_intf_pins xdma_axi_smc/S02_AXI] [get_bd_intf_ports M_AXI_TDOT]
# BUG-034: S02 в fabric-домене 125 МГц (вместе с S01) — расширяем ассоциацию
# aclk2 (база ставила только S01_AXI; порта S02 тогда ещё не было).
set_property CONFIG.ASSOCIATED_BUSIF {S01_AXI:S02_AXI} [get_bd_pins xdma_axi_smc/aclk2]

# адрес: DDR3 0x80000000 (256 MB)
assign_bd_address -offset 0x80000000 -range 0x10000000 \
    -target_address_space [get_bd_addr_spaces M_AXI_TDOT] \
    [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force

puts "=== M_AXI_TDOT → xdma_axi_smc/S02_AXI @ DDR3 0x80000000 ==="

# ============================================================================
# 2. S_AXI_TDOT_REGS — регистры tdot_axi4
# ============================================================================
puts "=== 2. S_AXI_TDOT_REGS (AXI-Lite → xdma_axi_lite_smc/M03 @ 0x40003000) ==="

set tdot_port [get_bd_intf_ports -quiet S_AXI_TDOT_REGS]
if {$tdot_port eq ""} {
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_TDOT_REGS
}
# НЕ задаём CLK_DOMAIN — SmartConnect с единым aclk; Vivado 2025.2 выводит
# домен автоматически из подключенного SmartConnect (явная установка
# приводила к BUG-017: wrapper-name mismatch).
set_property -dict [list \
    CONFIG.PROTOCOL AXI4LITE \
    CONFIG.DATA_WIDTH 32 \
    CONFIG.ADDR_WIDTH 8 \
    CONFIG.FREQ_HZ 125000000 \
] [get_bd_intf_ports S_AXI_TDOT_REGS]

# расширяем lite SMC до 6 мастеров
set_property -dict [list CONFIG.NUM_MI 6] [get_bd_cells xdma_axi_lite_smc]
connect_bd_intf_net [get_bd_intf_pins xdma_axi_lite_smc/M03_AXI] [get_bd_intf_ports S_AXI_TDOT_REGS]

delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_TDOT_REGS_Reg}]
assign_bd_address -offset 0x40003000 -range 0x1000 \
    -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] \
    [get_bd_addr_segs S_AXI_TDOT_REGS/Reg] -force

# BUG-034: M03-M05 — экспортируемые порты без локального клока-соседа,
# домен по инференсу не определить — расширяем ассоциацию aclk1 (fabric 125 МГц).
set_property CONFIG.ASSOCIATED_BUSIF {M00_AXI:M01_AXI:M02_AXI:M03_AXI} [get_bd_pins xdma_axi_lite_smc/aclk1]

# ============================================================================
# 3. S_AXI_ICAP_REGS — регистры ICAP
# ============================================================================
puts "=== 3. S_AXI_ICAP_REGS (AXI-Lite → xdma_axi_lite_smc/M04 @ 0x40004000) ==="

set icap_port [get_bd_intf_ports -quiet S_AXI_ICAP_REGS]
if {$icap_port eq ""} {
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_ICAP_REGS
}
set_property -dict [list \
    CONFIG.PROTOCOL AXI4LITE \
    CONFIG.DATA_WIDTH 32 \
    CONFIG.ADDR_WIDTH 8 \
    CONFIG.FREQ_HZ 125000000 \
] [get_bd_intf_ports S_AXI_ICAP_REGS]

connect_bd_intf_net [get_bd_intf_pins xdma_axi_lite_smc/M04_AXI] [get_bd_intf_ports S_AXI_ICAP_REGS]

delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_ICAP_REGS_Reg}]
assign_bd_address -offset 0x40004000 -range 0x1000 \
    -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] \
    [get_bd_addr_segs S_AXI_ICAP_REGS/Reg] -force

set_property CONFIG.ASSOCIATED_BUSIF {M00_AXI:M01_AXI:M02_AXI:M03_AXI:M04_AXI} [get_bd_pins xdma_axi_lite_smc/aclk1]

# ============================================================================
# 4. S_AXI_XADC_REGS — регистры XADC
# ============================================================================
puts "=== 4. S_AXI_XADC_REGS (AXI-Lite → xdma_axi_lite_smc/M05 @ 0x46000000) ==="

set xadc_port [get_bd_intf_ports -quiet S_AXI_XADC_REGS]
if {$xadc_port eq ""} {
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_XADC_REGS
}
set_property -dict [list \
    CONFIG.PROTOCOL AXI4LITE \
    CONFIG.DATA_WIDTH 32 \
    CONFIG.ADDR_WIDTH 8 \
    CONFIG.FREQ_HZ 125000000 \
] [get_bd_intf_ports S_AXI_XADC_REGS]

connect_bd_intf_net [get_bd_intf_pins xdma_axi_lite_smc/M05_AXI] [get_bd_intf_ports S_AXI_XADC_REGS]

delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_XADC_REGS_Reg}]
assign_bd_address -offset 0x46000000 -range 0x1000 \
    -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] \
    [get_bd_addr_segs S_AXI_XADC_REGS/Reg] -force

set_property CONFIG.ASSOCIATED_BUSIF {M00_AXI:M01_AXI:M02_AXI:M03_AXI:M04_AXI:M05_AXI} [get_bd_pins xdma_axi_lite_smc/aclk1]

# ============================================================================
# 4b. ASSOCIATED_BUSIF для axi_aclk — ВНИМАНИЕ (BUG-017 follow-up):
# XDMA IP в Vivado 2025.2 делает ASSOCIATED_BUSIF на пине axi_aclk READ-ONLY
# (CRITICAL WARNING: [BD 41-737] Cannot set the parameter ASSOCIATED_BUSIF
# on /xdma_0/axi_aclk. It is read-only). Пропускаем эту настройку — Vivado
# auto-derive clock domain association из подключённых интерфейсов.
# ============================================================================

# ============================================================================
# 4c. XADC — ВАЖНО: НЕ создаём отдельный xadc_wiz IP (BUG-031)
# ============================================================================
# Artix-7 XC7A200T имеет ТОЛЬКО 1 XADC на кристалле.
# MIG 7-series IP в DFX-варианте отключил XADC (см. xdma_ddr3_dfx_bd.tcl:199:
#   <XADC_En>Off</XADC_En>
# — чтобы избежать UTLZ-1 при добавлении хост-доступа к XADC через xadc_temp.sv).
# Если добавить xadc_wiz, то UTLZ-1 снова появится (2 XADC на 1 кристалл).
#   site is available).
#
# monitor_temp.py должен читать температуру через:
#   (1) AXI GPIO (axi_gpio_0) — уже подключён к mig7_status_concat (MIG status)
#       в xdma_ddr3_dfx_bd.tcl. MIG экспортирует температуру в status-regs.
#   (2) ИЛИ через MIG DRP (если нужна точность).
#
# u_xadc в xdma_ddr3_core_top.sv остаётся с raw_temp=0/raw_vccint=0/
# raw_valid=0 — AXI-Lite slave отвечает (для register access tests),
# но значения TEMP/VCCINT = 0 до подключения к MIG status bus.
# ============================================================================

puts "=== 4c. XADC Wizard SKIPPED (BUG-031: XADC over-utilized, MIG already uses it) ==="

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
# XDMA 64-бит тактирует axi_aclk частотой 250 МГц; ядро/RP/периферия
# остаются на 125 МГц (clk125_core_wiz, создан в xdma_ddr3_dfx_bd.tcl).
# Топ (xdma_ddr3_core_top.sv) получает их как core_clk/core_resetn.
puts "=== 5b. Экспорт fabric-домена (clk_core_out / core_resetn_out) ==="

if {[get_bd_ports -quiet clk_core_out] eq ""} {
    create_bd_port -dir O clk_core_out
}
if {[get_bd_ports -quiet core_resetn_out] eq ""} {
    create_bd_port -dir O core_resetn_out
}
_clk_connect clk_core_out    clk125_core_wiz/clk_out1
_clk_connect core_resetn_out rst_core_125M/peripheral_aresetn

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
puts " xdma_axi_smc.S02 → M_AXI_TDOT @ DDR3 0x80000000 (fabric 125 МГц, BUG-034)"
puts " xdma_axi_lite_smc.M03 → S_AXI_TDOT_REGS @ 0x40003000"
puts " xdma_axi_lite_smc.M04 → S_AXI_ICAP_REGS @ 0x40004000"
puts " xdma_axi_lite_smc.M05 → S_AXI_XADC_REGS @ 0x46000000"
puts " clock: axi_aclk_out/aresetn_out (O, XDMA 250), axi_aclk_in (I)"
puts " clock: clk_core_out/core_resetn_out (O, fabric 125 МГц, BUG-034)"
puts "============================================"

if {$opened_here} { close_project }
