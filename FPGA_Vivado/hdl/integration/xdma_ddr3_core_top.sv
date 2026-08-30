// ============================================================================
// xdma_ddr3_core_top.sv — Top-level для XDMA_DDR3_V2
// Инстанциирует BD (xdma_ddr3) + tdot_axi4 (TFloat48 вычислитель)
// ============================================================================
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
    output [2:0]  gpio_rtl_0_tri_o,
    input  [3:0]  pcie_7x_mgt_rtl_0_rxn,
    input  [3:0]  pcie_7x_mgt_rtl_0_rxp,
    output [3:0]  pcie_7x_mgt_rtl_0_txn,
    output [3:0]  pcie_7x_mgt_rtl_0_txp,
    input         reset_rtl_0
);

    // Сигналы от BD
    wire        axi_aclk;
    wire        axi_aresetn;
    wire [31:0] m_axi_awaddr;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize, m_axi_arsize;
    wire [1:0]  m_axi_awburst, m_axi_arburst;
    wire        m_axi_awlock, m_axi_arlock;
    wire [3:0]  m_axi_awcache, m_axi_arcache;
    wire [2:0]  m_axi_awprot, m_axi_arprot;
    wire [3:0]  m_axi_awqos, m_axi_arqos;
    wire        m_axi_awvalid, m_axi_awready;
    wire [63:0] m_axi_wdata;
    wire [7:0]  m_axi_wstrb;
    wire        m_axi_wlast, m_axi_wvalid, m_axi_wready;
    wire        m_axi_bvalid, m_axi_bready;
    wire [1:0]  m_axi_bresp;
    wire        m_axi_arvalid, m_axi_arready;
    wire [63:0] m_axi_rdata;
    wire        m_axi_rvalid, m_axi_rready, m_axi_rlast;
    wire [1:0]  m_axi_rresp;

    wire [31:0] s_axil_awaddr, s_axil_araddr;
    wire        s_axil_awvalid, s_axil_awready;
    wire [31:0] s_axil_wdata;
    wire [3:0]  s_axil_wstrb;
    wire        s_axil_wvalid, s_axil_wready;
    wire [1:0]  s_axil_bresp;
    wire        s_axil_bvalid, s_axil_bready;
    wire        s_axil_arvalid, s_axil_arready;
    wire [31:0] s_axil_rdata;
    wire [1:0]  s_axil_rresp;
    wire        s_axil_rvalid, s_axil_rready;

    // BD wrapper
    xdma_ddr3 xdma_ddr3_i (
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
        .gpio_rtl_0_tri_o(gpio_rtl_0_tri_o),
        .M_AXI_awaddr(m_axi_awaddr), .M_AXI_awlen(m_axi_awlen),
        .M_AXI_awsize(m_axi_awsize), .M_AXI_awburst(m_axi_awburst),
        .M_AXI_awlock(m_axi_awlock), .M_AXI_awcache(m_axi_awcache),
        .M_AXI_awprot(m_axi_awprot), .M_AXI_awqos(m_axi_awqos),
        .M_AXI_awvalid(m_axi_awvalid), .M_AXI_awready(m_axi_awready),
        .M_AXI_wdata(m_axi_wdata), .M_AXI_wstrb(m_axi_wstrb),
        .M_AXI_wlast(m_axi_wlast), .M_AXI_wvalid(m_axi_wvalid),
        .M_AXI_wready(m_axi_wready),
        .M_AXI_bresp(m_axi_bresp), .M_AXI_bvalid(m_axi_bvalid),
        .M_AXI_bready(m_axi_bready),
        .M_AXI_araddr(m_axi_araddr), .M_AXI_arlen(m_axi_arlen),
        .M_AXI_arsize(m_axi_arsize), .M_AXI_arburst(m_axi_arburst),
        .M_AXI_arlock(m_axi_arlock), .M_AXI_arcache(m_axi_arcache),
        .M_AXI_arprot(m_axi_arprot), .M_AXI_arqos(m_axi_arqos),
        .M_AXI_arvalid(m_axi_arvalid), .M_AXI_arready(m_axi_arready),
        .M_AXI_rdata(m_axi_rdata), .M_AXI_rresp(m_axi_rresp),
        .M_AXI_rlast(m_axi_rlast), .M_AXI_rvalid(m_axi_rvalid),
        .M_AXI_rready(m_axi_rready),
        .S_AXI_TDOT_REGS_awaddr(s_axil_awaddr), .S_AXI_TDOT_REGS_awprot(),
        .S_AXI_TDOT_REGS_awvalid(s_axil_awvalid), .S_AXI_TDOT_REGS_awready(s_axil_awready),
        .S_AXI_TDOT_REGS_wdata(s_axil_wdata), .S_AXI_TDOT_REGS_wstrb(s_axil_wstrb),
        .S_AXI_TDOT_REGS_wvalid(s_axil_wvalid), .S_AXI_TDOT_REGS_wready(s_axil_wready),
        .S_AXI_TDOT_REGS_bresp(s_axil_bresp), .S_AXI_TDOT_REGS_bvalid(s_axil_bvalid),
        .S_AXI_TDOT_REGS_bready(s_axil_bready),
        .S_AXI_TDOT_REGS_araddr(s_axil_araddr), .S_AXI_TDOT_REGS_arprot(),
        .S_AXI_TDOT_REGS_arvalid(s_axil_arvalid), .S_AXI_TDOT_REGS_arready(s_axil_arready),
        .S_AXI_TDOT_REGS_rdata(s_axil_rdata), .S_AXI_TDOT_REGS_rresp(s_axil_rresp),
        .S_AXI_TDOT_REGS_rvalid(s_axil_rvalid), .S_AXI_TDOT_REGS_rready(s_axil_rready),
        .pcie_7x_mgt_rtl_0_rxn(pcie_7x_mgt_rtl_0_rxn),
        .pcie_7x_mgt_rtl_0_rxp(pcie_7x_mgt_rtl_0_rxp),
        .pcie_7x_mgt_rtl_0_txn(pcie_7x_mgt_rtl_0_txn),
        .pcie_7x_mgt_rtl_0_txp(pcie_7x_mgt_rtl_0_txp),
        .reset_rtl_0(reset_rtl_0)
    );

    // tdot_axi4 — TFloat48 вычислитель
    tdot_axi4 #(.NUM_MAC(NUM_MAC)) u_tdot (
        .S_AXI_ACLK(axi_aclk), .S_AXI_ARESETN(axi_aresetn),
        .S_AXI_AWADDR(s_axil_awaddr[7:0]), .S_AXI_AWPROT(1'b0),
        .S_AXI_AWVALID(s_axil_awvalid), .S_AXI_AWREADY(s_axil_awready),
        .S_AXI_WDATA(s_axil_wdata), .S_AXI_WSTRB(s_axil_wstrb),
        .S_AXI_WVALID(s_axil_wvalid), .S_AXI_WREADY(s_axil_wready),
        .S_AXI_BRESP(s_axil_bresp), .S_AXI_BVALID(s_axil_bvalid),
        .S_AXI_BREADY(s_axil_bready),
        .S_AXI_ARADDR(s_axil_araddr[7:0]), .S_AXI_ARPROT(1'b0),
        .S_AXI_ARVALID(s_axil_arvalid), .S_AXI_ARREADY(s_axil_arready),
        .S_AXI_RDATA(s_axil_rdata), .S_AXI_RRESP(s_axil_rresp),
        .S_AXI_RVALID(s_axil_rvalid), .S_AXI_RREADY(s_axil_rready),
        .M_AXI_ACLK(axi_aclk), .M_AXI_ARESETN(axi_aresetn),
        .M_AXI_AWID(), .M_AXI_AWADDR(m_axi_awaddr), .M_AXI_AWLEN(m_axi_awlen),
        .M_AXI_AWSIZE(m_axi_awsize), .M_AXI_AWBURST(m_axi_awburst),
        .M_AXI_AWLOCK(m_axi_awlock), .M_AXI_AWCACHE(m_axi_awcache),
        .M_AXI_AWPROT(m_axi_awprot), .M_AXI_AWQOS(m_axi_awqos),
        .M_AXI_AWVALID(m_axi_awvalid), .M_AXI_AWREADY(m_axi_awready),
        .M_AXI_WDATA(m_axi_wdata), .M_AXI_WSTRB(m_axi_wstrb),
        .M_AXI_WLAST(m_axi_wlast), .M_AXI_WVALID(m_axi_wvalid),
        .M_AXI_WREADY(m_axi_wready),
        .M_AXI_BID(), .M_AXI_BRESP(m_axi_bresp),
        .M_AXI_BVALID(m_axi_bvalid), .M_AXI_BREADY(m_axi_bready),
        .M_AXI_ARID(), .M_AXI_ARADDR(m_axi_araddr), .M_AXI_ARLEN(m_axi_arlen),
        .M_AXI_ARSIZE(m_axi_arsize), .M_AXI_ARBURST(m_axi_arburst),
        .M_AXI_ARLOCK(m_axi_arlock), .M_AXI_ARCACHE(m_axi_arcache),
        .M_AXI_ARPROT(m_axi_arprot), .M_AXI_ARQOS(m_axi_arqos),
        .M_AXI_ARVALID(m_axi_arvalid), .M_AXI_ARREADY(m_axi_arready),
        .M_AXI_RID(), .M_AXI_RDATA(m_axi_rdata), .M_AXI_RRESP(m_axi_rresp),
        .M_AXI_RLAST(m_axi_rlast), .M_AXI_RVALID(m_axi_rvalid),
        .M_AXI_RREADY(m_axi_rready)
    );

    // AXI тактовые и сброс от BD
    assign axi_aclk = xdma_ddr3_i/axi_aclk;
    assign axi_aresetn = xdma_ddr3_i/axi_aresetn;

endmodule