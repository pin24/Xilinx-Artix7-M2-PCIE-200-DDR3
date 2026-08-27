module axi_slave_ok #(
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int C_S_AXI_ADDR_WIDTH = 16
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

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_AWREADY <= 0; S_AXI_WREADY <= 0; S_AXI_BVALID <= 0;
            S_AXI_ARREADY <= 0; S_AXI_RVALID <= 0;
        end else begin
            S_AXI_AWREADY <= S_AXI_AWVALID ? 1 : 0;
            S_AXI_WREADY  <= S_AXI_WVALID  ? 1 : 0;
            if (S_AXI_AWVALID && S_AXI_WVALID && !S_AXI_BVALID)
                S_AXI_BVALID <= 1;
            if (S_AXI_BVALID && S_AXI_BREADY)
                S_AXI_BVALID <= 0;
            S_AXI_ARREADY <= S_AXI_ARVALID ? 1 : 0;
            if (S_AXI_ARVALID && !S_AXI_RVALID)
                S_AXI_RVALID <= 1;
            if (S_AXI_RVALID && S_AXI_RREADY)
                S_AXI_RVALID <= 0;
        end
    end
    assign S_AXI_BRESP = 2'b00;
    assign S_AXI_RRESP = 2'b00;
    assign S_AXI_RDATA = 32'h0;

endmodule