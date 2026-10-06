// FIX-DIAG 2026-10-03: NUM_MAC default lowered 32 -> 16 to free DSP48/LUT/BRAM
// for the diagnostic modules (BRAM bypass, AXI sniffers, compare regfile).
// ADDERS=4 (было 8): вдвое меньше barrel-аддеров -> меньше LUT/плотность и короче
// маршрут деревьев накопления (WNS-fix 06.10). NUM_MAC=16 сохранён.
module xdma_ddr3_core_top #(parameter int NUM_MAC = 16, parameter int ADDERS = 4)
   (DDR3_0_addr,
     DDR3_0_ba,
     DDR3_0_cas_n,
     DDR3_0_ck_n,
     DDR3_0_ck_p,
     DDR3_0_cke,
     DDR3_0_cs_n,
     DDR3_0_dm,
     DDR3_0_dq,
     DDR3_0_dqs_n,
     DDR3_0_dqs_p,
     DDR3_0_odt,
     DDR3_0_ras_n,
     DDR3_0_reset_n,
     DDR3_0_we_n,
     clk50,
     diff_clock_rtl_0_clk_n,
     diff_clock_rtl_0_clk_p,
     gpio_rtl_0_tri_o,
     pcie_7x_mgt_rtl_0_rxn,
     pcie_7x_mgt_rtl_0_rxp,
     pcie_7x_mgt_rtl_0_txn,
     pcie_7x_mgt_rtl_0_txp,
   reset_rtl_0);
  output [13:0]DDR3_0_addr;
  output [2:0]DDR3_0_ba;
  output DDR3_0_cas_n;
  output [0:0]DDR3_0_ck_n;
  output [0:0]DDR3_0_ck_p;
  output [0:0]DDR3_0_cke;
  output [0:0]DDR3_0_cs_n;
  output [1:0]DDR3_0_dm;
  inout [15:0]DDR3_0_dq;
  inout [1:0]DDR3_0_dqs_n;
  inout [1:0]DDR3_0_dqs_p;
  output [0:0]DDR3_0_odt;
  output DDR3_0_ras_n;
  output DDR3_0_reset_n;
  output DDR3_0_we_n;
  input [0:0]clk50;
  input [0:0]diff_clock_rtl_0_clk_n;
  input [0:0]diff_clock_rtl_0_clk_p;
  output [2:0]gpio_rtl_0_tri_o;
  input [3:0]pcie_7x_mgt_rtl_0_rxn;
  input [3:0]pcie_7x_mgt_rtl_0_rxp;
  output [3:0]pcie_7x_mgt_rtl_0_txn;
  output [3:0]pcie_7x_mgt_rtl_0_txp;
  input reset_rtl_0;

  // ---- Такт/сброс fabric-домена 125 МГц (BUG-034, BUG-036) ----
  // BD генерирует такт 125 МГц (clk125_core_wiz из clk50) и сброс
  // (rst_core_125M), экспортирует их через clk_core_out/core_resetn_out.
  // НЕ объявляем core_clk/core_resetn входными портами топа — иначе на сети
  // будет 2 драйвера (выход clk_wiz внутри BD + IBUF от input-порта) -> DRC
  // MDRV-1. (FLAT: без icap/u_icap — icap_clk группы больше нет.)
  logic core_clk;
  logic core_resetn;

  // ---- Такт/сброс PCIe-домена: экспортируются из BD (post_bd_flat.tcl) ----
  // BD выводит axi_aclk_out (xdma_0/axi_aclk) и axi_aresetn_out; используется
  // только PCIe-доменом (SmartConnect S-стороны). Периферия и ядро — в core_clk.
  logic axi_aclk;
  logic axi_aresetn;

  // ---- AXI-Lite от BD S_AXI_TDOT_REGS (хост через XDMA -> tdot_axi4) ----
  logic [31:0] s_axil_awaddr, s_axil_araddr;
  logic        s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata;
  logic [3:0]  s_axil_wstrb;
  logic        s_axil_wvalid, s_axil_wready;
  logic [1:0]  s_axil_bresp;
  logic        s_axil_bvalid, s_axil_bready;
  logic        s_axil_arvalid, s_axil_arready;
  logic [31:0] s_axil_rdata;
  logic [1:0]  s_axil_rresp;
  logic        s_axil_rvalid, s_axil_rready;

  // ---- AXI4-мастер tdot_axi4 -> BD M_AXI_TDOT ----
  logic [31:0] m_axi_awaddr, m_axi_araddr;
  logic [7:0]  m_axi_awlen, m_axi_arlen;
  logic [2:0]  m_axi_awsize, m_axi_arsize;
  logic [1:0]  m_axi_awburst, m_axi_arburst;
  logic        m_axi_awlock, m_axi_arlock;
  logic [3:0]  m_axi_awcache, m_axi_arcache;
  logic [2:0]  m_axi_awprot, m_axi_arprot;
  logic [3:0]  m_axi_awqos, m_axi_arqos;
  logic        m_axi_awvalid, m_axi_awready;
  logic [63:0] m_axi_wdata;
  logic [7:0]  m_axi_wstrb;
  logic        m_axi_wlast, m_axi_wvalid, m_axi_wready;
  logic        m_axi_bvalid, m_axi_bready;
  logic [1:0]  m_axi_bresp;
  logic        m_axi_arvalid, m_axi_arready;
  logic [63:0] m_axi_rdata;
  logic        m_axi_rvalid, m_axi_rready, m_axi_rlast;
  logic [1:0]  m_axi_rresp;

  // ---- IRQ планировщика TDOT: уровень из fabric 125 -> домен XDMA 125 ----
  // Уровень держится до irq_ack (миллисекунды) — 2-FF синхронизация достаточна;
  // дальше в BD: tdot_irq -> xdma_0/usr_irq_req (MSI-X вектор 0).
  logic tdot_irq_w;
  (* ASYNC_REG = "TRUE" *) logic [1:0] tdot_irq_sync;
  always_ff @(posedge axi_aclk or negedge axi_aresetn) begin
      if (!axi_aresetn) tdot_irq_sync <= 2'b00;
      else              tdot_irq_sync <= {tdot_irq_sync[0], tdot_irq_w};
  end

  // DIAG-статус tdot (2026-10-03): выведены из tdot_axi4 для diag сниффера.
  logic tdot_go_w, tdot_busy_w, tdot_done_w;

  tdot_axi4 #(.NUM_MAC(NUM_MAC), .ADDERS(ADDERS)) u_tdot (
      .S_AXI_ACLK(core_clk), .S_AXI_ARESETN(core_resetn),
      .S_AXI_AWADDR(s_axil_awaddr), .S_AXI_AWPROT(1'b0),
      .S_AXI_AWVALID(s_axil_awvalid), .S_AXI_AWREADY(s_axil_awready),
      .S_AXI_WDATA(s_axil_wdata), .S_AXI_WSTRB(s_axil_wstrb),
      .S_AXI_WVALID(s_axil_wvalid), .S_AXI_WREADY(s_axil_wready),
      .S_AXI_BRESP(s_axil_bresp), .S_AXI_BVALID(s_axil_bvalid), .S_AXI_BREADY(s_axil_bready),
      .S_AXI_ARADDR(s_axil_araddr), .S_AXI_ARPROT(1'b0),
      .S_AXI_ARVALID(s_axil_arvalid), .S_AXI_ARREADY(s_axil_arready),
      .S_AXI_RDATA(s_axil_rdata), .S_AXI_RRESP(s_axil_rresp),
      .S_AXI_RVALID(s_axil_rvalid), .S_AXI_RREADY(s_axil_rready),
      .M_AXI_ACLK(core_clk), .M_AXI_ARESETN(core_resetn),
      .M_AXI_AWID(), .M_AXI_AWADDR(m_axi_awaddr), .M_AXI_AWLEN(m_axi_awlen),
      .M_AXI_AWSIZE(m_axi_awsize), .M_AXI_AWBURST(m_axi_awburst),
      .M_AXI_AWLOCK(m_axi_awlock), .M_AXI_AWCACHE(m_axi_awcache),
      .M_AXI_AWPROT(m_axi_awprot), .M_AXI_AWQOS(m_axi_awqos),
      .M_AXI_AWVALID(m_axi_awvalid), .M_AXI_AWREADY(m_axi_awready),
      .M_AXI_WDATA(m_axi_wdata), .M_AXI_WSTRB(m_axi_wstrb),
      .M_AXI_WLAST(m_axi_wlast), .M_AXI_WVALID(m_axi_wvalid), .M_AXI_WREADY(m_axi_wready),
      .M_AXI_BID(), .M_AXI_BRESP(m_axi_bresp),
      .M_AXI_BVALID(m_axi_bvalid), .M_AXI_BREADY(m_axi_bready),
      .M_AXI_ARID(), .M_AXI_ARADDR(m_axi_araddr), .M_AXI_ARLEN(m_axi_arlen),
      .M_AXI_ARSIZE(m_axi_arsize), .M_AXI_ARBURST(m_axi_arburst),
      .M_AXI_ARLOCK(m_axi_arlock), .M_AXI_ARCACHE(m_axi_arcache),
      .M_AXI_ARPROT(m_axi_arprot), .M_AXI_ARQOS(m_axi_arqos),
      .M_AXI_ARVALID(m_axi_arvalid), .M_AXI_ARREADY(m_axi_arready),
      .M_AXI_RID(), .M_AXI_RDATA(m_axi_rdata), .M_AXI_RRESP(m_axi_rresp),
      .M_AXI_RLAST(m_axi_rlast), .M_AXI_RVALID(m_axi_rvalid), .M_AXI_RREADY(m_axi_rready),
      .sched_irq(tdot_irq_w),
      .diag_go(tdot_go_w), .diag_busy(tdot_busy_w), .diag_done(tdot_done_w)
  );

  // ======================== XADC (температура/напряжение, база 0x46000000) ========================
  // FIX-5 RTL-1: инстанцируем xadc_temp.sv, чтобы BD-порт S_AXI_XADC_REGS
  // (M03 @ 0x46000000) был подключён к реальному AXI-Lite slave.
  // BUG-031: Artix-7 имеет только 1 XADC. MIG отключил XADC (XADC_En=Off),
  // xadc_wiz НЕ создаётся; xadc_prim (ниже) подаёт реальные raw_temp/raw_vccint.
  logic [7:0]  xadc_awaddr, xadc_araddr;
  logic        xadc_awvalid, xadc_awready;
  logic [31:0] xadc_wdata;
  logic [3:0]  xadc_wstrb;
  logic        xadc_wvalid, xadc_wready;
  logic        xadc_bvalid, xadc_bready;
  logic        xadc_arvalid, xadc_arready;
  logic [31:0] xadc_rdata;
  logic        xadc_rvalid, xadc_rready;
  logic [1:0]  xadc_bresp, xadc_rresp;

  logic [15:0] xadc_raw_temp;
  logic [15:0] xadc_raw_vccint;
  logic        xadc_raw_valid;

  xadc_temp u_xadc (
      .S_AXI_ACLK(core_clk), .S_AXI_ARESETN(core_resetn),
      .S_AXI_AWADDR(xadc_awaddr), .S_AXI_AWPROT(1'b0),
      .S_AXI_AWVALID(xadc_awvalid), .S_AXI_AWREADY(xadc_awready),
      .S_AXI_WDATA(xadc_wdata), .S_AXI_WSTRB(xadc_wstrb),
      .S_AXI_WVALID(xadc_wvalid), .S_AXI_WREADY(xadc_wready),
      .S_AXI_BRESP(xadc_bresp), .S_AXI_BVALID(xadc_bvalid), .S_AXI_BREADY(xadc_bready),
      .S_AXI_ARADDR(xadc_araddr), .S_AXI_ARPROT(1'b0),
      .S_AXI_ARVALID(xadc_arvalid), .S_AXI_ARREADY(xadc_arready),
      .S_AXI_RDATA(xadc_rdata), .S_AXI_RRESP(xadc_rresp),
      .S_AXI_RVALID(xadc_rvalid), .S_AXI_RREADY(xadc_rready),
      // BUG-031 RTL-fix: xadc_prim подаёт реальные raw_temp/raw_vccint/raw_valid
      .raw_temp(xadc_raw_temp), .raw_vccint(xadc_raw_vccint), .raw_valid(xadc_raw_valid)
  );

  // ---- XADC primitive: реальный мониторинг температуры/VCCINT (BUG-031 fix) ----
  // xadc_prim = DRP-FSM вокруг примитива XADC: раз в секунду читает DADDR 0x00
  // (temp) и 0x06 (VCCINT). Тактируется clk50 (DCLK), сброс — fabric core_resetn.
  xadc_prim u_xadc_prim (
      .clk       (clk50[0]),
      .rst_n     (core_resetn),
      .raw_temp  (xadc_raw_temp),
      .raw_vccint(xadc_raw_vccint),
      .raw_valid (xadc_raw_valid)
  );

  // ======================== BD (FLAT, no-DFX variant) ========================
  // BD wrapper: xdma_ddr3_dfx (from xdma_ddr3_dfx.bd, FLAT)
  // Включает XDMA, MIG, inlined DataMover MM2S/S2MM + ctrl, GPIO, clk wizards.
  // БЕЗ icap_ctrl (S_AXI_ICAP_REGS убран) и БЕЗ SPI-over-PCIe (S_AXI_SPI_REGS
  // убран). icap_ctrl.sv остаётся в дереве как неиспользуемый файл.
  xdma_ddr3_dfx xdma_ddr3_dfx_i (
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
      .axi_aclk_out(axi_aclk),       // экспорт xdma_0/axi_aclk из BD (125 МГц, 128-бит)
      .axi_aresetn_out(axi_aresetn), // экспорт xdma_0/axi_aresetn из BD
      .axi_aclk_in(axi_aclk),        // loopback: та же цепь, что axi_aclk_out
      .tdot_irq(tdot_irq_sync[1]),   // IRQ планировщика (синхр. в 125, -> usr_irq_req)
      .clk_core_out(core_clk),       // 125 МГц fabric/ядро (BUG-034, clk125_core_wiz)
      .core_resetn_out(core_resetn), // сброс fabric-домена (rst_core_125M)
      .diff_clock_rtl_0_clk_n(diff_clock_rtl_0_clk_n),
      .diff_clock_rtl_0_clk_p(diff_clock_rtl_0_clk_p),
      .clk50(clk50),
      .gpio_rtl_0_tri_o(gpio_rtl_0_tri_o),
      .M_AXI_TDOT_awaddr(m_axi_awaddr), .M_AXI_TDOT_awlen(m_axi_awlen),
      .M_AXI_TDOT_awsize(m_axi_awsize), .M_AXI_TDOT_awburst(m_axi_awburst),
      .M_AXI_TDOT_awlock(m_axi_awlock), .M_AXI_TDOT_awcache(m_axi_awcache),
      .M_AXI_TDOT_awprot(m_axi_awprot), .M_AXI_TDOT_awqos(m_axi_awqos),
      .M_AXI_TDOT_awvalid(m_axi_awvalid), .M_AXI_TDOT_awready(m_axi_awready),
      .M_AXI_TDOT_wdata(m_axi_wdata), .M_AXI_TDOT_wstrb(m_axi_wstrb),
      .M_AXI_TDOT_wlast(m_axi_wlast), .M_AXI_TDOT_wvalid(m_axi_wvalid),
      .M_AXI_TDOT_wready(m_axi_wready),
      .M_AXI_TDOT_bresp(m_axi_bresp), .M_AXI_TDOT_bvalid(m_axi_bvalid),
      .M_AXI_TDOT_bready(m_axi_bready),
      .M_AXI_TDOT_araddr(m_axi_araddr), .M_AXI_TDOT_arlen(m_axi_arlen),
      .M_AXI_TDOT_arsize(m_axi_arsize), .M_AXI_TDOT_arburst(m_axi_arburst),
      .M_AXI_TDOT_arlock(m_axi_arlock), .M_AXI_TDOT_arcache(m_axi_arcache),
      .M_AXI_TDOT_arprot(m_axi_arprot), .M_AXI_TDOT_arqos(m_axi_arqos),
      .M_AXI_TDOT_arvalid(m_axi_arvalid), .M_AXI_TDOT_arready(m_axi_arready),
      .M_AXI_TDOT_rdata(m_axi_rdata), .M_AXI_TDOT_rresp(m_axi_rresp),
      .M_AXI_TDOT_rlast(m_axi_rlast), .M_AXI_TDOT_rvalid(m_axi_rvalid),
      .M_AXI_TDOT_rready(m_axi_rready),
      .S_AXI_TDOT_REGS_awaddr(s_axil_awaddr), .S_AXI_TDOT_REGS_awprot(1'b0),
      .S_AXI_TDOT_REGS_awvalid(s_axil_awvalid), .S_AXI_TDOT_REGS_awready(s_axil_awready),
      .S_AXI_TDOT_REGS_wdata(s_axil_wdata), .S_AXI_TDOT_REGS_wstrb(s_axil_wstrb),
      .S_AXI_TDOT_REGS_wvalid(s_axil_wvalid), .S_AXI_TDOT_REGS_wready(s_axil_wready),
      .S_AXI_TDOT_REGS_bresp(s_axil_bresp), .S_AXI_TDOT_REGS_bvalid(s_axil_bvalid),
      .S_AXI_TDOT_REGS_bready(s_axil_bready),
      .S_AXI_TDOT_REGS_araddr(s_axil_araddr), .S_AXI_TDOT_REGS_arprot(1'b0),
      .S_AXI_TDOT_REGS_arvalid(s_axil_arvalid), .S_AXI_TDOT_REGS_arready(s_axil_arready),
      .S_AXI_TDOT_REGS_rdata(s_axil_rdata), .S_AXI_TDOT_REGS_rresp(s_axil_rresp),
      .S_AXI_TDOT_REGS_rvalid(s_axil_rvalid), .S_AXI_TDOT_REGS_rready(s_axil_rready),
      // FIX-5 RTL-1: S_AXI_XADC_REGS подключён к u_xadc. Канонический адрес 0x46000000.
      .S_AXI_XADC_REGS_awaddr(xadc_awaddr), .S_AXI_XADC_REGS_awprot(1'b0),
      .S_AXI_XADC_REGS_awvalid(xadc_awvalid), .S_AXI_XADC_REGS_awready(xadc_awready),
      .S_AXI_XADC_REGS_wdata(xadc_wdata), .S_AXI_XADC_REGS_wstrb(xadc_wstrb),
      .S_AXI_XADC_REGS_wvalid(xadc_wvalid), .S_AXI_XADC_REGS_wready(xadc_wready),
      .S_AXI_XADC_REGS_bresp(xadc_bresp), .S_AXI_XADC_REGS_bvalid(xadc_bvalid),
      .S_AXI_XADC_REGS_bready(xadc_bready),
      .S_AXI_XADC_REGS_araddr(xadc_araddr), .S_AXI_XADC_REGS_arprot(1'b0),
      .S_AXI_XADC_REGS_arvalid(xadc_arvalid), .S_AXI_XADC_REGS_arready(xadc_arready),
      .S_AXI_XADC_REGS_rdata(xadc_rdata), .S_AXI_XADC_REGS_rresp(xadc_rresp),
      .S_AXI_XADC_REGS_rvalid(xadc_rvalid), .S_AXI_XADC_REGS_rready(xadc_rready),
      .pcie_7x_mgt_rtl_0_rxn(pcie_7x_mgt_rtl_0_rxn),
      .pcie_7x_mgt_rtl_0_rxp(pcie_7x_mgt_rtl_0_rxp),
      .pcie_7x_mgt_rtl_0_txn(pcie_7x_mgt_rtl_0_txn),
      .pcie_7x_mgt_rtl_0_txp(pcie_7x_mgt_rtl_0_txp),
      .reset_rtl_0(reset_rtl_0));

  // ======================== DIAG (2026-10-03): сниффер пути ядро->DDR3 ========================
  // Наблюдает мастер-шину tdot_axi4 (m_axi_* = путь TDOT->xdma_axi_smc->MIG) и статусы
  // ядра. Даёт счётчики транзакций read/write, RRESP/BRESP!=OKAY, stall-таймаут и
  // BRAM-реестр сравнения "ожидал/получил" — без вмешательства в шину.
  // NOTE: сниффер включён только в тестовую/диагностическую сборку; для продакшена
  // этот блок можно удалить или выключить константой DIAG_EN.
  localparam int DIAG_EN = 1;
  generate
  if (DIAG_EN) begin : g_diag
    diag_axi_sniffer #(
      .C_S_AXI_ADDR_WIDTH(8),
      .C_S_AXI_DATA_WIDTH(32),
      .AW(32)
    ) u_diag (
      .clk(core_clk), .rst_n(core_resetn),
      // AXI-Lite watch port не подключён в DFX-варианте (нет свободного M_AXI_LITE).
      // Сниффер пока работает как watch-only + сравнение; чтение реестра хостом
      // станет доступно после выделения S_AXI_DIAG порта в BD (см. план внедрения).
      .s_axi_awvalid(1'b0), .s_axi_awaddr('0), .s_axi_awready(),
      .s_axi_wvalid(1'b0), .s_axi_wdata('0), .s_axi_wready(),
      .s_axi_bvalid(), .s_axi_bready(1'b0),
      .s_axi_arvalid(1'b0), .s_axi_araddr('0), .s_axi_arready(),
      .s_axi_rvalid(), .s_axi_rdata(), .s_axi_rready(1'b0),
      // мастер-шина tdot (путь к DDR3/MIG)
      .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
      .m_axi_awaddr(m_axi_awaddr),
      .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready), .m_axi_wlast(m_axi_wlast),
      .m_axi_bvalid(m_axi_bvalid), .m_axi_bresp(m_axi_bresp), .m_axi_bready(m_axi_bready),
      .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
      .m_axi_araddr(m_axi_araddr),
      .m_axi_rvalid(m_axi_rvalid), .m_axi_rlast(m_axi_rlast),
      .m_axi_rresp(m_axi_rresp), .m_axi_rready(m_axi_rready),
      // статусы ядра
      .tdot_go(tdot_go_w), .tdot_busy(tdot_busy_w), .tdot_done(tdot_done_w),
      // DDR3 статус не выведен в RTL-top (MIG внутри BD) — заглушка 0
      .mig_init_calib_complete(1'b0), .mig_mmcm_locked(1'b0)
    );
  end
  endgenerate
endmodule