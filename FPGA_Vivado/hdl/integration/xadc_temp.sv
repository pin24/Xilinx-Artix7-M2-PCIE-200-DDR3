module xadc_temp #(
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
    input  logic                                  S_AXI_RREADY,
    input  logic [15:0]                           raw_temp,
    input  logic [15:0]                           raw_vccint,
    input  logic                                  raw_valid
);

    logic clk, rst_n;
    assign clk = S_AXI_ACLK;
    assign rst_n = S_AXI_ARESETN;

    localparam int ADDR_LSB = 2;

    logic awready, wready, bvalid;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin awready <= 0; wready <= 0; bvalid <= 0; end
        else begin
            awready <= 0; wready <= 0;
            if (S_AXI_AWVALID && !awready) awready <= 1;
            if (S_AXI_WVALID && !wready) wready <= 1;
            bvalid <= 0;
            if (S_AXI_AWVALID && S_AXI_WVALID && !bvalid) bvalid <= 1;
            if (bvalid && S_AXI_BREADY) bvalid <= 0;
        end
    end

    logic arready, rvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] araddr_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin arready <= 0; rvalid <= 0; araddr_q <= 0; end
        else begin
            arready <= 0;
            if (S_AXI_ARVALID && !arready) begin araddr_q <= S_AXI_ARADDR; arready <= 1; end
            if (arready && !rvalid) rvalid <= 1;
            if (rvalid && S_AXI_RREADY) rvalid <= 0;
        end
    end

    logic [15:0] temp_val, vccint_val;
    logic valid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin temp_val <= 0; vccint_val <= 0; valid_q <= 0; end
        else if (raw_valid) begin
            temp_val <= raw_temp;
            vccint_val <= raw_vccint;
            valid_q <= 1;
        end
    end

    logic [C_S_AXI_DATA_WIDTH-1:0] rdata;
    always_comb begin
        case (araddr_q[ADDR_LSB+:2])
            2'd0: rdata = {16'h0, temp_val};
            2'd1: rdata = {16'h0, vccint_val};
            2'd2: rdata = {31'b0, valid_q};
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

endmodule