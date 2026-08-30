// ============================================================================
// xdma_ddr3_core_top.sv — Top-level: BD wrapper (XDMA + MIG + tdot_axi4)
// ============================================================================
`timescale 1ns / 1ps
module xdma_ddr3_core_top #(
    parameter int NUM_MAC = 32
)(
    inout  [15:0] DDR3_0_dq,
    inout  [1:0]  DDR3_0_dqs_n,
    inout  [1:0]  DDR3_0_dqs_p,
    output [13:0] DDR3_0_addr,
    output [2:0]  DDR3_0_ba,
    output        DDR3_0_cas_n,
    output [0:0]  DDR3_0_ck_n,
    output [0:0]  DDR3_0_ck_p,
    output [0:0]  DDR3_0_cke,
    output [0:0]  DDR3_0_cs_n,
    output [1:0]  DDR3_0_dm,
    output [0:0]  DDR3_0_odt,
    output        DDR3_0_ras_n,
    output        DDR3_0_reset_n,
    output        DDR3_0_we_n,
    input  [0:0]  diff_clock_rtl_0_clk_n,
    input  [0:0]  diff_clock_rtl_0_clk_p,
    input  [3:0]  pcie_7x_mgt_rtl_0_rxn,
    input  [3:0]  pcie_7x_mgt_rtl_0_rxp,
    output [3:0]  pcie_7x_mgt_rtl_0_txn,
    output [3:0]  pcie_7x_mgt_rtl_0_txp,
    input         reset_rtl_0
);

    // BD wrapper содержит XDMA + MIG + tdot_axi4
    // Все соединения — внутри BD
    xdma_ddr3_wrapper u_bd (
        .DDR3_0_addr(DDR3_0_addr),
        .DDR3_0_ba(DDR3_0_ba),
        .DDR3_0_cas_n(DDR3_0_cas_n),
        .DDR3_0_ck_n(DDR3_0_ck_n),
        .DDR3_0_ck_p(DDR3_0_ck_p),
        .DDR3_0_cke(DDR3_0_cke),
        .DDR3_0_cs_n(DDR3_0_cs_n),
        .DDR3_0_dm(DDR3_0_dm),
        .DDR3_0_dq(DDR3_0_dq),
        .DDR3_0_dqs_n(DDR3_0_dqs_n),
        .DDR3_0_dqs_p(DDR3_0_dqs_p),
        .DDR3_0_odt(DDR3_0_odt),
        .DDR3_0_ras_n(DDR3_0_ras_n),
        .DDR3_0_reset_n(DDR3_0_reset_n),
        .DDR3_0_we_n(DDR3_0_we_n),
        .diff_clock_rtl_0_clk_n(diff_clock_rtl_0_clk_n),
        .diff_clock_rtl_0_clk_p(diff_clock_rtl_0_clk_p),
        .pcie_7x_mgt_rtl_0_rxn(pcie_7x_mgt_rtl_0_rxn),
        .pcie_7x_mgt_rtl_0_rxp(pcie_7x_mgt_rtl_0_rxp),
        .pcie_7x_mgt_rtl_0_txn(pcie_7x_mgt_rtl_0_txn),
        .pcie_7x_mgt_rtl_0_txp(pcie_7x_mgt_rtl_0_txp),
        .reset_rtl_0(reset_rtl_0)
    );

endmodule