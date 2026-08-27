// ============================================================================
// icap_ctrl.sv — простой ICAP-контроллер: хост пишет слова напрямую в DATA
// Регистры (32-бит, байтовый адрес):
//   [0x00] CTRL   bit0 GO, bit1 STOP
//   [0x04] STATUS bit0 READY, bit1 BUSY
//   [0x08] DATA   write-only, 32-бит слово для ICAP
// Порядок работы:
//   1. Хост пишет CTRL.GO=1 → BUSY=1, CSB=0, RDWRB=0
//   2. Хост ждёт STATUS.READY=1
//   3. Хост пишет первое слово 0xAA995566 в DATA
//   4. Контроллер отправляет слово в ICAP, READY=0 на 1-2 такта
//   5. Повторять 2-4 для каждого слова битстрима
//   6. Хост пишет CTRL.STOP=1 после DESYNC
// ============================================================================
module icap_ctrl #(
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int C_S_AXI_ADDR_WIDTH = 8
)(
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
    output logic [C_S_AXI_DATA_WIDTH-1:0]         S_AXI_RDATA,
    output logic [1:0]                            S_AXI_RRESP,
    output logic                                  S_AXI_RVALID,
    input  logic                                  S_AXI_RREADY
);

    logic clk, rst_n;
    assign clk = S_AXI_ACLK;
    assign rst_n = S_AXI_ARESETN;

    localparam int ADDR_LSB = 2;

    logic awready, wready, bvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] awaddr_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awready <= 0; wready <= 0; bvalid <= 0; awaddr_q <= 0;
        end else begin
            awready <= 0; wready <= 0;
            if (S_AXI_AWVALID && !awready) begin
                awaddr_q <= S_AXI_AWADDR;
                awready <= 1;
            end
            if (S_AXI_WVALID && !wready) begin
                wready <= 1;
            end
            bvalid <= 0;
            if (S_AXI_AWVALID && S_AXI_WVALID && !bvalid) begin
                bvalid <= 1;
            end
            if (bvalid && S_AXI_BREADY) bvalid <= 0;
        end
    end

    logic arready, rvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] araddr_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arready <= 0; rvalid <= 0; araddr_q <= 0;
        end else begin
            arready <= 0;
            if (S_AXI_ARVALID && !arready) begin
                araddr_q <= S_AXI_ARADDR;
                arready <= 1;
            end
            if (arready && !rvalid) begin
                rvalid <= 1;
            end
            if (rvalid && S_AXI_RREADY) rvalid <= 0;
        end
    end

    logic [C_S_AXI_DATA_WIDTH-1:0] rdata;
    logic go_reg, stop_reg;
    logic ready_q, busy_q;

    always_comb begin
        case (araddr_q[ADDR_LSB+:2])
            2'd0: rdata = {30'b0, stop_reg, go_reg};
            2'd1: rdata = {30'b0, busy_q, ready_q};
            default: rdata = 32'h0;
        endcase
    end

    assign S_AXI_AWREADY = awready;
    assign S_AXI_WREADY = wready;
    assign S_AXI_BRESP = 2'b00;
    assign S_AXI_BVALID = bvalid;
    assign S_AXI_ARREADY = arready;
    assign S_AXI_RRESP = 2'b00;
    assign S_AXI_RVALID = rvalid;
    assign S_AXI_RDATA = rdata;

    logic [31:0] data_reg;
    logic data_wr;
    assign data_wr = S_AXI_AWVALID && S_AXI_WVALID && (S_AXI_AWADDR[ADDR_LSB+:2] == 2'd2);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            go_reg <= 0; stop_reg <= 0; data_reg <= 0;
        end else begin
            if (S_AXI_AWVALID && S_AXI_WVALID) begin
                if (S_AXI_AWADDR[ADDR_LSB+:2] == 2'd0) begin
                    go_reg <= S_AXI_WDATA[0];
                    stop_reg <= S_AXI_WDATA[1];
                end
                if (S_AXI_AWADDR[ADDR_LSB+:2] == 2'd2) begin
                    data_reg <= S_AXI_WDATA;
                end
            end else begin
                if (go_reg) go_reg <= 0;
                if (stop_reg) stop_reg <= 0;
            end
        end
    end

    logic icap_cs, icap_rw;
    logic [31:0] icap_data;

    ICAPE2 #(
        .ICAP_WIDTH("X32"),
        .SIM_CFG_FILE_NAME("NONE")
    ) u_icap (
        .O(),
        .CLK(clk),
        .CSIB(icap_cs),
        .I(icap_data),
        .RDWRB(icap_rw)
    );

    logic [1:0] clk_en_cnt;
    logic clk_en;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) clk_en_cnt <= 0;
        else clk_en_cnt <= clk_en_cnt + 1;
    end
    assign clk_en = (clk_en_cnt == 0);

    localparam ST_IDLE = 0;
    localparam ST_SEND = 1;
    localparam ST_WAIT = 2;
    logic [1:0] state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            ready_q <= 1; busy_q <= 0;
            icap_cs <= 1; icap_rw <= 1; icap_data <= 0;
        end else begin
            case (state)
                ST_IDLE: begin
                    icap_cs <= 1; icap_rw <= 1;
                    ready_q <= 1;
                    if (go_reg) begin
                        busy_q <= 1; ready_q <= 0;
                        icap_cs <= 0; icap_rw <= 0;
                        state <= ST_SEND;
                    end
                    if (stop_reg) begin
                        busy_q <= 0;
                    end
                end
                ST_SEND: begin
                    if (!clk_en) begin
                    end else if (data_wr) begin
                        icap_data <= S_AXI_WDATA;
                        ready_q <= 0;
                        state <= ST_WAIT;
                    end else if (stop_reg) begin
                        icap_cs <= 1; icap_rw <= 1;
                        busy_q <= 0;
                        state <= ST_IDLE;
                    end
                end
                ST_WAIT: begin
                    ready_q <= 0;
                    if (clk_en) begin
                        ready_q <= 1;
                        state <= ST_SEND;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule