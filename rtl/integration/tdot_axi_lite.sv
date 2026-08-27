// ============================================================================
// tdot_axi_lite.sv - AXI-Lite периферия вокруг compute_dot_par_raw (TFloat48)
// ============================================================================
// Регистры (32-бит, байтовый адрес, из AXI-Lite [5:2]):
//   [0x00] CTRL   : бит0 GO (1 -> запуск dot, самосброс через 1 такт)
//   [0x04] STATUS : бит0 BUSY, бит1 DONE (DONE сбрасывается по GO)
//   [0x08] N_IN   : число пар (1..NUM_MAC)
//   [0x0C] RES0   : результат dot [15:0] (DONE)
//   [0x10] RES1   : результат dot [47:32] (DONE)
//   [0x14] DATA_ADDR_LO/HI    : байтовый адрес вектора data  в DDR3
//   [0x18] WEIGHTS_ADDR_LO/HI : байтовый адрес вектора weights в DDR3
//   [0x1C] RESULT_ADDR_LO/HI  : байтовый адрес результата в DDR3
//   [0x2C] CORE_RES0/1        : read-only зеркало последнего результата ядра
//
// Данные для ядра приходят по шинам core_data/core_weights (48*NUM_MAC бит),
// результат — core_result. Адреса DDR3 доступны хосту для организации DMA
// через XDMA M_AXI (который сам пишет данные в DDR3 и читает результат).
// ============================================================================
module tdot_axi_lite #(
    parameter int NUM_MAC = 32,
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int C_S_AXI_ADDR_WIDTH = 6
)(
    // AXI-Lite slave
    input  logic                                  S_AXI_ACLK,
    input  logic                                  S_AXI_ARESETN,
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]         S_AXI_AWADDR,
    input  logic                                  S_AXI_AWPROT,
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
    input  logic                                  S_AXI_ARPROT,
    input  logic                                  S_AXI_ARVALID,
    output logic                                  S_AXI_ARREADY,
    input  logic [C_S_AXI_DATA_WIDTH-1:0]         S_AXI_RDATA,
    output logic [1:0]                            S_AXI_RRESP,
    output logic                                  S_AXI_RVALID,
    input  logic                                  S_AXI_RREADY,
    // ядро
    input  logic [48*NUM_MAC-1:0]                 core_data,
    input  logic [48*NUM_MAC-1:0]                 core_weights,
    output logic                                  core_valid_in,
    input  logic [47:0]                           core_result,
    input  logic                                  core_valid_out,
    // прямые AXI-адреса (зарезервированы под DMA-доступ к DDR3)
    output logic [63:0]                           ddr_data_start,
    output logic [63:0]                           ddr_weights_start,
    output logic [63:0]                           ddr_result_addr
);

    // --- регистры ---
    logic go_reg;                 // бит0 CTRL, самосбрасывается
    logic [31:0] n_in_reg;
    logic [63:0] data_start_reg, weights_start_reg, result_addr_reg;
    logic [31:0] res0_reg, res1_reg;

    logic busy_q, done_q;

    // --- FSM запуска ядра ---
    logic core_go;
    logic [1:0] go_pipe;
    assign core_go = go_pipe[0];

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            go_pipe <= 0;
            core_valid_in <= 0;
        end else begin
            core_valid_in <= 0;
            go_pipe <= {go_pipe[0], go_reg};
            if (go_pipe[0]) core_valid_in <= 1;
        end
    end

    // --- статус ---
    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            busy_q <= 0; done_q <= 0;
        end else begin
            if (go_reg) begin
                busy_q <= 1; done_q <= 0;
            end
            if (core_valid_out) begin
                busy_q <= 0; done_q <= 1;
            end
        end
    end

    // --- AXI-Lite write channel ---
    logic awready, wready, bvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] awaddr;

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            awready <= 0; wready <= 0; bvalid <= 0; awaddr <= 0;
            go_reg <= 0; n_in_reg <= NUM_MAC;
            data_start_reg <= 0; weights_start_reg <= 0; result_addr_reg <= 0;
        end else begin
            if (S_AXI_AWVALID && !awready) begin
                awaddr <= S_AXI_AWADDR;
                awready <= 1;
            end else begin
                awready <= 0;
            end
            if (S_AXI_WVALID && !wready) begin
                wready <= 1;
            end else begin
                wready <= 0;
            end
            if (S_AXI_WVALID && S_AXI_AWVALID && !bvalid) begin
                case (awaddr[5:2])
                    4'd0: begin
                        go_reg <= S_AXI_WDATA[0];
                        n_in_reg <= S_AXI_WDATA[16:8];
                    end
                    4'd2: n_in_reg <= S_AXI_WDATA;
                    4'd5: data_start_reg[31:0]   <= S_AXI_WDATA;
                    4'd6: data_start_reg[63:32]  <= S_AXI_WDATA;
                    4'd7: weights_start_reg[31:0] <= S_AXI_WDATA;
                    4'd8: weights_start_reg[63:32] <= S_AXI_WDATA;
                    4'd9: result_addr_reg[31:0]  <= S_AXI_WDATA;
                    4'd10: result_addr_reg[63:32] <= S_AXI_WDATA;
                    default: ;
                endcase
                bvalid <= 1;
            end else if (go_reg) begin
                go_reg <= 0;   // самосброс GO
            end
            if (bvalid && S_AXI_BREADY) bvalid <= 0;
        end
    end

    // --- AXI-Lite read channel ---
    logic arready, rvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] araddr;

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            arready <= 0; rvalid <= 0; araddr <= 0;
        end else begin
            if (S_AXI_ARVALID && !arready) begin
                araddr <= S_AXI_ARADDR;
                arready <= 1;
            end else begin
                arready <= 0;
            end
            if (arready) rvalid <= 1;
            if (rvalid && S_AXI_RREADY) rvalid <= 0;
        end
    end

    logic [C_S_AXI_DATA_WIDTH-1:0] rdata;
    always_comb begin
        case (araddr[5:2])
            4'd0: rdata = {31'b0, go_reg};
            4'd1: rdata = {30'b0, done_q, busy_q};
            4'd2: rdata = n_in_reg;
            4'd3: rdata = {16'h0, res0_reg[15:0]};
            4'd4: rdata = {16'h0, res1_reg[15:0]};
            4'd5: rdata = data_start_reg[31:0];
            4'd6: rdata = data_start_reg[63:32];
            4'd7: rdata = weights_start_reg[31:0];
            4'd8: rdata = weights_start_reg[63:32];
            4'd9: rdata = result_addr_reg[31:0];
            4'd10: rdata = result_addr_reg[63:32];
            4'd11: rdata = {16'h0, core_result[15:0]};
            4'd12: rdata = {16'h0, core_result[47:32]};
            default: rdata = 32'h0;
        endcase
    end

    // --- захват результата ядра ---
    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            res0_reg <= 0; res1_reg <= 0;
        end else if (core_valid_out) begin
            res0_reg <= {16'h0, core_result[15:0]};
            res1_reg <= {16'h0, core_result[47:32]};
        end
    end

    assign S_AXI_AWREADY = awready;
    assign S_AXI_WREADY  = wready;
    assign S_AXI_BRESP   = 2'b00;
    assign S_AXI_BVALID  = bvalid;
    assign S_AXI_ARREADY = arready;
    assign S_AXI_RRESP   = 2'b00;
    assign S_AXI_RVALID  = rvalid;
    assign S_AXI_RDATA   = rdata;

    assign ddr_data_start   = data_start_reg;
    assign ddr_weights_start = weights_start_reg;
    assign ddr_result_addr  = result_addr_reg;

endmodule
