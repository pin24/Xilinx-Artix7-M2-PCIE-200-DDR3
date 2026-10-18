// Auto-generated synthesis wrapper for tdot_axi4 (SV params via generic).
// Template; placeholders %%NUM_MAC%% %%ADDERS%% %%ELEM_FMT%% %%BRD_LEN%% %%BWR_LEN%%
// are substituted by synth_tdot_axi4.tcl.
module tdot_synth_wrap #(
    parameter int NUM_MAC             = %%NUM_MAC%%,
    parameter int ADDERS              = %%ADDERS%%,
    parameter int ELEM_FMT            = %%ELEM_FMT%%,
    parameter int C_S_AXI_DATA_WIDTH  = 32,
    parameter int C_S_AXI_ADDR_WIDTH  = 8,
    parameter int C_M_AXI_ID_WIDTH    = 1,
    parameter int C_M_AXI_ADDR_WIDTH  = 32,
    parameter int C_M_AXI_DATA_WIDTH  = 64,
    parameter int BURST_RD_LEN        = %%BRD_LEN%%,
    parameter int BURST_WR_LEN        = %%BWR_LEN%%
)(
  input  logic S_AXI_ACLK,
  input  logic S_AXI_ARESETN,
  input  logic [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_AWADDR,
  input  logic S_AXI_AWPROT, input logic S_AXI_AWVALID, output logic S_AXI_AWREADY,
  input  logic [C_S_AXI_DATA_WIDTH-1:0] S_AXI_WDATA,
  input  logic [C_S_AXI_DATA_WIDTH/8-1:0] S_AXI_WSTRB,
  input  logic S_AXI_WVALID, output logic S_AXI_WREADY,
  output logic [1:0] S_AXI_BRESP, output logic S_AXI_BVALID, input logic S_AXI_BREADY,
  input  logic [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_ARADDR,
  input  logic S_AXI_ARPROT, input logic S_AXI_ARVALID, output logic S_AXI_ARREADY,
  output logic [C_S_AXI_DATA_WIDTH-1:0] S_AXI_RDATA, output logic [1:0] S_AXI_RRESP,
  output logic S_AXI_RVALID, input logic S_AXI_RREADY,
  // NOTE: M_AXI_ACLK/M_AXI_ARESETN intentionally NOT exposed as ports: they are
  // the same single clock/reset as S_AXI_ACLK/S_AXI_ARESETN (spec tdot_axi4.sv:
  // "S_AXI_ACLK and M_AXI_ACLK must be the same signal"). Exposing two separate
  // clock ports made synth build them as two clock sources -> fake -2.2ns skew
  // on the M_AXI_RREADY output path. One clock gives a honest timing report.
  output logic [C_M_AXI_ID_WIDTH-1:0] M_AXI_AWID,
  output logic [C_M_AXI_ADDR_WIDTH-1:0] M_AXI_AWADDR,
  output logic [7:0] M_AXI_AWLEN, output logic [2:0] M_AXI_AWSIZE,
  output logic [1:0] M_AXI_AWBURST, output logic M_AXI_AWLOCK,
  output logic [3:0] M_AXI_AWCACHE, output logic [2:0] M_AXI_AWPROT,
  output logic [3:0] M_AXI_AWQOS, output logic M_AXI_AWVALID,
  input  logic M_AXI_AWREADY,
  output logic [C_M_AXI_DATA_WIDTH-1:0] M_AXI_WDATA,
  output logic [C_M_AXI_DATA_WIDTH/8-1:0] M_AXI_WSTRB,
  output logic M_AXI_WLAST, output logic M_AXI_WVALID, input logic M_AXI_WREADY,
  input  logic [C_M_AXI_ID_WIDTH-1:0] M_AXI_BID, input logic [1:0] M_AXI_BRESP,
  input  logic M_AXI_BVALID, output logic M_AXI_BREADY,
  output logic [C_M_AXI_ID_WIDTH-1:0] M_AXI_ARID,
  output logic [C_M_AXI_ADDR_WIDTH-1:0] M_AXI_ARADDR,
  output logic [7:0] M_AXI_ARLEN, output logic [2:0] M_AXI_ARSIZE,
  output logic [1:0] M_AXI_ARBURST, output logic M_AXI_ARLOCK,
  output logic [3:0] M_AXI_ARCACHE, output logic [2:0] M_AXI_ARPROT,
  output logic [3:0] M_AXI_ARQOS, output logic M_AXI_ARVALID,
  input  logic M_AXI_ARREADY,
  input  logic [C_M_AXI_ID_WIDTH-1:0] M_AXI_RID,
  input  logic [C_M_AXI_DATA_WIDTH-1:0] M_AXI_RDATA,
  input  logic [1:0] M_AXI_RRESP, input logic M_AXI_RLAST, input logic M_AXI_RVALID,
  output logic M_AXI_RREADY,
  output logic sched_irq,
  output logic diag_go, output logic diag_busy, output logic diag_done,
  output logic diag_f2t_sv, output logic diag_f2t_mv, output logic diag_f2t_dv
);
  tdot_axi4 #(
    .NUM_MAC(NUM_MAC), .ADDERS(ADDERS), .ELEM_FMT(ELEM_FMT),
    .BURST_RD_LEN(BURST_RD_LEN), .BURST_WR_LEN(BURST_WR_LEN)
  ) u_core (
    .S_AXI_ACLK(S_AXI_ACLK), .S_AXI_ARESETN(S_AXI_ARESETN),
    .S_AXI_AWADDR(S_AXI_AWADDR), .S_AXI_AWPROT(S_AXI_AWPROT), .S_AXI_AWVALID(S_AXI_AWVALID), .S_AXI_AWREADY(S_AXI_AWREADY),
    .S_AXI_WDATA(S_AXI_WDATA), .S_AXI_WSTRB(S_AXI_WSTRB), .S_AXI_WVALID(S_AXI_WVALID), .S_AXI_WREADY(S_AXI_WREADY),
    .S_AXI_BRESP(S_AXI_BRESP), .S_AXI_BVALID(S_AXI_BVALID), .S_AXI_BREADY(S_AXI_BREADY),
    .S_AXI_ARADDR(S_AXI_ARADDR), .S_AXI_ARPROT(S_AXI_ARPROT), .S_AXI_ARVALID(S_AXI_ARVALID), .S_AXI_ARREADY(S_AXI_ARREADY),
    .S_AXI_RDATA(S_AXI_RDATA), .S_AXI_RRESP(S_AXI_RRESP), .S_AXI_RVALID(S_AXI_RVALID), .S_AXI_RREADY(S_AXI_RREADY),
    .M_AXI_ACLK(S_AXI_ACLK), .M_AXI_ARESETN(S_AXI_ARESETN),
    .M_AXI_AWID(M_AXI_AWID), .M_AXI_AWADDR(M_AXI_AWADDR), .M_AXI_AWLEN(M_AXI_AWLEN), .M_AXI_AWSIZE(M_AXI_AWSIZE),
    .M_AXI_AWPROT(M_AXI_AWPROT), .M_AXI_AWQOS(M_AXI_AWQOS), .M_AXI_AWVALID(M_AXI_AWVALID), .M_AXI_AWREADY(M_AXI_AWREADY),
    .M_AXI_WDATA(M_AXI_WDATA), .M_AXI_WSTRB(M_AXI_WSTRB), .M_AXI_WLAST(M_AXI_WLAST), .M_AXI_WVALID(M_AXI_WVALID), .M_AXI_WREADY(M_AXI_WREADY),
    .M_AXI_BID(M_AXI_BID), .M_AXI_BRESP(M_AXI_BRESP), .M_AXI_BVALID(M_AXI_BVALID), .M_AXI_BREADY(M_AXI_BREADY),
    .M_AXI_ARID(M_AXI_ARID), .M_AXI_ARADDR(M_AXI_ARADDR), .M_AXI_ARLEN(M_AXI_ARLEN), .M_AXI_ARSIZE(M_AXI_ARSIZE),
    .M_AXI_ARBURST(M_AXI_ARBURST), .M_AXI_ARLOCK(M_AXI_ARLOCK), .M_AXI_ARCACHE(M_AXI_ARCACHE),
    .M_AXI_ARPROT(M_AXI_ARPROT), .M_AXI_ARQOS(M_AXI_ARQOS), .M_AXI_ARVALID(M_AXI_ARVALID), .M_AXI_ARREADY(M_AXI_ARREADY),
    .M_AXI_RID(M_AXI_RID), .M_AXI_RDATA(M_AXI_RDATA), .M_AXI_RRESP(M_AXI_RRESP), .M_AXI_RLAST(M_AXI_RLAST), .M_AXI_RVALID(M_AXI_RVALID), .M_AXI_RREADY(M_AXI_RREADY),
    .sched_irq(sched_irq),
    .diag_go(diag_go), .diag_busy(diag_busy), .diag_done(diag_done),
    .diag_f2t_sv(diag_f2t_sv), .diag_f2t_mv(diag_f2t_mv), .diag_f2t_dv(diag_f2t_dv)
  );
endmodule