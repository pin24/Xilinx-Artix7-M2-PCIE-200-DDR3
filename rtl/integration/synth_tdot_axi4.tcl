# ============================================================================
# synth_tdot_axi4.tcl - синтез полного ядра tdot_axi4 (AXI master) как top.
# Параметры через -tclargs (формы: NUM_MAC=16 ADDERS=4 ELEM_FMT=2 BURST_RD_LEN=16).
#   vivado -mode batch -source synth_tdot_axi4.tcl -tclargs \
#       NUM_MAC=16 ADDERS=4 ELEM_FMT=2 BURST_RD_LEN=16 BURST_WR_LEN=8
# Одиночное tclarg число = NUM_MAC (как в synth_par_raw).
# Цель: ресурсы/тайминг PACKED6-ядра (ELEM_FMT=2) @125 МГц.
# Обёртка tdot_synth_wrap.generated.sv: параметризует SV-модуль через generic.
# ============================================================================
set PART    "xc7a200tfbg484-2"
set rtl_dir [file normalize [file dirname [file normalize [info script]]]]
set block   [file join [file dirname ${rtl_dir}] block]

# Параметры из переменных окружения (надёжнее, чем tclargs на Windows):
#   set SYNTH_NUM_MAC, SYNTH_ADDERS, SYNTH_ELEM_FMT, SYNTH_BRD_LEN, ...
set num_mac     [expr {[info exists ::env(SYNTH_NUM_MAC)]  ? $::env(SYNTH_NUM_MAC)  : 16}]
set adders      [expr {[info exists ::env(SYNTH_ADDERS)]   ? $::env(SYNTH_ADDERS)   : 4}]
set elem_fmt    [expr {[info exists ::env(SYNTH_ELEM_FMT)] ? $::env(SYNTH_ELEM_FMT) : 2}]
set brd_len     [expr {[info exists ::env(SYNTH_BRD_LEN)]  ? $::env(SYNTH_BRD_LEN)  : 16}]
set bwr_len     [expr {[info exists ::env(SYNTH_BWR_LEN)]  ? $::env(SYNTH_BWR_LEN)  : 8}]
set jobs        [expr {[info exists ::env(SYNTH_JOBS)]     ? $::env(SYNTH_JOBS)     : 19}]

puts "=== synth_tdot_axi4: NUM_MAC=${num_mac} ADDERS=${adders} ELEM_FMT=${elem_fmt} \
BURST_RD_LEN=${brd_len} BURST_WR_LEN=${bwr_len} JOBS=${jobs} PART=${PART} ==="

set proj_dir C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3_2chanle/rtl/integration/synth_out_n${num_mac}
file mkdir ${proj_dir}

create_project -force tdot_synth ${proj_dir} -part ${PART}

add_files -norecurse \
    ${block}/tbyte_add.sv \
    ${block}/tbyte_mul.sv \
    ${block}/tfadd_raw.sv \
    ${block}/tfmul_raw.sv \
    ${block}/tfadd48.sv \
    ${block}/compute_dot_par_raw.sv \
    ${block}/packed6_rd.sv \
    ${block}/packed6_wr.sv \
    ${rtl_dir}/../rtl/tf48_pkg.sv \
    ${rtl_dir}/../rtl/int_to_trits.sv \
    ${rtl_dir}/tdot_axi4.sv

# --- top-обёртка: шаблон + подстановка параметров через string map ---
set tmpl_path [file join ${rtl_dir} tdot_synth_wrap.tmpl.sv]
set fd [open ${tmpl_path} r]
set wdata [read $fd]
close $fd
set wdata [string map [list "%%NUM_MAC%%" ${num_mac} "%%ADDERS%%" ${adders} \
                                    "%%ELEM_FMT%%" ${elem_fmt} "%%BRD_LEN%%" ${brd_len} \
                                    "%%BWR_LEN%%" ${bwr_len}] $wdata]
set wrap ${proj_dir}/tdot_synth_wrap.generated.sv
set fo [open ${wrap} w]
puts -nonewline $fo $wdata
close $fo

add_files -norecurse ${wrap}
set_property top tdot_synth_wrap [current_fileset]
update_compile_order -fileset sources_1

# --- тайминг @125 МГц (через XDC-файл; create_clock требуют открытый design) ---
set xdc_file ${proj_dir}/tdot_synth.xdc
set fx [open ${xdc_file} w]
puts $fx "create_clock -period 8.000 -name clk \[get_ports {S_AXI_ACLK}\]"
puts $fx "set_input_delay  -clock clk 2 \[get_ports {S_AXI_AWADDR S_AXI_AWVALID S_AXI_WDATA S_AXI_WVALID S_AXI_ARADDR S_AXI_ARVALID M_AXI_AWREADY M_AXI_WREADY M_AXI_BID M_AXI_BRESP M_AXI_BVALID M_AXI_ARREADY M_AXI_RID M_AXI_RDATA M_AXI_RRESP M_AXI_RLAST M_AXI_RVALID}\]"
puts $fx "set_output_delay -clock clk 2 \[get_ports {S_AXI_AWREADY S_AXI_WREADY S_AXI_BRESP S_AXI_BVALID S_AXI_ARREADY S_AXI_RDATA S_AXI_RRESP S_AXI_RVALID M_AXI_AWID M_AXI_AWADDR M_AXI_AWLEN M_AXI_AWSIZE M_AXI_AWBURST M_AXI_AWLOCK M_AXI_AWCACHE M_AXI_AWPROT M_AXI_AWQOS M_AXI_AWVALID M_AXI_WDATA M_AXI_WSTRB M_AXI_WLAST M_AXI_WVALID M_AXI_BREADY M_AXI_ARID M_AXI_ARADDR M_AXI_ARLEN M_AXI_ARSIZE M_AXI_ARBURST M_AXI_ARLOCK M_AXI_ARCACHE M_AXI_ARPROT M_AXI_ARQOS M_AXI_ARVALID M_AXI_RREADY sched_irq}\]"
close $fx
add_files -fileset constrs_1 -norecurse ${xdc_file}

launch_runs synth_1 -jobs ${jobs}
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    puts "=== SYNTHESIS FAILED ==="
    exit 1
} else {
    puts "=== SYNTHESIS OK (tdot_axi4 NUM_MAC=${num_mac} ADDERS=${adders} ELEM_FMT=${elem_fmt}) ==="
    open_run synth_1
    report_utilization    -file [file join ${proj_dir} util_tdot_n${num_mac}_a${adders}_e${elem_fmt}.rpt]
    report_timing_summary -file [file join ${proj_dir} timing_tdot_n${num_mac}_a${adders}_e${elem_fmt}.rpt]
    close_design
}
close_project
exit 0