# ============================================================================
# flash_program.tcl - program the on-board SPI flash (W25Q128JV) with a .bin/.mcs
# ----------------------------------------------------------------------------
# Usage:
#   vivado.bat -mode batch -source scripts/flash_program.tcl -tclargs <file.bin|file.mcs>
#
# Reproduces the flash sequence (open_hw_manager -> connect_hw_server ->
# open_hw_target -> xc7a200t_0 -> create_hw_cfgmem w25q128jvq-spi-x1_x2_x4 ->
# Program/Verify). Prefer a full .mcs (build/artifacts_dfx/*.mcs, SPIX4) over
# the raw .bin (use_file also valid; raw size must fit flash).
#
# ⚠️ HW NOTE (verified 2026-09-27): Labtools 27-3347 "Failure to set flash
# parameters" on this board is CAUSED BY THE BITSTREAM, not this script: the
# R-14 spi_over_pcie design assigns the QSPI flash pins (FCS_B=T19, D00=P22,
# D01=R22, D02=P21, D03=R21) as USER fabric IO (xdma_ddr3_pins.xdc:101-105).
# While such a bitstream is loaded, the config controller cannot reach the
# flash -> cfgmem JEDEC/params read fails -> 27-3347. To program the flash,
# load a bitstream that does NOT claim the flash pins (or leave the cell
# unconfigured / use a .bit without spi_over_pcie). Same root cause affects
# any attempt while the SPI-over-PCIe design is active.
#
# NOTE: executed 2026-09-27 against real board (JTAG). Script + part name +
# property set are now correct; the remaining 27-3347 is caused by the loaded
# bitstream claiming the flash pins (see ⚠️ HW NOTE above), not by this file.
# FIX 2026-09-27: part matched resiliently (jvq is the valid name); dropped
# set_property calls on non-existent PROGRAM.* fields (CHECKSUM, ADDRESS_RANGE,
# PRM_FILE, UNUSED_PIN_TERMINATION) that themselves rejected -> 27-3347.
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

# Select Winbond 128 Mbit SPI (x1_x2_x4) cfgmem part RESILIENTLY.
# CORRECTION 2026-09-27 (pull #2): the canonical part name in this Vivado
# 2025.2 database is "w25q128jvq-spi-x1_x2_x4" (with 'q'!). The earlier fix
# dropped the 'q' -> "w25q128jv-..." which is NOT in get_cfgmem_parts ->
# Labtools 44-349 "Unrecognized config mem part". So primary name keeps the
# 'q'; fallbacks cover jvm and the generic w25q128* glob for other revisions.
set CFGPART [lindex [get_cfgmem_parts {w25q128jvq-spi-x1_x2_x4}] 0]
if {${CFGPART} eq ""} {
    set CFGPART [lindex [get_cfgmem_parts {w25q128jvm-spi-x1_x2_x4}] 0]
}
if {${CFGPART} eq ""} {
    set CFGPART [lindex [get_cfgmem_parts {w25q128*spi-x1_x2_x4}] 0]
}
if {${CFGPART} eq ""} {
    puts "ERROR: no Winbond 128M SPI[x1_x2_x4] cfgmem part in this Vivado."
    puts "Available (w25q128*): [join [get_cfgmem_parts {w25q128*}] {, }]"
    exit 1
}
create_hw_cfgmem -hw_device ${DEV} ${CFGPART}
set CFG [get_property PROGRAM.HW_CFGMEM ${DEV}]
# NOTE: only set properties that ACTUALLY EXIST on this cfgmem part. For
# w25q128jvq-spi-x1_x2_x4 in Vivado 2025.2 the valid PROGRAM.* are:
# BLANK_CHECK, CFG_PROGRAM, ERASE, FILES, MULTI_IMAGE_*, SKIP_QE_BIT_ERASE,
# VERIFY. The legacy lines (CHECKSUM, ADDRESS_RANGE, PRM_FILE,
# UNUSED_PIN_TERMINATION) are NOT part of the property set -> set_property on
# them is rejected -> program_hw_cfgmem aborts with Labtools 27-3347. So we
# do NOT set them. For a full .mcs (self-addressing) no ADDRESS_RANGE is
# required; for a raw .bin Vivado uses use_file semantics by default.
set_property PROGRAM.ERASE          1 ${CFG}
set_property PROGRAM.CFG_PROGRAM    1 ${CFG}
set_property PROGRAM.VERIFY         1 ${CFG}

set_property PROGRAM.FILES [list ${FILE}] ${CFG}
program_hw_cfgmem -hw_cfgmem ${CFG}

puts "=== FLASH PROGRAM: DONE (verify OK required above) ==="
close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
