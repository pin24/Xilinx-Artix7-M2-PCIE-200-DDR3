// ============================================================================
// tdot_axi_lite.sv - AXI-Lite периферия вокруг compute_dot_par_raw (TFloat48)
// ============================================================================
// LEGACY-дубль tdot_axi4 без AXI4-мастера; держать регистровую карту
// синхронной с tdot_axi4.
//
// Регистры (32-бит, байтовый адрес, из AXI-Lite [5:2]):
//   [0x00] CTRL   : бит0 GO (1 -> запуск dot, самосброс через 1 такт)
//   [0x04] STATUS : бит0 BUSY, бит1 DONE (DONE сбрасывается по GO)
//   [0x08] N_IN   : число пар (1..NUM_MAC)
//   [0x0C] RES0   : результат dot [31:0] (DONE)
//   [0x10] RES1   : {16'h0, результат dot [47:32]} (DONE)
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

    // --- AXI-Lite write channel: приём AW и W НЕЗАВИСИМЫЙ, с защёлками
    // глубиной 1. Запись применяется (commit), когда защёлкнуты ОБА (адрес
    // и данные), а bvalid свободен. Это устраняет тупик/потерю записи, когда
    // AWVALID и WVALID не совпадают в одном такте.
    logic awready, wready, bvalid;
    logic aw_latched, w_latched;    // занятость защёлок адреса/данных
    logic [C_S_AXI_ADDR_WIDTH-1:0] awaddr_q;
    logic [C_S_AXI_DATA_WIDTH-1:0] wdata_q;

    wire aw_hs     = S_AXI_AWVALID && awready;            // handshake AW
    wire w_hs      = S_AXI_WVALID  && wready;             // handshake W
    wire wr_commit = aw_latched && w_latched && !bvalid;  // commit: оба защёлкнуты, B свободен

    // состояние на следующий такт (для формирования готовностей без тупиков)
    wire aw_latched_n = aw_hs ? 1'b1 : (wr_commit ? 1'b0 : aw_latched);
    wire w_latched_n  = w_hs  ? 1'b1 : (wr_commit ? 1'b0 : w_latched);
    wire bvalid_n     = wr_commit ? 1'b1 :
                        (bvalid && S_AXI_BREADY) ? 1'b0 : bvalid;
    wire wr_commit_n  = aw_latched_n && w_latched_n && !bvalid_n;

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            awready <= 0; wready <= 0; bvalid <= 0;
            aw_latched <= 0; w_latched <= 0;
            awaddr_q <= 0; wdata_q <= 0;
            go_reg <= 0; n_in_reg <= NUM_MAC;
            data_start_reg <= 0; weights_start_reg <= 0; result_addr_reg <= 0;
        end else begin
            // приём AW/W в защёлки по handshake каждого канала независимо
            if (aw_hs) awaddr_q <= S_AXI_AWADDR;
            if (w_hs)  wdata_q  <= S_AXI_WDATA;
            aw_latched <= aw_latched_n;   // handshake заполняет, commit освобождает
            w_latched  <= w_latched_n;
            bvalid     <= bvalid_n;       // ответ: выставляется по commit, сброс по BREADY
            // готовности: защёлка свободна ИЛИ освободится этим тактом (commit).
            // Если обе защёлки заняты и bvalid висит - готовности сняты,
            // пока не освободится место.
            awready <= !aw_latched_n || wr_commit_n;
            wready  <= !w_latched_n  || wr_commit_n;
            // применение записи из защёлок
            // (запись CTRL ставит только go_reg - N_IN не трогаем!)
            if (wr_commit) begin
                case (awaddr_q[5:2])
                    4'd0: begin
                        go_reg <= wdata_q[0];
                    end
                    4'd2: n_in_reg <= wdata_q;
                    4'd5: data_start_reg[31:0]    <= wdata_q;
                    4'd6: data_start_reg[63:32]   <= wdata_q;
                    4'd7: weights_start_reg[31:0] <= wdata_q;
                    4'd8: weights_start_reg[63:32]<= wdata_q;
                    4'd9: result_addr_reg[31:0]   <= wdata_q;
                    4'd10: result_addr_reg[63:32] <= wdata_q;
                    default: ;
                endcase
            end else if (go_reg) begin
                go_reg <= 0;   // самосброс GO
            end
        end
    end

    // --- AXI-Lite read channel: независимый приём AR (защёлка адреса), ответ
    // (rvalid + rdata) выставляется в следующем такте, сброс по rvalid && RREADY.
    // Новый AR не принимается, пока висит непрочитанный ответ.
    logic arready, rvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] araddr_q;
    wire ar_hs = S_AXI_ARVALID && arready;   // handshake AR

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            arready <= 0; rvalid <= 0; araddr_q <= 0;
        end else begin
            // готовность к приёму AR: через такт после ARVALID и только
            // при отсутствии висящего ответа
            if (S_AXI_ARVALID && !arready && !rvalid) begin
                arready <= 1;
            end else begin
                arready <= 0;
            end
            // приём AR: фиксируем адрес, rvalid - в следующем такте
            if (ar_hs) begin
                araddr_q <= S_AXI_ARADDR;
                rvalid   <= 1;
            end else if (rvalid && S_AXI_RREADY) begin
                rvalid <= 0;
            end
        end
    end

    logic [C_S_AXI_DATA_WIDTH-1:0] rdata;
    always_comb begin
        case (araddr_q[5:2])
            4'd0: rdata = {31'b0, go_reg};
            4'd1: rdata = {30'b0, done_q, busy_q};
            4'd2: rdata = n_in_reg;
            4'd3: rdata = res0_reg;                      // результат [31:0]
            4'd4: rdata = res1_reg;                      // {16'h0, результат [47:32]}
            4'd5: rdata = data_start_reg[31:0];
            4'd6: rdata = data_start_reg[63:32];
            4'd7: rdata = weights_start_reg[31:0];
            4'd8: rdata = weights_start_reg[63:32];
            4'd9: rdata = result_addr_reg[31:0];
            4'd10: rdata = result_addr_reg[63:32];
            4'd11: rdata = core_result[31:0];            // CORE_RES0: результат [31:0]
            4'd12: rdata = {16'h0, core_result[47:32]};  // CORE_RES1: результат [47:32]
            default: rdata = 32'h0;
        endcase
    end

    // --- захват результата ядра ---
    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            res0_reg <= 0; res1_reg <= 0;
        end else if (core_valid_out) begin
            res0_reg <= core_result[31:0];             // результат [31:0]
            res1_reg <= {16'h0, core_result[47:32]};   // результат [47:32]
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
