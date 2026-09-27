module xdma_ddr3_core_top #(parameter int NUM_MAC = 32, parameter int ADDERS = 8)
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
   reset_rtl_0,
   qspi_cs_n,
   qspi_d0,
   qspi_d1,
   qspi_d2,
   qspi_d3);
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
  output qspi_cs_n;
  inout  qspi_d0;
  inout  qspi_d1;
  inout  qspi_d2;
  inout  qspi_d3;

  // ---- Такт/сброс fabric-домена 125 МГц (BUG-034, BUG-036) ----
  // XDMA в 64-битном варианте (Gen2 x4) тактирует axi_aclk частотой 250 МГц.
  // Тернарное ядро (tfmul_raw: 40-тритовая последовательная цепочка сложения)
  // и RP (DataMover 128 бит) закрывают тайминг только при 125 МГц.
  // BD генерирует такт 125 МГц (clk125_core_wiz из clk50) и сброс (rst_core_125M),
  // экспортирует их через clk_core_out/core_resetn_out. НЕ объявляем core_clk/
  // core_resetn входными портами топа — иначе на сети будет 2 драйвера
  // (выход clk125_core_wiz внутри BD + IBUF от input-порта) → DRC MDRV-1.
  logic core_clk;
  logic core_resetn;

  // ---- Такт/сброс PCIe-домена: экспортируются из BD (post_bd_dfx.tcl:step 5) ----
  // BD выводит axi_aclk_out (xdma_0/axi_aclk, 250 МГц в 64-битном варианте)
  // и axi_aresetn_out (xdma_0/axi_aresetn); используется только
  // PCIe-доменом (SmartConnect S-стороны). Периферия и ядро — в core_clk.
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

  // ---- IRQ планировщика TDOT: уровень из fabric 125 -> домен XDMA 250 ----
  // Уровень держится до irq_ack (миллисекунды) — 2-FF синхронизация достаточна;
  // дальше в BD: tdot_irq -> xlconcat -> xdma_0/usr_irq_req (MSI-X вектор).
  logic tdot_irq_w;
  (* ASYNC_REG = "TRUE" *) logic [1:0] tdot_irq_sync;
  always_ff @(posedge axi_aclk or negedge axi_aresetn) begin
      if (!axi_aresetn) tdot_irq_sync <= 2'b00;
      else              tdot_irq_sync <= {tdot_irq_sync[0], tdot_irq_w};
  end

  tdot_axi4 #(.NUM_MAC(NUM_MAC), .ADDERS(ADDERS)) u_tdot (
      .S_AXI_ACLK(core_clk), .S_AXI_ARESETN(core_resetn),
      .S_AXI_AWADDR(s_axil_awaddr), .S_AXI_AWPROT(1'b0),
      .S_AXI_AWVALID(s_axil_awvalid), .S_AXI_AWREADY(s_axil_awready),
      .S_AXI_WDATA(s_axil_wdata), .S_AXI_WSTRB(s_axil_wstrb),
      .S_AXI_WVALID(s_axil_wvalid), .S_AXI_WREADY(s_axil_wready),
      .S_AXI_BRESP(), .S_AXI_BVALID(s_axil_bvalid), .S_AXI_BREADY(s_axil_bready),
      .S_AXI_ARADDR(s_axil_araddr), .S_AXI_ARPROT(1'b0),
      .S_AXI_ARVALID(s_axil_arvalid), .S_AXI_ARREADY(s_axil_arready),
      .S_AXI_RDATA(s_axil_rdata), .S_AXI_RRESP(),
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
      .sched_irq(tdot_irq_w)
  );

  // ======================== ICAP (перезагрузка на лету через AXI-Lite) ========================
  logic [7:0]  icap_awaddr, icap_araddr;
  logic        icap_awvalid, icap_awready;
  logic [31:0] icap_wdata;
  logic [3:0]  icap_wstrb;
  logic        icap_wvalid, icap_wready;
  logic        icap_bvalid, icap_bready;
  logic        icap_arvalid, icap_arready;
  logic [31:0] icap_rdata;
  logic        icap_rvalid, icap_rready;
  logic [1:0]  icap_bresp;
  logic [1:0]  icap_rresp;

  // ---- SPI-over-PCIe (R-14): AXI-Lite @ 0x40005000 ----
  logic [7:0]  spi_awaddr, spi_araddr;
  logic        spi_awvalid, spi_awready;
  logic [31:0] spi_wdata;
  logic [3:0]  spi_wstrb;
  logic        spi_wvalid, spi_wready;
  logic        spi_bvalid, spi_bready;
  logic        spi_arvalid, spi_arready;
  logic [31:0] spi_rdata;
  logic        spi_rvalid, spi_rready;
  logic [1:0]  spi_bresp;
  logic [1:0]  spi_rresp;

  icap_ctrl u_icap (
      .S_AXI_ACLK(core_clk), .S_AXI_ARESETN(core_resetn),
      .S_AXI_AWADDR(icap_awaddr), .S_AXI_AWPROT(1'b0),
      .S_AXI_AWVALID(icap_awvalid), .S_AXI_AWREADY(icap_awready),
      .S_AXI_WDATA(icap_wdata), .S_AXI_WSTRB(icap_wstrb),
      .S_AXI_WVALID(icap_wvalid), .S_AXI_WREADY(icap_wready),
      .S_AXI_BRESP(), .S_AXI_BVALID(icap_bvalid), .S_AXI_BREADY(icap_bready),
      .S_AXI_ARADDR(icap_araddr), .S_AXI_ARPROT(1'b0),
      .S_AXI_ARVALID(icap_arvalid), .S_AXI_ARREADY(icap_arready),
      .S_AXI_RDATA(icap_rdata), .S_AXI_RRESP(),
      .S_AXI_RVALID(icap_rvalid), .S_AXI_RREADY(icap_rready)
  );

  // ======================== SPI-over-PCIe (R-14, hot-flash without JTAG) ====================
  spi_over_pcie #(.CLK_DIV(16)) u_spi (
      .S_AXI_ACLK(core_clk), .S_AXI_ARESETN(core_resetn),
      .S_AXI_AWADDR(spi_awaddr), .S_AXI_AWVALID(spi_awvalid), .S_AXI_AWREADY(spi_awready),
      .S_AXI_WDATA(spi_wdata), .S_AXI_WSTRB(spi_wstrb),
      .S_AXI_WVALID(spi_wvalid), .S_AXI_WREADY(spi_wready),
      .S_AXI_BRESP(spi_bresp), .S_AXI_BVALID(spi_bvalid), .S_AXI_BREADY(spi_bready),
      .S_AXI_ARADDR(spi_araddr), .S_AXI_ARVALID(spi_arvalid), .S_AXI_ARREADY(spi_arready),
      .S_AXI_RDATA(spi_rdata), .S_AXI_RRESP(spi_rresp),
      .S_AXI_RVALID(spi_rvalid), .S_AXI_RREADY(spi_rready),
      .spi_cclk(), .qspi_cs_n(qspi_cs_n),
      .qspi_d0(qspi_d0), .qspi_d1(qspi_d1), .qspi_d2(qspi_d2), .qspi_d3(qspi_d3)
  );

  // ======================== XADC (температура/напряжение, база 0x46000000) ========================
  // FIX-5 RTL-1: инстанцируем xadc_temp.sv, чтобы BD-порт S_AXI_XADC_REGS (создаваемый
  // scripts/post_bd_dfx.tcl на M05 @ 0x46000000) был подключён к реальному
  // AXI-Lite slave. Без этого wrapper-порт остаётся floating, monitor_temp.py
  // получает decoder error / undefined. Соответствует ANALYSIS_AND_SPEC_FIX.md B-5.
  //
  // BUG-031: Artix-7 имеет только 1 XADC. MIG 7-series IP в DFX-варианте
  // отключил XADC (XADC_En=Off в xdma_ddr3_dfx_bd.tcl:199 — отключён ради
  // избежания UTLZ-1). xadc_wiz IP НЕ создаётся (создал бы 2-й виртуальный
  // XADC → UTLZ-1). raw_temp/raw_vccint/raw_valid = 0 — monitor_temp.py
  // читает 0°C / 0V. См. BUG-031, scripts/post_bd_dfx.tcl блок 4c.
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

  // BUG-031 RTL-fix: xadc_prim (ниже) подаёт реальные данные температуры/VCCINT.
  // MIG 7-series IP в DFX-варианте: XADC_En=Off (см. xdma_ddr3_dfx_bd.tcl:199) —
  // физический XADC свободен, примитив один (UTLZ-1 не возникает). monitor_temp.py
  // читает реальные 0x46000000 TEMP/VCCINT/VALID.

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
      // BUG-031 RTL-fix: xadc_prim (примитив XADC через DRP) подаёт реальные
      // raw_temp/raw_vccint/raw_valid. MIG сконфигурирован XADC_En=Off — физический
      // XADC свободен, примитив один, UTLZ-1 не возникает.
      .raw_temp(xadc_raw_temp), .raw_vccint(xadc_raw_vccint), .raw_valid(xadc_raw_valid)
  );

  // ---- XADC primitive: реальный мониторинг температуры/VCCINT (BUG-031 fix) ----
  // xadc_prim = DRP-FSM вокруг примитива XADC (xadc_prim.sv): раз в секунду
  // читает DADDR 0x00 (temp) и 0x06 (VCCINT), подаёт raw_temp/raw_vccint/raw_valid
  // в xadc_temp. Тактирование — clk50 (50 МГц, в спецификации XADC DCLK 8..250 МГц;
  // см. шапку xadc_prim.sv: DCLK=clk50), сброс — fabric-домен core_resetn (clk50 —
  // источник core_clk, так что reset согласован с DCLK). AXI-Lite интерфейс u_xadc
  // не тронут: host-тесты register access работают как раньше.
  logic [15:0] xadc_raw_temp;
  logic [15:0] xadc_raw_vccint;
  logic        xadc_raw_valid;

  xadc_prim u_xadc_prim (
      .clk       (clk50[0]),
      .rst_n     (core_resetn),
      .raw_temp  (xadc_raw_temp),
      .raw_vccint(xadc_raw_vccint),
      .raw_valid (xadc_raw_valid)
  );

  // ======================== BD (DFX variant) ========================
  // BD wrapper: xdma_ddr3_dfx_wrapper (from xdma_ddr3_dfx.bd)
  // Включает XDMA, MIG, HWICAP, DFX Socket, DFX Partition
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
      .axi_aclk_out(axi_aclk),      // экспорт xdma_0/axi_aclk из BD (250 МГц, 64-бит)
      .axi_aresetn_out(axi_aresetn),// экспорт xdma_0/axi_aresetn из BD
      .axi_aclk_in(axi_aclk),       // loopback: та же цепь, что axi_aclk_out
      .tdot_irq(tdot_irq_sync[1]),  // IRQ планировщика (синхр. в 250, -> usr_irq_req)
      .clk_core_out(core_clk),      // 125 МГц fabric/ядро (BUG-034, clk125_core_wiz)
      .core_resetn_out(core_resetn),// сброс fabric-домена (rst_core_125M)
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
      .S_AXI_ICAP_REGS_awaddr(icap_awaddr), .S_AXI_ICAP_REGS_awprot(1'b0),
      .S_AXI_ICAP_REGS_awvalid(icap_awvalid), .S_AXI_ICAP_REGS_awready(icap_awready),
      .S_AXI_ICAP_REGS_wdata(icap_wdata), .S_AXI_ICAP_REGS_wstrb(icap_wstrb),
      .S_AXI_ICAP_REGS_wvalid(icap_wvalid), .S_AXI_ICAP_REGS_wready(icap_wready),
      .S_AXI_ICAP_REGS_bresp(icap_bresp), .S_AXI_ICAP_REGS_bvalid(icap_bvalid),
      .S_AXI_ICAP_REGS_bready(icap_bready),
      .S_AXI_ICAP_REGS_araddr(icap_araddr), .S_AXI_ICAP_REGS_arprot(1'b0),
      .S_AXI_ICAP_REGS_arvalid(icap_arvalid), .S_AXI_ICAP_REGS_arready(icap_arready),
      .S_AXI_ICAP_REGS_rdata(icap_rdata), .S_AXI_ICAP_REGS_rresp(icap_rresp),
      .S_AXI_ICAP_REGS_rvalid(icap_rvalid), .S_AXI_ICAP_REGS_rready(icap_rready),
      // FIX-5 RTL-1: S_AXI_XADC_REGS подключается к u_xadc (раньше floating).
      // Канонический адрес 0x46000000 (см. docs/ADDRESS_MAP.md §2.1, resize_bar0.tcl).
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
      // ---- SPI-over-PCIe regs (R-14, M06 @ 0x40005000) ----
      .S_AXI_SPI_REGS_awaddr(spi_awaddr), .S_AXI_SPI_REGS_awprot(1'b0),
      .S_AXI_SPI_REGS_awvalid(spi_awvalid), .S_AXI_SPI_REGS_awready(spi_awready),
      .S_AXI_SPI_REGS_wdata(spi_wdata), .S_AXI_SPI_REGS_wstrb(spi_wstrb),
      .S_AXI_SPI_REGS_wvalid(spi_wvalid), .S_AXI_SPI_REGS_wready(spi_wready),
      .S_AXI_SPI_REGS_bresp(spi_bresp), .S_AXI_SPI_REGS_bvalid(spi_bvalid),
      .S_AXI_SPI_REGS_bready(spi_bready),
      .S_AXI_SPI_REGS_araddr(spi_araddr), .S_AXI_SPI_REGS_arprot(1'b0),
      .S_AXI_SPI_REGS_arvalid(spi_arvalid), .S_AXI_SPI_REGS_arready(spi_arready),
      .S_AXI_SPI_REGS_rdata(spi_rdata), .S_AXI_SPI_REGS_rresp(spi_rresp),
      .S_AXI_SPI_REGS_rvalid(spi_rvalid), .S_AXI_SPI_REGS_rready(spi_rready),
      // legacy-порт M_AXI_ICAP очищается в scripts/post_bd_dfx.tcl step 6.
      // Если warning в impl остаётся — запустить make_wrapper -force.
      .pcie_7x_mgt_rtl_0_rxn(pcie_7x_mgt_rtl_0_rxn),
      .pcie_7x_mgt_rtl_0_rxp(pcie_7x_mgt_rtl_0_rxp),
      .pcie_7x_mgt_rtl_0_txn(pcie_7x_mgt_rtl_0_txn),
      .pcie_7x_mgt_rtl_0_txp(pcie_7x_mgt_rtl_0_txp),
      .reset_rtl_0(reset_rtl_0));
endmodule
