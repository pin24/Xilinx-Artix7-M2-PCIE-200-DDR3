// ============================================================================
// core_wrapper_top.sv - top для standalone-проверки: tdot_axi_lite + ядро + тест
// (синтезируется отдельно, вне BD, чтобы измерить ресурсы интеграции)
// ============================================================================
module core_wrapper_top #(
    parameter int NUM_MAC = 32
)(
    input  logic clk,
    input  logic rst_n,
    // AXI-Lite (пример подключения)
    input  logic [5:0]  S_AXI_AWADDR,
    input  logic        S_AXI_AWVALID,
    input  logic [31:0] S_AXI_WDATA,
    input  logic [3:0]  S_AXI_WSTRB,
    input  logic        S_AXI_WVALID,
    input  logic        S_AXI_BREADY,
    input  logic [5:0]  S_AXI_ARADDR,
    input  logic        S_AXI_ARVALID,
    input  logic        S_AXI_RREADY,
    output logic        S_AXI_AWREADY,
    output logic        S_AXI_WREADY,
    output logic        S_AXI_BVALID,
    output logic        S_AXI_ARREADY,
    output logic        S_AXI_RVALID,
    output logic [31:0] S_AXI_RDATA,
    // ядро (прямые порты для теста)
    input  logic [48*NUM_MAC-1:0] core_data,
    input  logic [48*NUM_MAC-1:0] core_weights,
    output logic [47:0] core_result,
    output logic core_valid_out
);

    logic core_valid_in;

    tdot_axi_lite #(.NUM_MAC(NUM_MAC)) u_lite (
        .S_AXI_ACLK(clk), .S_AXI_ARESETN(rst_n),
        .S_AXI_AWADDR(S_AXI_AWADDR), .S_AXI_AWPROT(1'b0),
        .S_AXI_AWVALID(S_AXI_AWVALID), .S_AXI_AWREADY(S_AXI_AWREADY),
        .S_AXI_WDATA(S_AXI_WDATA), .S_AXI_WSTRB(S_AXI_WSTRB),
        .S_AXI_WVALID(S_AXI_WVALID), .S_AXI_WREADY(S_AXI_WREADY),
        .S_AXI_BRESP(), .S_AXI_BVALID(S_AXI_BVALID),
        .S_AXI_BREADY(S_AXI_BREADY),
        .S_AXI_ARADDR(S_AXI_ARADDR), .S_AXI_ARPROT(1'b0),
        .S_AXI_ARVALID(S_AXI_ARVALID), .S_AXI_ARREADY(S_AXI_ARREADY),
        .S_AXI_RDATA(S_AXI_RDATA), .S_AXI_RRESP(),
        .S_AXI_RVALID(S_AXI_RVALID), .S_AXI_RREADY(S_AXI_RREADY),
        .core_data(core_data), .core_weights(core_weights),
        .core_valid_in(core_valid_in),
        .core_result(core_result), .core_valid_out(core_valid_out),
        .ddr_data_start(), .ddr_weights_start(), .ddr_result_addr()
    );

    compute_dot_par_raw #(.NUM_MAC(NUM_MAC)) u_core (
        .clk(clk), .rst_n(rst_n),
        .data_in(core_data), .weights(core_weights), .valid_in(core_valid_in),
        .result_out(core_result), .valid_out(core_valid_out)
    );

endmodule
