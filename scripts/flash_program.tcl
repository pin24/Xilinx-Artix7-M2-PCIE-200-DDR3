# ============================================================================
# flash_program.tcl - program the on-board SPI flash (W25Q128JV) with a .bin/.mcs
# ----------------------------------------------------------------------------
# Usage:
#   vivado.bat -mode batch -source scripts/flash_program.tcl -tclargs <file.bin|file.mcs>
#
# Reproduces the proven sequence (see C:/build_dfx/vivado.log, 2026-09-09/10):
#   open_hw_manager -> connect_hw_server -> open_hw_target -> xc7a200t_0 ->
#   create_hw_cfgmem w25q128jvq-spi-x1_x2_x4 -> Program/Verify.
#
# NOTE: not executed end-to-end in the audit session (a full flash takes ~2 min
# and rewrites the board); the command sequence mirrors the reference log.
# ============================================================================
set FILE [lindex $argv 0]
if {${FILE} eq "" || ![file exists ${FILE}]} {
    puts "ERROR: pass an existing .bin/.mcs file: -tclargs <path>"
    exit 1
}
puts "=== FLASH PROGRAM: ${FILE} ==="

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set DEV [lindex [get_hw_devices xc7a200t_0] 0]
if {${DEV} eq ""} { puts "ERROR: xc7a200t_0 not found (JTAG target?)"; exit 1 }
current_hw_device ${DEV}
refresh_hw_device -update_hw_probes false ${DEV}

create_hw_cfgmem -hw_device ${DEV} [lindex [get_cfgmem_parts {w25q128jvq-spi-x1_x2_x4}] 0]
set CFG [get_property PROGRAM.HW_CFGMEM ${DEV}]
set_property PROGRAM.BLANK_CHECK    0 ${CFG}
set_property PROGRAM.ERASE          1 ${CFG}
set_property PROGRAM.CFG_PROGRAM    1 ${CFG}
set_property PROGRAM.VERIFY         1 ${CFG}
set_property PROGRAM.CHECKSUM       0 ${CFG}
set_property PROGRAM.ADDRESS_RANGE  {use_file} ${CFG}
set_property PROGRAM.PRM_FILE       {} ${CFG}
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} ${CFG}

set_property PROGRAM.FILES [list ${FILE}] ${CFG}
program_hw_cfgmem -hw_cfgmem ${CFG}

puts "=== FLASH PROGRAM: DONE (verify OK required above) ==="
close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
