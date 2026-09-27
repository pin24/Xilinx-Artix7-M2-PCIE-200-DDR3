# DDR3 PIN MAP — XC7A200T-FBG484 (M.2 Artix7 200T + DDR3)

Source: MIG 4.2 generated XDC
`C:\build_dfx\m2_artix7_xdma_ddr3_dfx.gen\sources_1\bd\xdma_ddr3_dfx\ip\xdma_ddr3_dfx_mig_7series_0_0\xdma_ddr3_dfx_mig_7series_0_0\user_design\constraints\xdma_ddr3_dfx_mig_7series_0_0.xdc`
Memory: MT41J128M16XX-125, Data Width 16, 400 MHz (2500 ps)
Extracted 2026-09-13.

## DQ / DM / DQS
| Port | PACKAGE_PIN |
|---|---|
| ddr3_dq[0] | V4 |
| ddr3_dq[1] | AB2 |
| ddr3_dq[2] | AB3 |
| ddr3_dq[3] | AA1 |
| ddr3_dq[4] | AA5 |
| ddr3_dq[5] | Y4 |
| ddr3_dq[6] | AB5 |
| ddr3_dq[7] | AA4 |
| ddr3_dq[8] | W2 |
| ddr3_dq[9] | U2 |
| ddr3_dq[10] | U3 |
| ddr3_dq[11] | T1 |
| ddr3_dq[12] | Y1 |
| ddr3_dq[13] | U1 |
| ddr3_dq[14] | Y2 |
| ddr3_dq[15] | W1 |
| ddr3_dm[0] | AB1 |
| ddr3_dm[1] | V2 |
| ddr3_dqs_p[0] | Y3 |
| ddr3_dqs_n[0] | AA3 |
| ddr3_dqs_p[1] | R3 |
| ddr3_dqs_n[1] | R2 |

## Address
| Port | PACKAGE_PIN |
|---|---|
| ddr3_addr[0] | U6 |
| ddr3_addr[1] | T6 |
| ddr3_addr[2] | Y8 |
| ddr3_addr[3] | W6 |
| ddr3_addr[4] | AB7 |
| ddr3_addr[5] | V7 |
| ddr3_addr[6] | Y7 |
| ddr3_addr[7] | W9 |
| ddr3_addr[8] | AB8 |
| ddr3_addr[9] | AA8 |
| ddr3_addr[10] | Y6 |
| ddr3_addr[11] | U7 |
| ddr3_addr[12] | W7 |
| ddr3_addr[13] | Y9 |

## Bank / Command / Clocks
| Port | PACKAGE_PIN |
|---|---|
| ddr3_ba[0] | V5 |
| ddr3_ba[1] | AA6 |
| ddr3_ba[2] | U5 |
| ddr3_ras_n | R4 |
| ddr3_cas_n | R6 |
| ddr3_we_n | W5 |
| ddr3_reset_n | T3 |
| ddr3_cke[0] | AB6 |
| ddr3_odt[0] | T4 |
| ddr3_cs_n[0] | T5 |
| ddr3_ck_p[0] | V9 |
| ddr3_ck_n[0] | V8 |

## Board pins (constraints/xdma_ddr3_pins.xdc)
| Port | PACKAGE_PIN |
|---|---|
| clk50[0] | Y18 |
| reset_rtl_0 | K22 |
| gpio_rtl_0_tri_o[0] | AB20 |
| gpio_rtl_0_tri_o[1] | AA20 |
| gpio_rtl_0_tri_o[2] | AB21 |
| diff_clock_rtl_0_clk_p[0] | F10 |
| diff_clock_rtl_0_clk_n[0] | E10 |
| pcie rxn/rxp/txn/txp[0] | A8/B8/A4/B4 |
| pcie rxn/rxp/txn/txp[1] | C11/D11/C5/D5 |
| pcie rxn/rxp/txn/txp[2] | A10/B10/A6/B6 |
| pcie rxn/rxp/txn/txp[3] | C9/D9/C7/D7 |