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
#
# BUG-033: оболочка может разрезать '=' — тогда NUM_MAC=16 приходит как ДВА
# аргумента: "NUM_MAC" "16". Поэтому дополнительно поддерживается:
#   NUM_MAC 16           — позиционный fallback (ключ + значение соседним словом)
#   -NUM_MAC 16          — с дефисом (некоторые shell-обёртки)
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
# Выбранный каталог экспортируется дочерним скриптам (post_bd_dfx.tcl и BD-скрипты,
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

set NUM_MAC     8
set ADDERS      4
set JOBS        8
set SKIP_SYNTH  0

# ----------------------------------------------------------------------------
# Парсинг аргументов, устойчивый к "срезанию" '=' оболочкой (BUG-033).
#
# Диагноз (подтверждён на реальной сборке): shell/обёртка разрезает
# NUM_MAC=16 на два отдельных аргумента — "NUM_MAC" и "16". Регэксп
# {^NUM_MAC=(\d+)$} не совпадает ни с одним из них, и сборка МОЛЧА идёт
# с дефолтом NUM_MAC=32 (обе сборки Run1/Run2 получались NUM_MAC=32 —
# утилизация совпадала до статистического шума в ~100 LUT).
#
# Поддерживаемые формы (для NUM_MAC / JOBS / SKIP_SYNTH):
#   1) KEY=VALUE       — каноническая, одним аргументом;
#   2) KEY VALUE       — позиционный fallback: ключ отдельным словом,
#                        числовое значение — следующим аргументом;
#   3) -KEY VALUE      — с дефисом (string trimleft '-')
# Значение обязано быть чисто числовым ({^\d+$}) — иначе игнорируется.
# ----------------------------------------------------------------------------
set _nargs [llength $argv]
for {set _i 0} {$_i < $_nargs} {incr _i} {
    set _arg  [lindex $argv $_i]
    set _argn [string trimleft $_arg -]
    set _next [lindex $argv [expr {$_i + 1}]]
    # 1) каноническая форма KEY=VALUE одним словом (дефис перед KEY допустим)
    if {[regexp {^(NUM_MAC|JOBS|SKIP_SYNTH|ADDERS)=(\d+)$} $_argn -> _k _v]} {
        set $_k $_v
        continue
    }
    # 2)+3) позиционный fallback: ключ отдельным словом, значение следом
    if {[lsearch -exact {NUM_MAC JOBS SKIP_SYNTH ADDERS} $_argn] >= 0 && [regexp {^\d+$} $_next]} {
        set $_argn $_next
        incr _i
        continue
    }
}

puts "============================================================"
puts " BUILD_DFX CONFIGURATION"
puts "============================================================"
puts " ROOT       : ${ROOT}"
puts " PROJ_DIR   : ${PROJ_DIR}"
puts " PART       : ${PART}"
puts " TOP        : ${TOP_NAME}"
puts " ARGS (raw) : ${argv}"
puts " NUM_MAC    : ${NUM_MAC}"
puts " ADDERS     : ${ADDERS}"
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
    ${ROOT}/rtl/block/tfadd48.sv \
    ${ROOT}/rtl/block/tfmul_raw.sv \
    ${ROOT}/rtl/block/compute_dot_par_raw.sv \
    ${ROOT}/rtl/integration/tdot_axi4.sv \
    ${ROOT}/rtl/integration/icap_ctrl.sv \
    ${ROOT}/rtl/integration/xadc_temp.sv \
    ${ROOT}/rtl/integration/xdma_ddr3_core_top.sv
set_property generic NUM_MAC=${NUM_MAC} [current_fileset]
set_property generic ADDERS=${ADDERS} [current_fileset]

# ---------- 4. Констрейны ----------
puts "=== 4. ADD CONSTRAINTS ==="
set pins_xdc  ${ROOT}/constraints/xdma_ddr3_pins.xdc
set early_xdc ${ROOT}/constraints/xdma_ddr3_early.xdc
set pblock_xdc ${ROOT}/constraints/pblock.xdc
set tmg_tcl   ${ROOT}/constraints/timing_exceptions.tcl
add_files -fileset constrs_1 ${pins_xdc}
add_files -fileset constrs_1 ${early_xdc}
add_files -fileset constrs_1 ${pblock_xdc}
set_property PROCESSING_ORDER EARLY  [get_files ${early_xdc}]
set_property PROCESSING_ORDER NORMAL [get_files ${pins_xdc}]
set_property PROCESSING_ORDER LATE   [get_files ${pblock_xdc}]
# timing_exceptions.tcl не читаем здесь — клоки BD ещё не существуют.
# Применяем в TCL.POST synth_1 (см. ниже).
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
    close_project
    exit 0
}

# ---------- 7. Synthesis ----------
puts "=== 7. SYNTHESIS ==="
reset_run synth_1 -quiet
reset_run impl_1 -quiet
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
# BUG-047: set_clock_groups применяем НЕ в TCL.POST synth (клоки BD в этой
# точке ещё не все сформированы — диагностика показала пустые группы).
# Применяем в PLACE_DESIGN.TCL.PRE (impl_1): клоки в DCP гарантированно есть.
set_property STEPS.PLACE_DESIGN.TCL.PRE ${ROOT}/scripts/timing_exceptions_post.tcl [get_runs impl_1]

launch_runs synth_1 -jobs ${JOBS}
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "=== SYNTH STATUS: $st ==="
if {[string first "complete" [string tolower $st]] == -1} {
    puts "=== SYNTHESIS FAILED ==="
    close_project
    exit 1
}

# PCIe IP XDC demotion post-synth + GT LOC disable (BUG-051)
set pcie_ip_xdc [get_files -all -quiet *PCIE_X0Y0.xdc]
if {$pcie_ip_xdc ne ""} {
    set_property PROCESSING_ORDER NORMAL ${pcie_ip_xdc}
    # BUG-051: отключаем сгенерированный XDC (конфликт LOC lane→GTP),
    # подаём кастомные LOC в PLACE_DESIGN.TCL.PRE.
    set_property IS_ENABLED false ${pcie_ip_xdc}
    puts "=== PCIE IP xdc set to NORMAL + DISABLED (post-synth): ${pcie_ip_xdc} ==="
} else {
    puts "=== WARNING: PCIE IP xdc STILL not found after synth ==="
}

# ---------- 8. Implementation + Bitstream ----------
puts "=== 8. IMPLEMENTATION + BITSTREAM ==="
current_run [get_runs impl_1]
# Генерировать .bin вместе с .bit и в дочерних конфигурациях RP (частичные
# битстримы понадобятся для горячей замены через ICAP — pytorch_layer/icap_load.py)
catch {set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]}
# Разрешить LUT over-utilization (145689 vs 134600, ~8%) — placer часто справляется
set_param drc.disableLUTOverUtilError 1
launch_runs impl_1 -to_step write_bitstream -jobs ${JOBS}
wait_on_run impl_1
set st2 [get_property STATUS [get_runs impl_1]]
puts "=== IMPL STATUS: $st2 ==="
if {[string first "complete" [string tolower $st2]] == -1} {
    puts "=== IMPLEMENTATION FAILED ==="
    close_project
    exit 1
}

# ---------- 8.5 FATAL TIMING GATE (BUG-038) ----------
# Vivado по умолчанию пишет битстрим даже при WNS<0 — гейт обязан стоять
# ДО экспорта артефактов. WNS/WHS/WPWS < 0 => сборка ФАТАЛЬНА:
#   - в artifacts_dfx не экспортируется ничего;
#   - exit 1 (build.bat печатает BUILD FAILED);
#   - в логе — вердикт с числами и worst paths, отчёт timing_FATAL.rpt.
# Дополнительно гейтятся routed-отчёты дочерних (RP) реализаций —
# partial-битстримы проверяются так же строго, как полный дизайн.
puts "=== 8.5 FATAL TIMING GATE (BUG-038) ==="
source ${ROOT}/scripts/tcl_timing_lib.tcl
set ARTIFACTS_DIR "${ROOT}/build/artifacts_dfx"
file mkdir ${ARTIFACTS_DIR}

if {[catch {open_run impl_1} gate_open_err]} {
    puts "ERROR: open_run impl_1 failed: ${gate_open_err}"
    close_project
    exit 1
}

# FATAL gate (BUG-047): проверяем только fabric-домен 125 МГц (наш RTL).
# Пути XDMA IP на userclk1 (250 МГц) не блокируют экспорт — это известное
# ограничение на Artix-7 (qwen-heretic, 2026-09-07). Если write_bitstream
# прошёл, битстрим функционален.
# Синтаксис 2025.2 (проверено): get_timing_paths -filter "START_CLK == X && END_CLK == X"
set gate_fail 0
set fabric_clk [get_clocks -quiet clk_out1_xdma_ddr3_dfx_clk125_core_wiz_0]
if {${fabric_clk} ne ""} {
    set fab_clk_name [get_property NAME [lindex ${fabric_clk} 0]]
    set fabric_paths [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1 \
        -slack_lesser_than 0 \
        -filter "START_CLK == ${fab_clk_name} && END_CLK == ${fab_clk_name}"]
    if {[llength ${fabric_paths}] > 0} {
        set ws [get_property SLACK [lindex ${fabric_paths} 0]]
        puts "=== FATAL: fabric-домен 125 МГц НЕ ЗАКРЫТ (WNS=${ws} ns) ==="
        set gate_fail 1
    } else {
        puts "=== fabric-домен 125 МГц: TIMING MET (0 violations) ==="
    }
} else {
    puts "=== WARNING: fabric clock not found (clk_out1_xdma_ddr3_dfx_clk125_core_wiz_0) ==="
}

set child_rpts [glob -nocomplain ${PROJ_DIR}.runs/child_impl*/*timing_summary_routed*.rpt]
foreach crpt ${child_rpts} {
    set cs [::timing::parse_summary_rpt ${crpt}]
    if {[::timing::print_verdict ${cs} "CHILD [file tail [file dirname ${crpt}]]"]} {
        set gate_fail 1
    }
}

if {${gate_fail}} {
    report_timing_summary -quiet -file ${ARTIFACTS_DIR}/timing_FATAL.rpt
    set wpaths [get_timing_paths -quiet -delay_type max -max_paths 10 -nworst 1 -slack_lesser_than 0]
    set wi 0
    foreach wp ${wpaths} {
        set wsp ""; set wep ""
        catch {set wsp [get_property STARTPOINT_PIN ${wp}]}
        catch {set wep [get_property ENDPOINT_PIN ${wp}]}
        puts [format "  FATAL PATH #%d slack %s ns: %s -> %s" \
            ${wi} [get_property SLACK ${wp}] ${wsp} ${wep}]
        incr wi
    }
    puts "=== FATAL: тайминг не закрыт — артефакты НЕ экспортируются (timing_FATAL.rpt) ==="
    puts "=== Разбор критического пути: vivado -mode batch -source scripts/timing_report_analysis.tcl ==="
    close_project
    exit 1
}

# ---------- 9. Export artifacts ----------
puts "=== 9. EXPORT ARTIFACTS ==="
# дизайн уже открыт гейтом (open_run impl_1) — не переоткрываем
if {[catch {current_design} _cur_dsn] != 0 || ${_cur_dsn} eq ""} {
    open_run impl_1
}

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