# QSPI FLASH PIN MAP - W25Q128JV on XC7A200T-FBG484

Provided by user 2026-09-13 (from core-module schematic A7_M2_DDR_V1.2).
RESOLVED against Vivado xc7a200tfbg484-2 package data 2026-09-13.

## Flash function -> FPGA ball -> OFFICIAL IO name

| Flash signal   | Flash pin    | FPGA BALL | IO name (PIN_FUNC)          | Bank | Notes |
|----------------|--------------|-----------|-----------------------------|------|-------|
| QSPI CS        | CS#          | T19       | IO_L6P_T0_FCS_B_14          | 14   | dedicated FCS_B |
| QSPI CLK       | CLK          | **L12**   | **CCLK_0**                  | 0    | dedicated CCLK (NOT Y19!) |
| QSPI D0        | SI/DQ0       | P22       | IO_L1P_T0_D00_MOSI_14       | 14   | dedicated D00/MOSI |
| QSPI D1        | SO/DQ1/HOLD# | R22       | IO_L1N_T0_D01_DIN_14        | 14   | dedicated D01/DIN |
| QSPI D2        | WP#/DQ2      | P21       | IO_L2P_T0_D02_14            | 14   | dedicated D02 |
| QSPI D3        | DQ3          | R21       | IO_L2N_T0_D03_14            | 14   | dedicated D03 |

## CORRECTION to earlier note

Earlier draft said "QSPI CLK = Y19 (GCLK 50M?)". That is WRONG.

Vivado `get_package_pins Y19` -> `IO_L13N_T2_MRCC_14`, bank 14,
is_clk_capable=1, diff_pair=Y18.

- Y19 is the N side of the regular MRCC diff pair whose P side is Y18.
- Y18 is already used in constraints/xdma_ddr3_pins.xdc as `clk50[0]` (single-ended).
- The TRUE dedicated configuration clock on XC7A200T-FBG484 is ball **L12** = `CCLK_0` (bank 0).

Therefore the flash CLK net on the schematic must be CCLK -> L12. If the schematic
really routes the flash CLK to Y19, that is a bit-banged QSPI on regular IO, NOT the
boot flash path, and STARTUPE2/USRCCLKO would not drive it.

## Access method after configuration

These are dedicated 7-series CONFIGURATION pins. After configuration they are reachable
ONLY via STARTUPE2 (single site on XC7A200T, already owned by axi_hwicap with
C_INCLUDE_STARTUP=1). Mapping:

- STARTUPE2.USRCCLKO  -> CCLK  (L12)
- STARTUPE2.USRDON    -> D00/MOSI (P22)
- STARTUPE2.USRDIN    -> D01/DIN  (R22)
- STARTUPE2.USRCSN    -> FCS_B    (T19)
- D02/D03 (P21/R21) are quad-mode extras, not exposed by STARTUPE2 -> quad-SPI read
  of the flash requires the 4-bit path which STARTUPE2 does not provide.

## Reproduce

```tcl
link_design -part xc7a200tfbg484-2 -quiet
set p [get_package_pins -quiet Y19]
get_property PIN_FUNC $p   ;# -> IO_L13N_T2_MRCC_14
get_property BANK     $p   ;# -> 14
```

NOTE: the ball string is the pin NAME. The property `PIN_NUMBER` does NOT exist —
filtering on it silently returns empty (this caused the first two failed lookups).
