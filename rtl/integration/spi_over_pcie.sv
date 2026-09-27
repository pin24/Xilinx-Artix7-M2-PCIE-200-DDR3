// ============================================================================
// spi_over_pcie.sv - SPI master over AXI-Lite (SPI-over-PCIe, R-14)
// ============================================================================
// Purpose: allow host to write a new bitstream into the on-board SPI flash
// (W25Q128JV) via the ICAPE2/STARTUPE2 path, WITHOUT needing JTAG.
//
// Register map (32-bit, byte address, decode [4:2], 32-byte space):
//   [0x00] CTRL   bit0 START (self-clear), bit1 ABORT
//                 bit2 WREN (send 0x06 first), bit3 RDID (send 0x9F first)
//   [0x04] STATUS bit0 BUSY, bit1 DONE, bit2 ERROR, bit3 WIP_FLASH
//   [0x08] CMD    SPI command byte (0x03 read, 0x02 page program,
//                 0x20 sector erase, 0x06 WREN, 0x05 RDSR, 0xC7 chip erase)
//   [0x0C] ADDR   24-bit flash address
//   [0x10] LEN    transfer length in bytes (for DATA phase)
//   [0x14] DATA   write-only, tx byte FIFO (byte in bits[7:0])
//   [0x18] RX     read-only, last received byte in bits[7:0]
//
// Protocol (host side):
//   1. Write CMD (e.g. 0x06 WREN, 0x20 sector-erase, 0x02 page-program, 0x03 read)
//   2. Write ADDR (for commands that need it)
//   3. Write LEN (number of data bytes)
//   4. For each byte to send: write DATA
//   5. Write CTRL.START=1
//   6. Poll STATUS.BUSY until 0, check ERROR
//   7. Read RX for each received byte (drained one per DATA write or polled)
//
// STARTUPE2: after FPGA configuration, the dedicated SPI pins become user I/O
// via STARTUPE2 (USRCCLKO=CCLK, USRDON=MOSI, USRDIN=MISO, USRCSN=CS_b).
// Only ONE STARTUPE2 instance per design (already not used elsewhere).
//
// Refs: UG470 (7 Series Configuration), UG953 (7 Series Primitives).
// ============================================================================
`timescale 1ns / 1ps

module spi_over_pcie #(
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int C_S_AXI_ADDR_WIDTH = 8,
    parameter int CLK_DIV = 16               // SPI clk = S_AXI_ACLK / (2*CLK_DIV)
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
    output logic                                  spi_cclk,
    output logic                                  qspi_cs_n,
    inout  wire                                   qspi_d0,
    inout  wire                                   qspi_d1,
    inout  wire                                   qspi_d2,
    inout  wire                                   qspi_d3
);

    localparam int ADDR_LSB = 2;

    // ==================== Registers (fast domain) ==========================
    logic        ctrl_start_q, ctrl_abort_q;
    logic        cmd_wren_q, cmd_rdid_q;
    logic [7:0]  cmd_byte_q;
    logic [23:0] addr_q;
    logic [31:0] len_q;
    logic [7:0]  tx_byte_q;
    logic        tx_byte_valid_q;
    logic [7:0]  rx_byte_q;
    logic        status_busy_q, status_done_q, status_error_q;
    logic        status_wip_q;

    // ==================== AXI-Lite write channel ==========================
    logic awready, wready, bvalid;
    logic aw_latched, w_latched;
    logic [C_S_AXI_ADDR_WIDTH-1:0] awaddr_q;
    logic [C_S_AXI_DATA_WIDTH-1:0] wdata_q;

    wire aw_hs = S_AXI_AWVALID && awready;
    wire w_hs  = S_AXI_WVALID  && wready;
    wire wr_commit = aw_latched && w_latched && !bvalid;

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            awready <= 0; wready <= 0; bvalid <= 0;
            aw_latched <= 0; w_latched <= 0;
            awaddr_q <= 0; wdata_q <= 0;
        end else begin
            if (aw_hs) awaddr_q <= S_AXI_AWADDR;
            if (w_hs)  wdata_q  <= S_AXI_WDATA;
            aw_latched <= aw_hs ? 1'b1 : (wr_commit ? 1'b0 : aw_latched);
            w_latched  <= w_hs  ? 1'b1 : (wr_commit ? 1'b0 : w_latched);
            bvalid     <= wr_commit ? 1'b1 :
                          (bvalid && S_AXI_BREADY) ? 1'b0 : bvalid;
            awready    <= !aw_latched || wr_commit;
            wready     <= !w_latched  || wr_commit;
        end
    end

    assign S_AXI_AWREADY = awready;
    assign S_AXI_WREADY  = wready;
    assign S_AXI_BVALID  = bvalid;
    assign S_AXI_BRESP   = 2'b00;

    // ==================== AXI-Lite read channel ===========================
    logic arready, rvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] araddr_q;
    wire ar_hs = S_AXI_ARVALID && arready;

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            arready <= 0; rvalid <= 0; araddr_q <= 0;
        end else begin
            if (S_AXI_ARVALID && !arready && !rvalid) arready <= 1;
            else                                        arready <= 0;
            if (ar_hs) begin
                araddr_q <= S_AXI_ARADDR;
                rvalid   <= 1;
            end else if (rvalid && S_AXI_RREADY) rvalid <= 0;
        end
    end

    logic [C_S_AXI_DATA_WIDTH-1:0] rdata_mux;
    assign S_AXI_ARREADY = arready;
    assign S_AXI_RVALID  = rvalid;
    assign S_AXI_RDATA   = rdata_mux;
    assign S_AXI_RRESP   = 2'b00;

    // ==================== Register writes ==================================
    wire wr_ctrl = wr_commit && (awaddr_q[ADDR_LSB+:3] == 3'd0);
    wire wr_cmd  = wr_commit && (awaddr_q[ADDR_LSB+:3] == 3'd2);
    wire wr_addr = wr_commit && (awaddr_q[ADDR_LSB+:3] == 3'd3);
    wire wr_len  = wr_commit && (awaddr_q[ADDR_LSB+:3] == 3'd4);
    wire wr_data = wr_commit && (awaddr_q[ADDR_LSB+:3] == 3'd5);

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            ctrl_start_q <= 1'b0; ctrl_abort_q <= 1'b0;
            cmd_wren_q   <= 1'b0; cmd_rdid_q   <= 1'b0;
            cmd_byte_q   <= 8'h0; addr_q       <= 24'h0;
            len_q        <= 32'h0; tx_byte_q    <= 8'h0;
            tx_byte_valid_q <= 1'b0;
        end else begin
            ctrl_start_q <= 1'b0;   // self-clear
            if (wr_ctrl) begin
                ctrl_start_q <= wdata_q[0];
                ctrl_abort_q <= wdata_q[1];
                cmd_wren_q   <= wdata_q[2];
                cmd_rdid_q   <= wdata_q[3];
            end
            if (wr_cmd)  cmd_byte_q <= wdata_q[7:0];
            if (wr_addr) addr_q     <= wdata_q[23:0];
            if (wr_len)  len_q      <= wdata_q;
            if (wr_data) begin
                tx_byte_q       <= wdata_q[7:0];
                tx_byte_valid_q <= 1'b1;
            end
            if (status_busy_q && tx_byte_valid_q) tx_byte_valid_q <= 1'b0;
        end
    end

    // ==================== SPI clock divider ==============================
    logic [15:0] div_cnt;
    logic        spi_clk_q;
    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            div_cnt   <= 16'h0;
            spi_clk_q <= 1'b0;
        end else if (div_cnt == CLK_DIV-1) begin
            div_cnt   <= 16'h0;
            spi_clk_q <= ~spi_clk_q;
        end else begin
            div_cnt <= div_cnt + 1'b1;
        end
    end

    logic spi_clk_rise, spi_clk_fall;
    logic spi_clk_q_d;
    always_ff @(posedge S_AXI_ACLK) spi_clk_q_d <= spi_clk_q;
    assign spi_clk_rise =  spi_clk_q & ~spi_clk_q_d;
    assign spi_clk_fall = ~spi_clk_q &  spi_clk_q_d;

    // ==================== SPI FSM =========================================
    typedef enum logic [2:0] {
        ST_IDLE, ST_CMD, ST_ADDR, ST_DATA, ST_DONE, ST_ERROR
    } state_t;
    state_t state, state_n;

    logic [2:0]  bit_cnt;
    logic [7:0]  shift_out, shift_in;
    logic [23:0] addr_shift;
    logic [31:0] len_cnt;
    logic        cs_n_q;
    logic        mosi_q;

    // Set WIP/ERROR status on abort and after erase
    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            status_busy_q  <= 1'b0;
            status_done_q  <= 1'b0;
            status_error_q <= 1'b0;
            status_wip_q   <= 1'b0;
        end else begin
            if (state == ST_IDLE && ctrl_start_q) begin
                status_busy_q <= 1'b1;
                status_done_q <= 1'b0;
                status_error_q <= 1'b0;
            end else if (state_n == ST_DONE) begin
                status_busy_q <= 1'b0;
                status_done_q <= 1'b1;
            end else if (state_n == ST_ERROR) begin
                status_busy_q  <= 1'b0;
                status_error_q <= 1'b1;
            end
            if (ctrl_abort_q) begin
                status_busy_q  <= 1'b0;
                status_error_q <= 1'b1;
            end
        end
    end

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            state       <= ST_IDLE;
            bit_cnt     <= 3'h7;
            shift_out   <= 8'h0;
            shift_in    <= 8'h0;
            addr_shift  <= 24'h0;
            len_cnt     <= 32'h0;
            cs_n_q      <= 1'b1;
            mosi_q      <= 1'b0;
            rx_byte_q   <= 8'h0;
        end else begin
            state <= state_n;
            state_n <= state;   // MDRV-1 fix: registered default next-state
            if (state == ST_IDLE && ctrl_start_q) state_n <= ST_CMD;
            if (state == ST_IDLE && ctrl_start_q) begin
                bit_cnt    <= 3'h7;
                shift_out  <= cmd_wren_q ? 8'h06 :
                              cmd_rdid_q ? 8'h9F : cmd_byte_q;
                addr_shift <= addr_q;
                len_cnt    <= len_q;
                cs_n_q     <= 1'b0;
                rx_byte_q  <= 8'h0;
            end
            if ((state == ST_CMD || state == ST_ADDR || state == ST_DATA)) begin
                if (spi_clk_fall) begin
                    shift_out <= {shift_out[6:0], 1'b0};
                    mosi_q    <= shift_out[7];
                end
                if (spi_clk_rise) begin
                    shift_in <= {shift_in[6:0], spi_miso};
                    if (bit_cnt == 3'h0) begin
                        bit_cnt <= 3'h7;
                        if (state == ST_CMD) begin
                            state_n <= (cmd_byte_q == 8'h06 || cmd_byte_q == 8'h9F ||
                                       cmd_byte_q == 8'hC7) ? ST_DONE : ST_ADDR;
                            if (cmd_byte_q == 8'h9F) state_n <= ST_DATA;
                            addr_shift <= addr_q;
                        end else if (state == ST_ADDR) begin
                            addr_shift <= {addr_shift[22:0], 1'b0};
                            state_n <= ST_DATA;
                        end else if (state == ST_DATA) begin
                            rx_byte_q <= {shift_in[6:0], spi_miso};
                            if (len_cnt == 32'h0) state_n <= ST_DONE;
                            else len_cnt <= len_cnt - 1'b1;
                        end
                    end else begin
                        bit_cnt <= bit_cnt - 1'b1;
                    end
                end
            end
            if (state == ST_DONE || state == ST_ERROR) begin
                cs_n_q <= 1'b1;
                mosi_q <= 1'b0;
                state_n <= ST_IDLE;
            end
        end
    end


    // ========================================================================
    // STARTUPE2 - drives ONLY CCLK (L12). Verified 2026-09-13:
    //   L12 is NOT a package pin -> CCLK reachable only via USRCCLKO.
    //   FCS_B/D00-D03 (T19/P22/R22/P21/R21) constrained as REGULAR IO.
    //   USRDONETS=1 keeps DOUT/CSO_B (AB20) in the fabric.
    // NOTE: if axi_hwicap also instantiates STARTUPE2 (C_INCLUDE_STARTUP=1)
    //   -> DRC UTLZ-1. Set axi_hwicap C_INCLUDE_STARTUP=0 (see docs).
    // ========================================================================
    STARTUPE2 #(
        .PROG_USR("FALSE"),
        .SIM_CCLK_FREQ(10.0)
    ) u_startup (
        .CFGCLK(),
        .CFGMCLK(),
        .EOS(),
        .PREQ(),
        .CLK(1'b0),
        .GSR(1'b0),
        .GTS(1'b0),
        .KEYCLEARB(1'b0),
        .PACK(1'b0),
        .USRCCLKO(spi_clk_q),
        .USRCCLKTS(1'b0),
        .USRDONEO(1'b0),
        .USRDONETS(1'b1)
    );

    assign spi_cclk = spi_clk_q;

    // External QSPI pads (regular fabric IO). CCLK is inside STARTUPE2 above.
    assign qspi_cs_n = cs_n_q;
    assign qspi_d0    = mosi_q ? 1'bz : 1'b0;
    assign qspi_d1    = 1'bz;
    assign qspi_d2    = 1'bz;
    assign qspi_d3    = 1'bz;

    wire spi_miso;
    assign spi_miso = qspi_d1;

endmodule