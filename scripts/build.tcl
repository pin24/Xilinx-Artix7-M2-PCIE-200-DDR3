# ============================================================================
# build.tcl — Автономная полная сборка проекта в Vivado 2021.2
# ============================================================================
# Создаёт проект с нуля, строит BD (XDMA + MIG DDR3 + GPIO + BRAM),
# добавляет RTL троичного ядра (TFloat48, NUM_MAC=32), ICAP, XADC,
# генерирует wrapper, запускает synth + impl + bitstream, экспортирует
# .bit / .bin / .mcs в build/artifacts/.
#
# Запуск (Windows):
#   cd <repo_root>
#   vivado.bat -mode batch -source scripts/build.tcl
#
# Опциональные аргументы (через -tclargs):
#   NUM_MAC=<16|32|64>   (по умолчанию 32)
#   JOBS=<N>             (по умолчанию 8)
#   SKIP_SYNTH=1         (только создать проект, без сборки)
#
# Пример:
#   vivado.bat -mode batch -source scripts/build.tcl -tclargs NUM_MAC=32 JOBS=12
# ============================================================================

# ---------- 0. Определение путей (без хардкода) ----------
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT       [file normalize "${SCRIPT_DIR}/.."]
set PROJ_NAME  "m2_artix7_xdma_ddr3"
set PROJ_DIR   "${ROOT}/build/${PROJ_NAME}"
set PART       "xc7a200tfbg484-2"
set TOP_NAME   "xdma_ddr3_core_top"

# ---------- 0.1. Парсинг аргументов ----------
set NUM_MAC     32
set JOBS        8
set SKIP_SYNTH  0
foreach arg $argv {
    if {[regexp {^NUM_MAC=(\d+)$} $arg -> v]}     { set NUM_MAC $v }
    if {[regexp {^JOBS=(\d+)$} $arg -> v]}         { set JOBS $v }
    if {[regexp {^SKIP_SYNTH=(\d+)$} $arg -> v]}   { set SKIP_SYNTH $v }
}

puts "============================================================"
puts " BUILD CONFIGURATION"
puts "============================================================"
puts " ROOT       : ${ROOT}"
puts " PROJ_DIR   : ${PROJ_DIR}"
puts " PART       : ${PART}"
puts " TOP        : ${TOP_NAME}"
puts " NUM_MAC    : ${NUM_MAC}"
puts " JOBS       : ${JOBS}"
puts " SKIP_SYNTH : ${SKIP_SYNTH}"
puts "============================================================"

# ---------- 1. Создание проекта ----------
puts "=== 1. CREATE PROJECT ==="
file mkdir [file dirname ${PROJ_DIR}]
create_project -force ${PROJ_NAME} ${PROJ_DIR} -part ${PART}
set_property target_language Verilog [current_project]
set_property target_simulator XSim [current_project]

# ---------- 2. Создание базового BD (XDMA + MIG + GPIO + BRAM) ----------
puts "=== 2. CREATE BASE BD (xdma_ddr3_bd.tcl) ==="
source ${ROOT}/scripts/xdma_ddr3_bd.tcl

# ---------- 3. Добавление RTL троичного ядра ----------
puts "=== 3. ADD RTL ==="
add_files -norecurse \
    ${ROOT}/rtl/block/tbyte_add.sv \
    ${ROOT}/rtl/block/tbyte_mul.sv \
    ${ROOT}/rtl/block/tfadd_raw.sv \
    ${ROOT}/rtl/block/tfmul_raw.sv \
    ${ROOT}/rtl/block/compute_dot_par_raw.sv \
    ${ROOT}/rtl/integration/tdot_axi4.sv \
    ${ROOT}/rtl/integration/icap_ctrl.sv \
    ${ROOT}/rtl/integration/xadc_temp.sv \
    ${ROOT}/rtl/integration/xdma_ddr3_core_top.sv
set_property generic NUM_MAC=${NUM_MAC} [current_fileset]

# ---------- 4. Констрейны ----------
puts "=== 4. ADD CONSTRAINTS ==="
set pins_xdc  ${ROOT}/constraints/xdma_ddr3_pins.xdc
set early_xdc ${ROOT}/constraints/xdma_ddr3_early.xdc
add_files -fileset constrs_1 ${pins_xdc}
add_files -fileset constrs_1 ${early_xdc}
set_property PROCESSING_ORDER EARLY  [get_files ${early_xdc}]
set_property PROCESSING_ORDER NORMAL [get_files ${pins_xdc}]
update_compile_order -fileset constrs_1

# ---------- 5. Настройка BAR0=128MB и карты адресов ----------
puts "=== 5. CONFIGURE BD: BAR0=128MB, ADDRESSES, TDOT/ICAP/XADC PORTS ==="
open_bd_design [get_files xdma_ddr3.bd]

# BAR0 = 128 MB
set_property -dict [list \
    CONFIG.pf0_bar0_scale {Megabytes} \
    CONFIG.pf0_bar0_size {128} \
] [get_bd_cells xdma_0]

# Сразу увеличиваем NUM_MI до 4 (GPIO + TDOT + ICAP + XADC) и NUM_SI до 2 для axi_smc.
# axi_interconnect автоматически создаёт M01/M02/M03 пины при увеличении NUM_MI.
# Вызывается до создания портов — идемпотентно при повторных запусках.
set_property -dict [list CONFIG.NUM_MI 4] [get_bd_cells xdma_0_axi_periph]
set_property -dict [list CONFIG.NUM_SI 2] [get_bd_cells axi_smc]

# ---------- 5.1. GPIO: уменьшить с 64K до 4K (освободить место под TDOT/ICAP) ----------
# NOTE: параметр C_S_AXI_ADDR_WIDTH не существует у axi_gpio (только у axi_bram_ctrl).
# Размер декодирования GPIO управляется через assign_bd_address -range.
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_gpio_0_Reg}]
assign_bd_address -offset 0x40000000 -range 0x1000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force

<<<<<<< HEAD
# ---------- 5.2. S_AXI_TDOT_REGS: Master-порт в BD для tdot_axi4 (slave на top) ----------
# На top-уровне xdma_ddr3_core_top.sv инстанции u_tdot подключается к этому порту.
set tdot_regs_port [get_bd_intf_ports -quiet S_AXI_TDOT_REGS]
if {$tdot_regs_port eq ""} {
    puts "=== Creating S_AXI_TDOT_REGS port (M01 @ 0x40001000) ==="
    # NUM_MI увеличен до 4 в начале секции 5 (идемпотентно)
=======
# TDOT CSRs: 0x40001000 (4K) — создать порт S_AXI_TDOT_REGS если его нет
set tdot_port [get_bd_intf_ports -quiet S_AXI_TDOT_REGS]
if {$tdot_port eq ""} {
    set_property -dict [list CONFIG.NUM_MI 2] [get_bd_cells xdma_0_axi_periph]
>>>>>>> 6313fd0 (DFX integration: xdma_ddr3_dfx BD, icap_ctrl fix, address map, driver, build scripts)
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_TDOT_REGS
    set_property -dict [list CONFIG.PROTOCOL AXI4LITE CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 8 CONFIG.FREQ_HZ 125000000] [get_bd_intf_ports S_AXI_TDOT_REGS]
    connect_bd_intf_net [get_bd_intf_pins xdma_0_axi_periph/M01_AXI] [get_bd_intf_ports S_AXI_TDOT_REGS]
    connect_bd_net [get_bd_pins xdma_0_axi_periph/M01_ACLK] [get_bd_pins xdma_0/axi_aclk]
    connect_bd_net [get_bd_pins xdma_0_axi_periph/M01_ARESETN] [get_bd_pins xdma_0/axi_aresetn]
<<<<<<< HEAD
    # ASSOCIATED_BUSIF: привязать S_AXI_TDOT_REGS к клоковому домену xdma_0/axi_aclk
    set old_assoc [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins xdma_0/axi_aclk]]
    if {[string first "S_AXI_TDOT_REGS" $old_assoc] == -1} {
        set new_assoc [string trim "$old_assoc S_AXI_TDOT_REGS"]
        set_property -dict [list CONFIG.ASSOCIATED_BUSIF $new_assoc] [get_bd_pins xdma_0/axi_aclk]
    }
=======
>>>>>>> 6313fd0 (DFX integration: xdma_ddr3_dfx BD, icap_ctrl fix, address map, driver, build scripts)
}
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_TDOT_REGS_Reg}]
assign_bd_address -offset 0x40001000 -range 0x1000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs S_AXI_TDOT_REGS/Reg] -force

# ---------- 5.3. S_AXI_ICAP_REGS: Master-порт для icap_ctrl (slave на top) ----------
set icap_port [get_bd_intf_ports -quiet S_AXI_ICAP_REGS]
if {$icap_port eq ""} {
    puts "=== Creating S_AXI_ICAP_REGS port (M02 @ 0x40002000) ==="
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_ICAP_REGS
    set_property -dict [list CONFIG.PROTOCOL AXI4LITE CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 8 CONFIG.FREQ_HZ 125000000] [get_bd_intf_ports S_AXI_ICAP_REGS]
    connect_bd_intf_net [get_bd_intf_pins xdma_0_axi_periph/M02_AXI] [get_bd_intf_ports S_AXI_ICAP_REGS]
    connect_bd_net [get_bd_pins xdma_0_axi_periph/M02_ACLK] [get_bd_pins xdma_0/axi_aclk]
    connect_bd_net [get_bd_pins xdma_0_axi_periph/M02_ARESETN] [get_bd_pins xdma_0/axi_aresetn]
    set old_assoc [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins xdma_0/axi_aclk]]
    if {[string first "S_AXI_ICAP_REGS" $old_assoc] == -1} {
        set new_assoc [string trim "$old_assoc S_AXI_ICAP_REGS"]
        set_property -dict [list CONFIG.ASSOCIATED_BUSIF $new_assoc] [get_bd_pins xdma_0/axi_aclk]
    }
}
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_ICAP_REGS_Reg}]
assign_bd_address -offset 0x40002000 -range 0x1000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs S_AXI_ICAP_REGS/Reg] -force

# ---------- 5.4. S_AXI_XADC_REGS: Master-порт для xadc_temp (slave на top) ----------
set xadc_port [get_bd_intf_ports -quiet S_AXI_XADC_REGS]
if {$xadc_port eq ""} {
    puts "=== Creating S_AXI_XADC_REGS port (M03 @ 0x46000000) ==="
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_XADC_REGS
    set_property -dict [list CONFIG.PROTOCOL AXI4LITE CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 8 CONFIG.FREQ_HZ 125000000] [get_bd_intf_ports S_AXI_XADC_REGS]
    connect_bd_intf_net [get_bd_intf_pins xdma_0_axi_periph/M03_AXI] [get_bd_intf_ports S_AXI_XADC_REGS]
    connect_bd_net [get_bd_pins xdma_0_axi_periph/M03_ACLK] [get_bd_pins xdma_0/axi_aclk]
    connect_bd_net [get_bd_pins xdma_0_axi_periph/M03_ARESETN] [get_bd_pins xdma_0/axi_aresetn]
}
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_XADC_REGS_Reg}]
assign_bd_address -offset 0x46000000 -range 0x1000 -target_address_space [get_bd_addr_spaces xdma_0/M_AXI_LITE] [get_bd_addr_segs S_AXI_XADC_REGS/Reg] -force

<<<<<<< HEAD
# ---------- 5.5. M_AXI_TDOT: Slave-порт в BD для tdot_axi4 master (доступ к DDR3) ----------
# tdot_axi4 читает data/weights из DDR3 и пишет результат — нужен master-выход в BD.
set m_axi_tdot_port [get_bd_intf_ports -quiet M_AXI_TDOT]
if {$m_axi_tdot_port eq ""} {
    puts "=== Creating M_AXI_TDOT slave port (S01 of axi_smc for DDR3 access) ==="
    # NUM_SI axi_smc уже увеличен до 2 в начале секции 5
    create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_TDOT
    set_property -dict [list CONFIG.PROTOCOL AXI4 CONFIG.DATA_WIDTH 64 CONFIG.ADDR_WIDTH 32 CONFIG.FREQ_HZ 125000000] [get_bd_intf_ports M_AXI_TDOT]
    connect_bd_intf_net [get_bd_intf_ports M_AXI_TDOT] [get_bd_intf_pins axi_smc/S01_AXI]
    # ACLK/ARESETN для S01
    connect_bd_net [get_bd_pins axi_smc/aclk] [get_bd_pins xdma_0/axi_aclk]
    # Адрес: tdot_axi4 видит DDR3 по тому же адресу, что и XDMA (0x80000000+)
    assign_bd_address -offset 0x80000000 -range 0x10000000 -target_address_space [get_bd_addr_spaces M_AXI_TDOT] [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force
    # ASSOCIATED_BUSIF для клока
    set old_assoc [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins xdma_0/axi_aclk]]
    if {[string first "M_AXI_TDOT" $old_assoc] == -1} {
        set new_assoc [string trim "$old_assoc M_AXI_TDOT"]
        set_property -dict [list CONFIG.ASSOCIATED_BUSIF $new_assoc] [get_bd_pins xdma_0/axi_aclk]
    }
}
=======
# ---------- 5a. M_AXI_TDOT (slave port, подключается к tdot_axi4.M_AXI) ----------
puts "=== 5a. ADD M_AXI_TDOT (AXI4 slave -> axi_smc/S01_AXI) ==="
set tdot_m_port [get_bd_intf_ports -quiet M_AXI_TDOT]
if {$tdot_m_port eq ""} {
    create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_TDOT
}
set_property -dict [list \
    CONFIG.PROTOCOL AXI4 \
    CONFIG.DATA_WIDTH 64 \
    CONFIG.ADDR_WIDTH 32 \
    CONFIG.NUM_READ_OUTSTANDING 2 \
    CONFIG.NUM_WRITE_OUTSTANDING 2 \
    CONFIG.FREQ_HZ 125000000 \
] [get_bd_intf_ports M_AXI_TDOT]

# axi_smc: второй slave порт
set_property -dict [list CONFIG.NUM_SI 2] [get_bd_cells axi_smc]
connect_bd_intf_net [get_bd_intf_pins axi_smc/S01_AXI] [get_bd_intf_ports M_AXI_TDOT]

# адресные сегменты для M_AXI_TDOT (DDR3 + BRAM)
assign_bd_address -offset 0x80000000 -range 0x10000000 \
    -target_address_space [get_bd_addr_spaces M_AXI_TDOT] \
    [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force
assign_bd_address -offset 0x00000000 -range 0x00002000 \
    -target_address_space [get_bd_addr_spaces M_AXI_TDOT] \
    [get_bd_addr_segs axi_bram_ctrl_0/S_AXI/Mem0] -force

# ---------- 5b. Экспорт такта PCIe-домена из BD ----------
puts "=== 5b. EXPORT CLOCK FROM BD (axi_aclk_out / axi_aresetn_out / axi_aclk_in) ==="
if {[get_bd_ports -quiet axi_aclk_out] eq ""} {
    create_bd_port -dir O axi_aclk_out
}
if {[get_bd_ports -quiet axi_aresetn_out] eq ""} {
    create_bd_port -dir O axi_aresetn_out
}
if {[get_bd_ports -quiet axi_aclk_in] eq ""} {
    create_bd_port -dir I -type clk axi_aclk_in
}
set_property -dict [list \
    CONFIG.FREQ_HZ 125000000 \
    CONFIG.ASSOCIATED_BUSIF {M_AXI_TDOT} \
] [get_bd_ports axi_aclk_in]

proc _clk_connect {port_name pin_name} {
    set port [get_bd_ports -quiet $port_name]
    set pin  [get_bd_pins  -quiet $pin_name]
    if {$port eq "" || $pin eq ""} { return }
    set npin [get_bd_nets -quiet -of_objects $pin]
    if {[llength $npin] == 0} {
        connect_bd_net $port $pin
        puts "=== CLOCK: $pin_name -> $port_name ==="
    }
}
_clk_connect axi_aclk_out    xdma_0/axi_aclk
_clk_connect axi_aresetn_out xdma_0/axi_aresetn
>>>>>>> 6313fd0 (DFX integration: xdma_ddr3_dfx BD, icap_ctrl fix, address map, driver, build scripts)

# Cleanup legacy M_AXI_ICAP port (если остался от старой схемы)
set legacy_icap [get_bd_intf_ports -quiet M_AXI_ICAP]
if {$legacy_icap ne ""} {
    set legacy_intf_nets [get_bd_intf_nets -quiet -of_objects $legacy_icap]
    foreach inet $legacy_intf_nets { delete_bd_objs $inet }
    set legacy_nets [get_bd_nets -quiet -of_objects $legacy_icap]
    foreach net $legacy_nets { delete_bd_objs $net }
    delete_bd_objs $legacy_icap
    puts "=== Removed legacy M_AXI_ICAP port ==="
}

validate_bd_design
save_bd_design
puts "=== BD: GPIO 0x40000000, TDOT 0x40001000, ICAP 0x40002000, XADC 0x46000000 ==="

# ---------- 6. (сделано в шаге 5b) ----------

# ---------- 7. Regenerate wrapper ----------
puts "=== 7. REGENERATE WRAPPER ==="
make_wrapper -files [get_files xdma_ddr3.bd] -top -force
set_property top ${TOP_NAME} [current_fileset]
update_compile_order -fileset sources_1
update_compile_order -fileset constrs_1

# ---------- 8. Demote PCIe IP XDC (early lane order must win) ----------
puts "=== 8. DEMOTE PCIE IP XDC ==="
set pcie_ip_xdc [get_files -all -quiet *PCIE_X0Y0.xdc]
if {$pcie_ip_xdc ne ""} {
    set_property PROCESSING_ORDER NORMAL ${pcie_ip_xdc}
    puts "=== PCIE IP xdc set to NORMAL (pre-synth): ${pcie_ip_xdc} ==="
} else {
    puts "=== PCIE IP xdc not found yet (will retry after synth) ==="
}

if ${SKIP_SYNTH} {
    puts "=== SKIP_SYNTH=1 — project created, exiting before synth ==="
    save_project_as ${PROJ_DIR}/${PROJ_NAME}.xpr -force
    close_project
    exit 0
}

# ---------- 9. Synthesis ----------
puts "=== 9. SYNTHESIS ==="
reset_run synth_1 -quiet
reset_run impl_1 -quiet
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
launch_runs synth_1 -jobs ${JOBS}
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    puts "=== SYNTHESIS FAILED ==="
    close_project
    exit 1
}

# Re-apply PCIe IP XDC demotion after synth (file is generated during OOC)
set pcie_ip_xdc [get_files -all -quiet *PCIE_X0Y0.xdc]
if {$pcie_ip_xdc ne ""} {
    set_property PROCESSING_ORDER NORMAL ${pcie_ip_xdc}
    puts "=== PCIE IP xdc set to NORMAL (post-synth): ${pcie_ip_xdc} ==="
} else {
    puts "=== WARNING: PCIE IP xdc STILL not found after synth ==="
}

# ---------- 10. Implementation + Bitstream ----------
puts "=== 10. IMPLEMENTATION + BITSTREAM ==="
launch_runs impl_1 -to_step write_bitstream -jobs ${JOBS}
wait_on_run impl_1
set st2 [get_property STATUS [get_runs impl_1]]
puts "=== IMPL STATUS: $st2 ==="
if {[string first "complete" [string tolower $st2]] == -1} {
    puts "=== IMPLEMENTATION FAILED ==="
    close_project
    exit 1
}

# ---------- 11. Export artifacts (.bit / .bin / .mcs) ----------
puts "=== 11. EXPORT ARTIFACTS ==="
open_run impl_1

set ARTIFACTS_DIR "${ROOT}/build/artifacts"
file mkdir ${ARTIFACTS_DIR}

set bit_file "${ARTIFACTS_DIR}/${TOP_NAME}.bit"
set bin_file "${ARTIFACTS_DIR}/${TOP_NAME}.bin"
set mcs_file "${ARTIFACTS_DIR}/${TOP_NAME}.mcs"

write_bitstream -force -raw_bitfile ${bit_file}
write_bitstream -force -bin_file    ${bin_file}
write_cfgmem -force -format mcs -size 128 -interface SPIx4 \
    -loadbit "up 0x0 ${bit_file}" ${mcs_file}

# Копируем логи и отчёты
foreach rpt {utilization.txt timing_summary.rpt} {
    set src ""
    catch { set src [get_property DIRECTORY [get_runs impl_1]]/${rpt} }
    if {[file exists ${src}]} {
        file copy -force ${src} ${ARTIFACTS_DIR}/${rpt}
    }
}

close_project

puts "============================================================"
puts " BUILD COMPLETE"
puts "============================================================"
puts " Bitstream : ${bit_file}"
puts " Binary    : ${bin_file}"
puts " MCS       : ${mcs_file}"
puts " Artifacts : ${ARTIFACTS_DIR}"
puts "============================================================"
