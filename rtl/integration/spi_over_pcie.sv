// ============================================================================
// spi_over_pcie.sv - SPI master over AXI-Lite (SPI-over-PCIe, R-14) - STUB
// ============================================================================
// REWRITTEN 2026-10-11: replaced with a non-blocking STUB.
//
// Why: the real spi_over_pcie instantiated STARTUPE2 and drove the dedicated
// QSPI flash pins (FCS_B=T19, D00=P22, D01=R22, D02=P21, D03=R21) as user I/O,
// so even a configured FPGA held the flash pins -> Vivado lab tool reported
//     Labtools 27-3347 "Failure to set flash parameters"
// at program_hw_cfgmem (JTAG flash). The module was removed from all active
// bitstreams (FLAT and DFX) on 2026-10-05 (top no longer instantiates it, and
// the S_AXI_SPI_REGS BD port was dropped). This file is retained ONLY as a
// compatibility stub.
//
// Stub behavior:
//   * Answers all AXI-Lite access normally (no hang) so any host tool that
//     pokes 0x40025000 keeps working.
//   * STATUS[0x04] reads DONE=1 (BUSY=0) so a host polling "START then check
//     BUSY/DONE" completes immediately and does not wait forever.
//   * Does NOT instantiate STARTUPE2 and does NOT drive the QSPI flash pins:
//     spi_cclk held low, qspi_cs_n deasserted, qspi_d0..d3 = high-impedance.
//     => flash pins are free for JTAG program_hw_cfgmem (no 27-3347).
//   * No real SPI activity is performed.
//
// Refs: UG470 (7 Series Configuration), UG953 (7 Series Primitives).
// ============================================================================
`timescale 1ns / 1ps

module spi_over_pcie #(
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int C_S_AXI_ADDR_WIDTH = 8,
    parameter int CLK_DIV = 16               // kept for interface compatibility (unused)
)(
    input  logic                                  S_AXI_ACLK,
    input  logic                                  S_AXI_ARESETN,

    input  logic [C_S_AXI_ADDR_WIDTH-1:0]         S_AXI_AWADDR,
    input  logic                                  S_AXI_AWVALID,
    output logic                                  S_AXI_AWREADY,
    input  logic [C_S_AXI_DATA_WIDTH-1:0]         S_AXI_WDATA,
    input  logic [C_S_AXI_DATA_WIDTH/8-1:0]       S_AXI_WSTRB,
    input  logic                                  S_AXI_WVALID,
    output logic                                  S_AXI_WREADY,
    output logic [1:0]                            S_AXI_BRESP,
    output logic                                  S_AXI_BVALID,
    input  logic                                  S_AXI_BREADY,

    input  logic [C_S_AXI_ADDR_WIDTH-1:0]         S_AXI_ARADDR,
    input  logic                                  S_AXI_ARVALID,
    output logic                                  S_AXI_ARREADY,
    output logic [C_S_AXI_DATA_WIDTH-1:0]         S_AXI_RDATA,
    output logic [1:0]                            S_AXI_RRESP,
    output logic                                  S_AXI_RVALID,
    input  logic                                  S_AXI_RREADY,

    // SPI / QSPI flash pins -- NOT driven by the stub (high-impedance),
    // so the on-board flash is not blocked from JTAG programming.
    output logic                                  spi_cclk,
    output logic                                  qspi_cs_n,
    inout  wire                                   qspi_d0,
    inout  wire                                   qspi_d1,
    inout  wire                                   qspi_d2,
    inout  wire                                   qspi_d3
);

    localparam int ADDR_LSB = 2;

    // ------------------------------------------------------------------
    // AXI-Lite write channel (accept-and-ack, 2-phase)
    // ------------------------------------------------------------------
    logic                 awready, wready, bvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] awaddr_q;
    logic                 start_q;          // CTRL[0x00] bit0 (stub: latched, ignored)

    localparam W_IDLE   = 1'b0;
    localparam W_COMMIT = 1'b1;
    logic wstate;

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            wstate  <= W_IDLE;
            bvalid  <= 1'b0;
            awaddr_q<= 0;
            start_q <= 1'b0;
        end else begin
            case (wstate)
                W_IDLE: begin
                    bvalid <= 1'b0;
                    if (S_AXI_AWVALID && S_AXI_WVALID) begin
                        awaddr_q <= S_AXI_AWADDR;
                        if (S_AXI_AWADDR[ADDR_LSB+:2] == 2'd0)
                            start_q <= S_AXI_WDATA[0];   // CTRL.GO latch (no effect)
                        wstate   <= W_COMMIT;
                    end
                end
                W_COMMIT: begin
                    bvalid <= 1'b1;
                    if (S_AXI_BREADY) begin
                        bvalid <= 1'b0;
                        wstate <= W_IDLE;
                    end
                end
                default: wstate <= W_IDLE;
            endcase
        end
    end

    assign S_AXI_AWREADY = (wstate == W_IDLE) && S_AXI_AWVALID;
    assign S_AXI_WREADY  = (wstate == W_IDLE) && S_AXI_WVALID;
    assign S_AXI_BRESP   = 2'b00;
    assign S_AXI_BVALID  = bvalid;

    // ------------------------------------------------------------------
    // AXI-Lite read channel (status stub -> DONE=1, others 0)
    // ------------------------------------------------------------------
    logic                 arready, rvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] araddr_q;

    localparam R_IDLE   = 1'b0;
    localparam R_RVALID = 1'b1;
    logic rstate;

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            rstate  <= R_IDLE;
            rvalid  <= 1'b0;
            araddr_q<= 0;
        end else begin
            case (rstate)
                R_IDLE: begin
                    rvalid <= 1'b0;
                    if (S_AXI_ARVALID) begin
                        araddr_q <= S_AXI_ARADDR;
                        rstate   <= R_RVALID;
                    end
                end
                R_RVALID: begin
                    rvalid <= 1'b1;
                    if (S_AXI_RREADY) begin
                        rvalid  <= 1'b0;
                        rstate  <= R_IDLE;
                    end
                end
                default: rstate <= R_IDLE;
            endcase
        end
    end

    logic [C_S_AXI_DATA_WIDTH-1:0] rdata;
    always_comb begin
        // [0x04] STATUS: bit0 BUSY=0, bit1 DONE=1 -> host "START->poll" completes.
        if (araddr_q[ADDR_LSB+:2] == 2'd1)
            rdata = 32'h00000002;                                  // STATUS: DONE=1 (bit1), BUSY=0
        else
            rdata = 32'h00000000;                                  // CTRL/CMD/ADDR/LEN/DATA/RX -> 0
    end
    assign S_AXI_ARREADY = (rstate == R_IDLE) && S_AXI_ARVALID;
    assign S_AXI_RRESP   = 2'b00;
    assign S_AXI_RDATA   = rdata;
    assign S_AXI_RVALID  = rvalid;

    // ------------------------------------------------------------------
    // SPI / QSPI pins: NOT driven (flash stays free for JTAG programming)
    // ------------------------------------------------------------------
    assign spi_cclk  = 1'b0;
    assign qspi_cs_n = 1'b1;
    assign qspi_d0   = 1'bz;
    assign qspi_d1   = 1'bz;
    assign qspi_d2   = 1'bz;
    assign qspi_d3   = 1'bz;

endmodule