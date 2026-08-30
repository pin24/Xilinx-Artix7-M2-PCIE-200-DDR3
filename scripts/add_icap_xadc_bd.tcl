# ============================================================================
# add_icap_xadc_bd.tcl — расширение axi_periph до 4 мастеров (CANONICAL FIX-5):
#   M00 -> axi_gpio       (0x4000_0000, уже есть в build_all.tcl:48)
#   M01 -> S_AXI_TDOT_REGS(0x4000_1000, уже есть в build_all.tcl:51)
#   M02 -> S_AXI_ICAP_REGS(0x4000_2000, соответствует build_all.tcl:63)
#   M03 -> S_AXI_XADC_REGS(0x4600_0000, соответствует resize_bar0.tcl:52)
# ICAP-контроллер больше не требует M_AXI (пишет напрямую от хоста),
# поэтому axi_smc не расширяется.
#
# FIX-5 RTL-2 (синхронизация с актуальной картой адресов):
#   РАНЬШЕ: M02=XADC @ 0x45000000, M03=ICAP @ 0x46000000 (расходилось с build_all.tcl)
#   ТЕПЕРЬ: M02=ICAP @ 0x40002000,  M03=XADC @ 0x46000000 (совпадает с build_all.tcl
#           и resize_bar0.tcl). Адреса сверены с docs/ADDRESS_MAP.md §2.
#
# FIX-5 RTL-3 (cleanup legacy M_AXI_ICAP, ANALYSIS_AND_SPEC_FIX.md B-3):
#   Удаляется посторонний BD-порт M_AXI_ICAP (64-бит мастер от старой схемы
#   «ICAP как мастер»). После удаления — нужно сделать `make_wrapper -force`
#   (в build_all.tcl:74 уже есть).
#
# Run: vivado -mode batch -source scripts/add_icap_xadc_bd.tcl
# ============================================================================
set proj_dir  C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name m2_artix7_xdma_ddr3

open_project ${proj_dir}/${proj_name}/${proj_name}.xpr
set bd [get_files xdma_ddr3.bd]
open_bd_design $bd

# ----- axi_periph: 4 мастера (M00..M03) -----
set_property -dict [list CONFIG.NUM_MI 4] [get_bd_cells xdma_0_axi_periph]

# ----- S_AXI_ICAP_REGS (Master, наружу -> icap_ctrl.S_AXI), M02 @ 0x40002000 -----
# Внимание: build_all.tcl:53-61 создаёт S_AXI_ICAP_REGS на M02, если его ещё нет.
# Здесь — такая же идемпотентная логика, на случай если BD ещё не обработан build_all.tcl.
set exist [get_bd_intf_ports -quiet S_AXI_ICAP_REGS]
if {$exist eq ""} {
    create_bd_intf_port -mode Master \
        -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_ICAP_REGS
}
set_property -dict [list \
    CONFIG.PROTOCOL AXI4LITE \
    CONFIG.DATA_WIDTH 32 \
    CONFIG.ADDR_WIDTH 8 \
    CONFIG.FREQ_HZ 125000000] [get_bd_intf_ports S_AXI_ICAP_REGS]
connect_bd_intf_net [get_bd_intf_pins xdma_0_axi_periph/M02_AXI] \
    [get_bd_intf_ports S_AXI_ICAP_REGS]

# ----- S_AXI_XADC_REGS (Master, наружу -> xadc_temp.S_AXI), M03 @ 0x46000000 -----
set exist [get_bd_intf_ports -quiet S_AXI_XADC_REGS]
if {$exist eq ""} {
    create_bd_intf_port -mode Master \
        -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_XADC_REGS
}
set_property -dict [list \
    CONFIG.PROTOCOL AXI4LITE \
    CONFIG.DATA_WIDTH 32 \
    CONFIG.ADDR_WIDTH 8 \
    CONFIG.FREQ_HZ 125000000] [get_bd_intf_ports S_AXI_XADC_REGS]
connect_bd_intf_net [get_bd_intf_pins xdma_0_axi_periph/M03_AXI] \
    [get_bd_intf_ports S_AXI_XADC_REGS]

# ----- часы/сброс M02/M03 (оба от xdma_0/axi_aclk, 125 МГц) -----
connect_bd_net [get_bd_pins xdma_0_axi_periph/M02_ACLK] \
    [get_bd_pins xdma_0/axi_aclk]
connect_bd_net [get_bd_pins xdma_0_axi_periph/M02_ARESETN] \
    [get_bd_pins xdma_0/axi_aresetn]
connect_bd_net [get_bd_pins xdma_0_axi_periph/M03_ACLK] \
    [get_bd_pins xdma_0/axi_aclk]
connect_bd_net [get_bd_pins xdma_0_axi_periph/M03_ARESETN] \
    [get_bd_pins xdma_0/axi_aresetn]

# ----- ASSOCIATED_BUSIF для axi_aclk (привязка клокового домена) -----
set old [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins xdma_0/axi_aclk]]
if {[string first "S_AXI_ICAP_REGS" $old] == -1} {
    set new [string trim "$old S_AXI_ICAP_REGS"]
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF $new] \
        [get_bd_pins xdma_0/axi_aclk]
    set old $new
}
if {[string first "S_AXI_XADC_REGS" $old] == -1} {
    set new [string trim "$old S_AXI_XADC_REGS"]
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF $new] \
        [get_bd_pins xdma_0/axi_aclk]
}

# ----- адреса (CANONICAL, соответствуют build_all.tcl + resize_bar0.tcl) -----
set as_lite [get_bd_addr_spaces xdma_0/M_AXI_LITE]

# ICAP на M02: 0x40002000 (build_all.tcl:63)
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_ICAP_REGS_Reg}]
assign_bd_address -offset 0x40002000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs S_AXI_ICAP_REGS/Reg] -force

# XADC на M03: 0x46000000 (resize_bar0.tcl:52, docs/ADDRESS_MAP.md §2)
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_XADC_REGS_Reg}]
assign_bd_address -offset 0x46000000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs S_AXI_XADC_REGS/Reg] -force

# ============================================================================
# FIX-5 RTL-3: cleanup legacy M_AXI_ICAP (ANALYSIS_AND_SPEC_FIX.md B-3)
# ============================================================================
# В BD-обёртке исторически остался интерфейсный порт M_AXI_ICAP (64-бит master)
# от старой схемы «ICAP как мастер». На top-level он не подключён (ICAP теперь
# AXI-Lite slave), что даёт CRITICAL WARNING в impl и бессмысленный floating
# порт в wrapper. Удаляем из BD — после следующего `make_wrapper -force`
# (вызывается в build_all.tcl:74) порт исчезнет и из wrapper.
# ============================================================================
set legacy_icap [get_bd_intf_ports -quiet M_AXI_ICAP]
if {$legacy_icap ne ""} {
    # Отключаем все внутренние соединения этого порта (интерфейсные и обычные сети).
    # M_AXI_ICAP — интерфейсный порт, поэтому в первую очередь ищем intf_nets;
    # обычные bd_nets тут для подстраховки (если Vivado хранит tied-off пины отдельно).
    set legacy_intf_nets [get_bd_intf_nets -quiet -of_objects $legacy_icap]
    if {[llength $legacy_intf_nets] > 0} {
        puts "=== FIX-5 RTL-3: отключаю interface-сети legacy M_AXI_ICAP ==="
        foreach inet $legacy_intf_nets {
            delete_bd_objs $inet
        }
    }
    set legacy_nets [get_bd_nets -quiet -of_objects $legacy_icap]
    if {[llength $legacy_nets] > 0} {
        puts "=== FIX-5 RTL-3: отключаю bd_nets legacy M_AXI_ICAP ==="
        foreach net $legacy_nets {
            delete_bd_objs $net
        }
    }
    delete_bd_objs $legacy_icap
    puts "=== FIX-5 RTL-3: удалён legacy BD-порт M_AXI_ICAP ==="
    puts "                  (после make_wrapper -force он исчезнет из wrapper.v)"
} else {
    puts "=== FIX-5 RTL-3: legacy M_AXI_ICAP уже отсутствует — пропускаю ==="
}

validate_bd_design
save_bd_design
regenerate_bd_layout

puts "=== BD (CANONICAL FIX-5): M00=GPIO@0x40000000, M01=TDOT@0x40001000, M02=ICAP@0x40002000, M03=XADC@0x46000000 ==="
close_project
