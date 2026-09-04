# ============================================================================
# build_dfx.tcl — ПОЛНАЯ СБОРКА DFX-варианта проекта
#
# Создаёт проект с нуля, строит DFX BD (xdma_ddr3_dfx.bd),
# постит его (post_bd_dfx.tcl), добавляет RTL, констрейны,
# запускает synth + impl + bitstream.
#
# Запуск:
#   vivado.bat -mode batch -source scripts/build_dfx.tcl
#
# Опциональные аргументы (через -tclargs):
#   NUM_MAC=<16|32|64>   (по умолчанию 32)
#   JOBS=<N>             (по умолчанию 8)
#   SKIP_SYNTH=1         (только создать проект, без сборки)
# ============================================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT       [file normalize "${SCRIPT_DIR}/.."]
set PROJ_NAME  "m2_artix7_xdma_ddr3_dfx"
# Каталог проекта (переносимый):
#   1) переменная окружения PROJ_DIR — наивысший приоритет;
#   2) Windows: C:/build_dfx (короткий корень диска — обход лимита MAX_PATH 260,
#      на который наступает генерация MIG IP; build.bat дополнительно делает
#      subst репозитория);
#   3) Linux/macOS: ${ROOT}/build/dfx_proj (внутри репозитория).
# Выбранный каталог экспортируется дочерним скриптам (mig_refclk_post.tcl,
# post_bd_dfx.tcl) через переменную окружения PROJ_DIR_BUILD.
if {[info exists ::env(PROJ_DIR)] && ${::env(PROJ_DIR)} ne ""} {
    set PROJ_DIR [file normalize ${::env(PROJ_DIR)}]
} elseif {$tcl_platform(platform) eq "windows"} {
    set PROJ_DIR "C:/build_dfx"
} else {
    set PROJ_DIR [file normalize "${ROOT}/build/dfx_proj"]
}
set ::env(PROJ_DIR_BUILD) ${PROJ_DIR}
set PART       "xc7a200tfbg484-2"
set TOP_NAME   "xdma_ddr3_core_top"

set NUM_MAC     32
set JOBS        8
set SKIP_SYNTH  0
foreach arg $argv {
    if {[regexp {^NUM_MAC=(\d+)$} $arg -> v]}     { set NUM_MAC $v }
    if {[regexp {^JOBS=(\d+)$} $arg -> v]}         { set JOBS $v }
    if {[regexp {^SKIP_SYNTH=(\d+)$} $arg -> v]}   { set SKIP_SYNTH $v }
}

puts "============================================================"
puts " BUILD_DFX CONFIGURATION"
puts "============================================================"
puts " ROOT       : ${ROOT}"
puts " PROJ_DIR   : ${PROJ_DIR}"
puts " PART       : ${PART}"
puts " TOP        : ${TOP_NAME}"
puts " NUM_MAC    : ${NUM_MAC}"
puts " JOBS       : ${JOBS}"
puts " SKIP_SYNTH : ${SKIP_SYNTH}"
puts "============================================================"

# ---------- 1. Создание проекта (с полной очисткой кэша) ----------
puts "=== 1. CREATE PROJECT ==="
file mkdir [file dirname ${PROJ_DIR}]

# ============================================================================
# Полная очистка ${PROJ_DIR} перед create_project.
# ============================================================================
# Vivado кэширует IP-генерацию в нескольких местах:
#   - ${PROJ_DIR}                              (Vivado проект, .xpr + .srcs)
#   - ${PROJ_DIR}.cache/                       (IP cache — синтез OOC IP)
#   - ${PROJ_DIR}.gen/                         (сгенерированные HDL/обёртки)
#   - ${PROJ_DIR}.hw/                          (hardware handoff)
#   - ${PROJ_DIR}.ip_user_files/               (IP user files)
#   - ${PROJ_DIR}.sim/                         (simulation outputs)
#   - ${PROJ_DIR}.runs/                        (synth_1, impl_1 runs)
#   - ${PROJ_DIR}.srcs/                        (sources, BD, constrs)
#   - ${PROJ_DIR}.xpr                          (project file)
#   - <parent of PROJ_DIR>/.Xil/               (Vivado global lock directory)
#
# После изменений в TCL-скриптах (например, в post_bd_dfx.tcl) или в RTL-файлах
# старый кэш IP становится несовместимым и приводит к:
#   - "Generation completed for the IP Integrator block ..." → обрыв без ошибки
#   - launch_runs synth_1 → Vivado crash
#   - BD parameter propagation не запускается ("already validated")
#   - DFX Aperture DRC не совпадает с новыми адресами
#
# Полное удаление ${PROJ_DIR} и .Xil/ перед create_project гарантирует
# чистую сборку. Если удаление не удалось (файлы заняты) — понятная инструкция.
# ============================================================================

set CLEANUP_DIRS [list \
    ${PROJ_DIR} \
    [file normalize "${PROJ_DIR}.cache"] \
    [file normalize "${PROJ_DIR}.gen"] \
    [file normalize "${PROJ_DIR}.hw"] \
    [file normalize "${PROJ_DIR}.ip_user_files"] \
    [file normalize "${PROJ_DIR}.sim"] \
    [file normalize "[file dirname ${PROJ_DIR}]/.Xil"] \
]

set cleanup_failed 0
foreach dir_to_clean ${CLEANUP_DIRS} {
    if {[file exists ${dir_to_clean}]} {
        puts "=== Cleaning: ${dir_to_clean} ==="
        if {[catch {file delete -force ${dir_to_clean}} err]} {
            puts "WARNING: Cannot delete ${dir_to_clean}: $err"
            set cleanup_failed 1
        }
    }
}

if {$cleanup_failed} {
    puts ""
    puts "============================================================"
    puts " CLEANUP FAILED — files locked by another process"
    puts "============================================================"
    puts " Some directories in ${PROJ_DIR} could not be deleted."
    puts " This usually means:"
    puts "   1. Vivado is still running (Task Manager → End all vivado.exe)"
    puts "   2. Windows Explorer has ${PROJ_DIR} open (close it)"
    puts "   3. Antivirus is scanning (wait or exclude ${PROJ_DIR})"
    puts "   4. Another process locked the files"
    puts ""
    puts " MANUAL FIX:"
    puts "   1. Close all Vivado: taskkill /f /im vivado.exe /im vivado.bat"
    puts "   2. rmdir /s /q ${PROJ_DIR}"
    puts "   3. Re-run: scripts\\build.bat"
    puts "============================================================"
    catch {close_project}
    exit 1
}

create_project -force ${PROJ_NAME} ${PROJ_DIR} -part ${PART}
set_property target_language Verilog [current_project]
set_property target_simulator XSim [current_project]

# ---------- 2a. Добавление HDL-файлов модулей DFX Partition ----------
puts "=== 2a. ADD DFX PARTITION HDL (up_axi + datamover_ctrl) ==="
# Файлы встроены в репозиторий: third_party/m2-artix7-accelerator-card/hdl/
# (см. third_party/m2-artix7-accelerator-card/README.md)
set HDL_DIR "${ROOT}/third_party/m2-artix7-accelerator-card/hdl"
add_files -norecurse \
    ${HDL_DIR}/common/up_axi.v \
    ${HDL_DIR}/common/datamover_ctrl.v \
    ${HDL_DIR}/datamover_mm2s_ctrl/axi_datamover_mm2s_ctrl.v \
    ${HDL_DIR}/datamover_s2mm_ctrl/axi_datamover_s2mm_ctrl.v

# Убеждаемся, что BD-контейнер dfx_partition может найти модули
set_property top ${TOP_NAME} [current_fileset]

# ---------- 2a. Создание BDC dfx_partition (источник для DFX BD) ----------
# Без этого шага block_design_top.tcl не сможет найти reference dfx_partition
# и создание BD упадёт с "can_resolve_reference == 0".
puts "=== 2a. CREATE DFX PARTITION BDC (dfx_block_designs/default.tcl) ==="
source ${ROOT}/dfx_block_designs/default.tcl
set dfx_bd_file [get_files -quiet dfx_partition.bd]
if {$dfx_bd_file eq ""} {
    puts "ERROR: dfx_partition.bd не создан из default.tcl"
    close_project
    exit 1
}
puts "=== dfx_partition.bd создан: $dfx_bd_file ==="
# dfx_partition.bd должен быть явно добавлен в проект как источник
# (BDC-reference для create_bd_cell -type container).
catch {add_files -norecurse -quiet ${dfx_bd_file}}

# ---------- 2b. Создание DFX BD (xdma_ddr3_dfx) ----------
puts "=== 2b. CREATE DFX BD (xdma_ddr3_dfx_bd.tcl) ==="
source ${ROOT}/scripts/xdma_ddr3_dfx_bd.tcl

# ---------- 2c. Постобработка DFX BD (TDOT/ICAP/XADC/клок) ----------
puts "=== 2c. POST-PROCESS DFX BD (post_bd_dfx.tcl) ==="
open_bd_design [get_files xdma_ddr3_dfx.bd]
source ${ROOT}/scripts/post_bd_dfx.tcl

# ---------- 2d. Настройка BAR0, адресов, DFX-апертур ----------
puts "=== 2d. CONFIGURE BD: BAR0=128MB, ADDRESSES ==="
open_bd_design [get_files xdma_ddr3_dfx.bd]

# BAR0 = 128 MB (покрывает всё AXI-Lite окно 0x40000000-0x47FFFFFF,
# включая XADC @ 0x46000000)
set_property -dict [list \
    CONFIG.pf0_bar0_scale {Megabytes} \
    CONFIG.pf0_bar0_size {128} \
] [get_bd_cells xdma_0]

# ---- Отчёт PCIe BAR / MSI-X (контроль PCIe-видимости до сборки) ----
# BAR0 — единственный хост-доступ к AXI-Lite. Таблица MSI-X размещается на
# 64-битном BAR2 (pf0_msix_cap_table_bir = BAR_3:2): проверяем, что BAR2
# включён, иначе хост не увидит таблицу MSI-X. Все чтения — в catch:
# изменение имён параметров в новых версиях IP не должно ломать сборку.
if {[catch {
    set xdma_cell [get_bd_cells xdma_0]
    puts "=== PCIe BAR REPORT (xdma_0) ==="
    foreach _bar {0 1 2 3 4 5} {
        set _sc ""; set _sz ""
        catch { set _sc [get_property CONFIG.pf0_bar${_bar}_scale $xdma_cell] }
        catch { set _sz [get_property CONFIG.pf0_bar${_bar}_size $xdma_cell] }
        if {${_sz} ne "" && ${_sz} ne "0"} {
            puts "    BAR${_bar}: scale=${_sc} size=${_sz}"
        }
    }
    set _msix ""; catch { set _msix [get_property CONFIG.pf0_msix_enabled $xdma_cell] }
    set _bir "";  catch { set _bir  [get_property CONFIG.pf0_msix_cap_table_bir $xdma_cell] }
    puts "    MSI-X: enabled=${_msix} table_bir=${_bir}"
    if {${_msix} eq "true" && [string first "3:2" ${_bir}] != -1} {
        set _b2 ""; catch { set _b2 [get_property CONFIG.pf0_bar2_size $xdma_cell] }
        if {${_b2} eq "" || ${_b2} eq "0"} {
            puts "    WARNING: MSI-X table на BAR2, но pf0_bar2_size не задан —"
            puts "             хост не увидит таблицу MSI-X (проверьте конфиг XDMA)."
        }
    }
    puts "=== PCIe BAR REPORT: END ==="
} err_bar]} {
    puts "    (BAR report skipped: $err_bar)"
}

# Адреса (уже назначены в xdma_ddr3_dfx_bd.tcl + post_bd_dfx.tcl, но перепроверяем)
# перебиваем адреса финально с canonical картой
set as_lite [get_bd_addr_spaces xdma_0/M_AXI_LITE]

# GPIO: 0x40000000 (4K) — уже есть от DFX BD
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_gpio_0_Reg}]
assign_bd_address -offset 0x40000000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force

# DFX Socket control: 0x40002000 — тоже есть
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_decouple_shutdown_ctrl_Reg}]
assign_bd_address -offset 0x40002000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs dfx_socket/decouple_shutdown_ctrl/S_AXI/Reg] -force

# TDOT: 0x40003000 (via post_bd_dfx)
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_TDOT_REGS_Reg}]
assign_bd_address -offset 0x40003000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs S_AXI_TDOT_REGS/Reg] -force

# ICAP: 0x40004000 (via post_bd_dfx)
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_ICAP_REGS_Reg}]
assign_bd_address -offset 0x40004000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs S_AXI_ICAP_REGS/Reg] -force

# XADC: 0x46000000 (via post_bd_dfx)
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_S_AXI_XADC_REGS_Reg}]
assign_bd_address -offset 0x46000000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs S_AXI_XADC_REGS/Reg] -force

# DFX Partition MM2S/S2MM control: 0x40010000 / 0x40018000 (4K на сегмент —
# остальное окно апертуры RP 64K свободно для дополнительных IP внутри RP,
# например GPIO в dfx_block_designs/test.tcl @ 0x40012000)
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_datamover_mm2s_c_0_reg0}]
assign_bd_address -offset 0x40010000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs dfx_partition/axi_datamover_mm2s_c_0/s_axi/reg0] -force

delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_datamover_s2mm_c_0_reg0}]
assign_bd_address -offset 0x40018000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs dfx_partition/axi_datamover_s2mm_c_0/s_axi/reg0] -force

# HWICAP: 0x40001000
delete_bd_objs -quiet [get_bd_addr_segs -quiet {xdma_0/M_AXI_LITE/SEG_axi_hwicap_0_Reg}]
assign_bd_address -offset 0x40001000 -range 0x1000 \
    -target_address_space $as_lite \
    [get_bd_addr_segs axi_hwicap_0/S_AXI_LITE/Reg] -force

validate_bd_design
save_bd_design

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
set pblock_xdc ${ROOT}/constraints/pblock.xdc
add_files -fileset constrs_1 ${pins_xdc}
add_files -fileset constrs_1 ${early_xdc}
add_files -fileset constrs_1 ${pblock_xdc}
set_property PROCESSING_ORDER EARLY  [get_files ${early_xdc}]
set_property PROCESSING_ORDER NORMAL [get_files ${pins_xdc}]
set_property PROCESSING_ORDER LATE   [get_files ${pblock_xdc}]
update_compile_order -fileset constrs_1

# Vivado 2025.2 DRC REQP-123 ложное срабатывание для clk200_clk_wiz
# (MMCM с CLKINSEL=VCC проверяет активность CLKIN1, но clk50 — внешний буферизованный клок)
set_property SEVERITY {Warning} [get_drc_checks REQP-123]

# ---------- 5. Regenerate wrapper ----------
puts "=== 5. REGENERATE WRAPPER ==="
make_wrapper -files [get_files xdma_ddr3_dfx.bd] -top -force
set_property top ${TOP_NAME} [current_fileset]
update_compile_order -fileset sources_1
update_compile_order -fileset constrs_1

# ---------- 6. Demote PCIe IP XDC ----------
puts "=== 6. DEMOTE PCIE IP XDC ==="
set pcie_ip_xdc [get_files -all -quiet *PCIE_X0Y0.xdc]
if {$pcie_ip_xdc ne ""} {
    set_property PROCESSING_ORDER NORMAL ${pcie_ip_xdc}
    puts "=== PCIE IP xdc set to NORMAL (pre-synth): ${pcie_ip_xdc} ==="
} else {
    puts "=== PCIE IP xdc not found yet (will retry after synth) ==="
}

if {${SKIP_SYNTH}} {
    puts "=== SKIP_SYNTH=1 — exiting before synth ==="
    save_project_as ${PROJ_DIR}/${PROJ_NAME}.xpr -force
    close_project
    exit 0
}

# ---------- 7. Synthesis ----------
puts "=== 7. SYNTHESIS ==="
reset_run synth_1 -quiet
reset_run impl_1 -quiet
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]

# AUDIT-02: create_clock mig_refclk на REFCLK pin MIG IODELAYCTRL
# выполняем в TCL.POST после synth (когда pin существует в netlist).
# До synth get_pins возвращает пустой список — см. ERROR_HISTORY.md BUG-026.
set_property STEPS.SYNTH_DESIGN.TCL.POST ${ROOT}/scripts/mig_refclk_post.tcl [get_runs synth_1]

launch_runs synth_1 -jobs ${JOBS}
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    puts "=== SYNTHESIS FAILED ==="
    close_project
    exit 1
}

# PCIe IP XDC demotion post-synth
set pcie_ip_xdc [get_files -all -quiet *PCIE_X0Y0.xdc]
if {$pcie_ip_xdc ne ""} {
    set_property PROCESSING_ORDER NORMAL ${pcie_ip_xdc}
    puts "=== PCIE IP xdc set to NORMAL (post-synth): ${pcie_ip_xdc} ==="
} else {
    puts "=== WARNING: PCIE IP xdc STILL not found after synth ==="
}

# ---------- 8. Implementation + Bitstream ----------
puts "=== 8. IMPLEMENTATION + BITSTREAM ==="
current_run [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.TCL.PRE ${ROOT}/scripts/suppress_warnings.tcl [get_runs impl_1]
# Генерировать .bin вместе с .bit и в дочерних конфигурациях RP (частичные
# битстримы понадобятся для горячей замены через ICAP — pytorch_layer/icap_load.py)
catch {set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]}
launch_runs impl_1 -to_step write_bitstream -jobs ${JOBS}
wait_on_run impl_1
set st2 [get_property STATUS [get_runs impl_1]]
puts "=== IMPL STATUS: $st2 ==="
if {[string first "complete" [string tolower $st2]] == -1} {
    puts "=== IMPLEMENTATION FAILED ==="
    close_project
    exit 1
}

# ---------- 9. Export artifacts ----------
puts "=== 9. EXPORT ARTIFACTS ==="
open_run impl_1

set ARTIFACTS_DIR "${ROOT}/build/artifacts_dfx"
file mkdir ${ARTIFACTS_DIR}

set bit_file "${ARTIFACTS_DIR}/${TOP_NAME}.bit"
set bin_file "${ARTIFACTS_DIR}/${TOP_NAME}.bin"
set mcs_file "${ARTIFACTS_DIR}/${TOP_NAME}.mcs"

write_bitstream -force -raw_bitfile -bin_file ${bit_file}
write_cfgmem -force -format mcs -size 128 -interface SPIx4 \
    -loadbit "up 0x0 ${bit_file}" ${mcs_file}

foreach rpt {utilization.txt timing_summary.rpt} {
    set src ""
    catch { set src [get_property DIRECTORY [get_runs impl_1]]/${rpt} }
    if {[file exists ${src}]} {
        file copy -force ${src} ${ARTIFACTS_DIR}/${rpt}
    }
}

# ---------- 9b. Экспорт PARTIAL битстримов (горячая замена RP) ----------
# В DFX-потоке Vivado создаёт дочерние имплементации для каждой конфигурации
# RP; их write_bitstream производит частичные битстримы (*partial*). Именно
# эти файлы загружаются через PCIe (icap_ctrl @ 0x40004000, icap_load.py /
# dfx_swap.py) — без JTAG, статическая область и PCIe-линк не сбрасываются.
puts "=== 9b. EXPORT PARTIAL BITSTREAMS ==="
set partial_files [glob -nocomplain \
    ${PROJ_DIR}.runs/*/*partial*.bit \
    ${PROJ_DIR}.runs/*/*partial*.bin]
if {[llength ${partial_files}] == 0} {
    puts " WARNING: частичные битстримы не найдены в ${PROJ_DIR}.runs/"
    puts " Дочерние конфигурации RP должны завершить write_bitstream;"
    puts " проверьте дерево запусков (impl_1 и дочерние runs)."
} else {
    foreach pfile ${partial_files} {
        file copy -force ${pfile} ${ARTIFACTS_DIR}/
        puts " PARTIAL: [file tail ${pfile}] -> ${ARTIFACTS_DIR}/"
    }
}

close_project

puts "============================================================"
puts " BUILD_DFX COMPLETE"
puts "============================================================"
puts " Bitstream : ${bit_file}"
puts " Binary    : ${bin_file}"
puts " MCS       : ${mcs_file}"
puts " Partials  : ${ARTIFACTS_DIR}/*partial*.bit|.bin (горячая замена RP)"
puts " Artifacts : ${ARTIFACTS_DIR}"
puts "============================================================"