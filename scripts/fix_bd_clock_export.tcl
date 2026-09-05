# ============================================================================
# [DEPRECATED — легаси не-DFX потока]
# Этот разовый helper относится к старой (не-DFX) интеграции и в активный
# DFX-поток НЕ входит: пути C:/A7_M2/EXAMPLES/XDMA_DDR3 устарели, часть
# файлов (build_all.tcl, build_existing.tcl, xdma_ddr3.bd) отсутствует.
# Активная сборка: scripts/build_dfx.tcl (vivado -mode batch -source ...).
# Оставлен для истории — не использовать в новых сборках.
# ============================================================================
# ============================================================================
# fix_bd_clock_export.tcl — экспорт такта/сброса PCIe-домена из BD
# ============================================================================
# Проблема: BD не экспортировал axi_aclk/axi_aresetn наружу, из-за чего
# top-level (xdma_ddr3_core_top.sv) тактировал ускоритель tdot_axi4 и ICAP
# неявными неподключёнными проводами — в собранном битстриме они мертвы.
#
# Что делает скрипт (идемпотентно, можно вызывать на каждой сборке):
#   axi_aclk_out    (O) <- xdma_0/axi_aclk     — такт PCIe/AXI-домена 125 МГц
#   axi_aresetn_out (O) <- xdma_0/axi_aresetn  — сброс домена
#   axi_aclk_in     (I, type clk, 125 МГц, CONFIG.ASSOCIATED_BUSIF = M_AXI_TDOT)
#     В top-level axi_aclk_out замыкается на axi_aclk_in (одна цепь, loopback).
#     ASSOCIATED_BUSIF привязывает внешний slave-интерфейс M_AXI_TDOT к домену
#     125 МГц и убирает DRC SmartConnect "S01_AXI do not share a common clock
#     domain" (см. build/vivado_build.log:81).
#
# Примечание: CRITICAL WARNING для S02_AXI остаётся — там висит брошенный
# порт M_AXI_ICAP (наследие старой схемы, на top не заведён). Чистится отдельно.
#
# Вызывается из build_all.tcl (проект и BD уже открыты — переоткрытие не нужно),
# либо вручную: vivado -mode batch -source scripts/fix_bd_clock_export.tcl
# ============================================================================
set proj_dir  C:/A7_M2/EXAMPLES/XDMA_DDR3
set proj_name m2_artix7_xdma_ddr3

# открыть проект/BD только если ещё не открыты (внутри build_all.tcl уже открыты)
set opened_here 0
if {[catch {current_project}] != 0} {
    puts "=== CLOCK EXPORT: OPEN PROJECT ==="
    open_project ${proj_dir}/${proj_name}/${proj_name}.xpr
    set opened_here 1
}
if {[llength [get_bd_designs -quiet]] == 0} {
    open_bd_design [get_files xdma_ddr3.bd]
}

# ----- M_AXI_TDOT должен существовать (создаётся add_tdot_axi4_bd.tcl) -----
if {[get_bd_intf_ports -quiet M_AXI_TDOT] eq ""} {
    puts "ERROR: интерфейсный порт M_AXI_TDOT не найден в BD."
    puts "       Сначала запустите: vivado -mode batch -source scripts/add_tdot_axi4_bd.tcl"
    close_project
    exit 1
}

# ----- 1. порты (идемпотентно: create только если ещё нет) -----
if {[get_bd_ports -quiet axi_aclk_out] eq ""} {
    create_bd_port -dir O axi_aclk_out
    puts "=== CLOCK EXPORT: создан порт axi_aclk_out ==="
}
if {[get_bd_ports -quiet axi_aresetn_out] eq ""} {
    create_bd_port -dir O axi_aresetn_out
    puts "=== CLOCK EXPORT: создан порт axi_aresetn_out ==="
}
if {[get_bd_ports -quiet axi_aclk_in] eq ""} {
    create_bd_port -dir I -type clk axi_aclk_in
    puts "=== CLOCK EXPORT: создан порт axi_aclk_in ==="
}
set_property -dict [list \
    CONFIG.FREQ_HZ 125000000 \
    CONFIG.ASSOCIATED_BUSIF {M_AXI_TDOT} \
] [get_bd_ports axi_aclk_in]

# ----- 2. подключение к xdma_0 (пин, уже подключённый к сети, не трогаем) -----
proc clk_export_connect {port_name pin_name} {
    set port [get_bd_ports -quiet $port_name]
    set pin  [get_bd_pins  -quiet $pin_name]
    if {$port eq "" || $pin eq ""} {
        puts "ERROR: не найден порт '$port_name' или пин '$pin_name'"
        close_project
        exit 1
    }
    set npin [get_bd_nets -quiet -of_objects $pin]
    if {[llength $npin] == 0} {
        connect_bd_net $port $pin
        puts "=== CLOCK EXPORT: $pin_name -> $port_name ==="
    } else {
        puts "=== CLOCK EXPORT: $pin_name уже подключён ([get_property NAME $npin]), пропускаю ==="
    }
}
clk_export_connect axi_aclk_out    xdma_0/axi_aclk
clk_export_connect axi_aresetn_out xdma_0/axi_aresetn

# ----- 3. validate + save (обёртку регенерирует build_all.tcl: make_wrapper -force) -----
validate_bd_design
save_bd_design
puts "=== CLOCK EXPORT: OK (axi_aclk_out / axi_aresetn_out / axi_aclk_in) ==="

if {$opened_here} { close_project }
