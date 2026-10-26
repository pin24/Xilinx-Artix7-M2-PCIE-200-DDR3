// ============================================================================
// tb_tdot_sched_hang.sv — ПОЛНАЯ эмуляция платы: весь tdot_axi4 (ядро + AXI4-мастер +
// кольцо планировщика с дескрипторами и завершениями в памяти) + AXI/DDR-модель.
// Цель — детерминированно воспроизвести зависание, которое в реальности даёт
// TdotScheduler.dot_batch (drivers xdma_driver.py): плата обрабатывает часть
// задач кольца (17/60, 65/192), потом RPTR замирает навсегда (STATUS=0x0).
//
// В отличие от tb_tdot_dot_hang.sv (изолированное ядро, прямое питание data/weights)
// здесь всё идёт как на железе: хост пишет дескрипторы в память, ставит SCHED_WPTR,
// включает sched_en, ПЛОНИРОВЩИК сам читает data/weights из DDR через AXI, считает
// dot и пишет завершения в кольцо; хост-часть опрашивает SCHED_RPTR.
//
// Источник реальных данных: vec64.dat / w64.dat (64-бит слова, младшие 48 бит =
// TFloat48), генерит make_tdot_vectors.py из весов модели. Кладёт их в память:
//   data[·]   byte 0x0000_0000
//   weights[·] byte 0x0002_0000 (128KB)
//   (для каждого вектора NUM_MAC слов)
// Схема пакета (NJOBS колец по одному на вектор):
//   ring[j].data_addr    = base_data + j*N*8
//   ring[j].weights_addr = base_weights + j*N*8
//   ring[j].result_addr  = base_result + j*8
//   ring[j].{n_total, tag} = {N, j}
//   где N — длина задачи (реальная: иногда 32, иногда 40 long-dot, иногда 16)
// Завершения пишутся в comp_ring по rptr*16; хост ждёт rptr==NJOBS.
//
// Watchdog: если SCHED_RPTR не сдвинулся за WATCHDOG тактов — печатает HANG и
// дампит внутренности (cstate/rstate/rd_* /sched_* /u_core.t_lvl,t_cnt,collected,
// rnd_issue,tree_can / u_acc.u_add.phase) и завершается ошибкой. Иначе PASS.
// ============================================================================
`include "sim_cfg.svh"

module tb_tdot_sched_hang;
  parameter int NUM_MAC = `SIM_NUM_MAC;
  parameter int ADDERS  = `SIM_ADDERS;
  parameter int NJOBS    = 250;                       // задач в пакете (как dot_batch CH)
  parameter longint WATCHDOG = 300000;                // тактов без прогресса RPTR = HANG
  parameter int N_PER_JOB = 32;                       // слов на задачу (по объёму вектора)
  parameter int LONG_EN   = `SIM_LONG;                // 1 = смесь длин (вкл. long-dot), 0 = только single-pass

  logic clk=0, rst_n=0;
  always #5 clk = ~clk;                               // 100 МГц

  // ---- AXI-Lite (host) ----
  logic [7:0]  S_AXI_AWADDR, S_AXI_ARADDR;
  logic        S_AXI_AWVALID, S_AXI_WVALID, S_AXI_BREADY, S_AXI_ARVALID, S_AXI_RREADY;
  logic [31:0] S_AXI_WDATA;
  logic [3:0]  S_AXI_WSTRB;
  logic        S_AXI_AWREADY, S_AXI_WREADY, S_AXI_BVALID, S_AXI_ARREADY, S_AXI_RVALID;
  logic [31:0] S_AXI_RDATA;
  // ---- AXI4 master <-> память ----
  logic [0:0]  M_AXI_AWID, M_AXI_ARID;
  logic [31:0] M_AXI_AWADDR, M_AXI_ARADDR;
  logic [7:0]  M_AXI_AWLEN, M_AXI_ARLEN;
  logic [2:0]  M_AXI_AWSIZE, M_AXI_ARSIZE;
  logic [1:0]  M_AXI_AWBURST, M_AXI_ARBURST;
  logic        M_AXI_AWLOCK, M_AXI_ARLOCK;
  logic [3:0]  M_AXI_AWCACHE, M_AXI_ARCACHE;
  logic [2:0]  M_AXI_AWPROT, M_AXI_ARPROT;
  logic [3:0]  M_AXI_AWQOS, M_AXI_ARQOS;
  logic        M_AXI_AWVALID, M_AXI_ARVALID, M_AXI_AWREADY, M_AXI_ARREADY;
  logic [63:0] M_AXI_WDATA;
  logic [7:0]  M_AXI_WSTRB;
  logic        M_AXI_WLAST, M_AXI_WVALID, M_AXI_WREADY;
  logic [1:0]  M_AXI_BRESP, M_AXI_RRESP;
  logic [0:0]  M_AXI_RID;
  logic        M_AXI_BVALID, M_AXI_BREADY, M_AXI_RVALID, M_AXI_RREADY, M_AXI_RLAST;
  wire  [63:0] M_AXI_RDATA;               // ведётся непрерывным assign из модели памяти
  logic        sched_irq;

  tdot_axi4 #(.NUM_MAC(NUM_MAC), .ADDERS(ADDERS), .BURST_RD_LEN(16), .BURST_WR_LEN(8)) dut (
    .S_AXI_ACLK(clk), .S_AXI_ARESETN(rst_n),
    .S_AXI_AWADDR(S_AXI_AWADDR), .S_AXI_AWPROT(1'b0), .S_AXI_AWVALID(S_AXI_AWVALID), .S_AXI_AWREADY(S_AXI_AWREADY),
    .S_AXI_WDATA(S_AXI_WDATA), .S_AXI_WSTRB(S_AXI_WSTRB), .S_AXI_WVALID(S_AXI_WVALID), .S_AXI_WREADY(S_AXI_WREADY),
    .S_AXI_BRESP(), .S_AXI_BVALID(S_AXI_BVALID), .S_AXI_BREADY(S_AXI_BREADY),
    .S_AXI_ARADDR(S_AXI_ARADDR), .S_AXI_ARPROT(1'b0), .S_AXI_ARVALID(S_AXI_ARVALID), .S_AXI_ARREADY(S_AXI_ARREADY),
    .S_AXI_RDATA(S_AXI_RDATA), .S_AXI_RRESP(), .S_AXI_RVALID(S_AXI_RVALID), .S_AXI_RREADY(S_AXI_RREADY),
    .M_AXI_ACLK(clk), .M_AXI_ARESETN(rst_n),
    .M_AXI_AWID(M_AXI_AWID), .M_AXI_AWADDR(M_AXI_AWADDR), .M_AXI_AWLEN(M_AXI_AWLEN),
    .M_AXI_AWSIZE(M_AXI_AWSIZE), .M_AXI_AWBURST(M_AXI_AWBURST),
    .M_AXI_AWLOCK(M_AXI_AWLOCK), .M_AXI_AWCACHE(M_AXI_AWCACHE),
    .M_AXI_AWPROT(M_AXI_AWPROT), .M_AXI_AWQOS(M_AXI_AWQOS),
    .M_AXI_AWVALID(M_AXI_AWVALID), .M_AXI_AWREADY(M_AXI_AWREADY),
    .M_AXI_WDATA(M_AXI_WDATA), .M_AXI_WSTRB(M_AXI_WSTRB),
    .M_AXI_WLAST(M_AXI_WLAST), .M_AXI_WVALID(M_AXI_WVALID), .M_AXI_WREADY(M_AXI_WREADY),
    .M_AXI_BID(M_AXI_AWID), .M_AXI_BRESP(M_AXI_BRESP), .M_AXI_BVALID(M_AXI_BVALID), .M_AXI_BREADY(M_AXI_BREADY),
    .M_AXI_ARID(M_AXI_ARID), .M_AXI_ARADDR(M_AXI_ARADDR), .M_AXI_ARLEN(M_AXI_ARLEN),
    .M_AXI_ARSIZE(M_AXI_ARSIZE), .M_AXI_ARBURST(M_AXI_ARBURST),
    .M_AXI_ARLOCK(M_AXI_ARLOCK), .M_AXI_ARCACHE(M_AXI_ARCACHE),
    .M_AXI_ARPROT(M_AXI_ARPROT), .M_AXI_ARQOS(M_AXI_ARQOS),
    .M_AXI_ARVALID(M_AXI_ARVALID), .M_AXI_ARREADY(M_AXI_ARREADY),
    .M_AXI_RID(M_AXI_ARID), .M_AXI_RDATA(M_AXI_RDATA), .M_AXI_RRESP(M_AXI_RRESP),
    .M_AXI_RLAST(M_AXI_RLAST), .M_AXI_RVALID(M_AXI_RVALID), .M_AXI_RREADY(M_AXI_RREADY),
    .sched_irq(sched_irq));

  // =================== Модель памяти (64-бит, 1 Мб = 131072 слов) ===================
  logic [63:0] mem [0:131071];
  integer i;

  // read path
  logic [31:0] ar_pend_addr;
  logic [7:0]  ar_pend_len, rd_beats_left;
  logic [31:0] rd_word_addr;
  logic        ar_pend_valid;
  assign M_AXI_AWREADY=1'b1;
  assign M_AXI_WREADY =1'b1;
  assign M_AXI_ARREADY=~ar_pend_valid;
  assign M_AXI_BRESP  =2'b00;
  assign M_AXI_RID    = M_AXI_ARID;              // эхо ID запроса (конвенция проекта)
  assign M_AXI_RDATA  = ar_pend_valid ? mem[rd_word_addr] : 64'h0;  // непрерывно из памяти
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ar_pend_valid<=0; M_AXI_RVALID<=0; M_AXI_RLAST<=0; end
    else begin
      if (!ar_pend_valid && M_AXI_ARVALID && M_AXI_ARREADY) begin
        ar_pend_len<=M_AXI_ARLEN; ar_pend_valid<=1; rd_beats_left<=M_AXI_ARLEN; rd_word_addr<=memidx(M_AXI_ARADDR);
      end
      if (ar_pend_valid) begin
        if (!M_AXI_RVALID) begin
          M_AXI_RVALID<=1; M_AXI_RLAST<=(rd_beats_left==0);
        end else if (M_AXI_RREADY) begin
          if (M_AXI_RLAST) begin M_AXI_RVALID<=0; ar_pend_valid<=0; end
          else begin rd_word_addr<=rd_word_addr+1; rd_beats_left<=rd_beats_left-1; M_AXI_RLAST<=(rd_beats_left==1); end
        end
      end
    end
  end

  // write path
  logic [31:0] wr_word_addr;
  logic [7:0]  wr_beats_left;
  logic        wr_active;
  wire [31:0] wr_word_addr_comb = (M_AXI_AWVALID && M_AXI_AWREADY) ? memidx(M_AXI_AWADDR) : wr_word_addr;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin M_AXI_BVALID<=0; wr_active<=0; end
    else begin
      if (!wr_active && M_AXI_AWVALID && M_AXI_AWREADY) begin wr_beats_left<=M_AXI_AWLEN; wr_active<=1; end
      if (M_AXI_WVALID && M_AXI_WREADY) begin
        mem[wr_word_addr_comb]<=M_AXI_WDATA; wr_word_addr<=wr_word_addr_comb+1;
        if (M_AXI_WLAST || wr_beats_left==0) begin M_AXI_BVALID<=1; wr_active<=0; end
        else wr_beats_left<=wr_beats_left-1;
      end
      if (M_AXI_BVALID && M_AXI_BREADY) M_AXI_BVALID<=0;
    end
  end

  // =================== host AXI-Lite tasks ===================
  integer k;
  task axi_lite_write(input [7:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      S_AXI_AWADDR=addr; S_AXI_AWVALID=1; S_AXI_WDATA=data; S_AXI_WSTRB=4'hF; S_AXI_WVALID=1; S_AXI_BREADY=1;
      @(posedge clk); k=0;
      while (!(S_AXI_AWREADY && S_AXI_WREADY)) begin @(posedge clk); k=k+1; if(k>50) $finish; end
      @(posedge clk); S_AXI_AWVALID=0; S_AXI_WVALID=0; k=0;
      while (!S_AXI_BVALID) begin @(posedge clk); k=k+1; if(k>50) $finish; end
      @(posedge clk); S_AXI_BREADY=0;
    end
  endtask
  task axi_lite_read(input [7:0] addr, output logic [31:0] data);
    begin
      @(posedge clk); S_AXI_ARADDR=addr; S_AXI_ARVALID=1; S_AXI_RREADY=0; k=0;
      while (!S_AXI_RVALID) begin @(posedge clk); k=k+1; if(k>50) $finish; end
      data=S_AXI_RDATA; S_AXI_RREADY=1;
      @(posedge clk); S_AXI_ARVALID=0; S_AXI_RREADY=0;
    end
  endtask

  // =================== адреса (в байтах) — внутри DDR-окна платы in_win() ===================
  parameter longint BASE_DATA   = 32'h8000_0000;   // DDR3 window [0x8000_0000..0x9000_0000)
  parameter longint BASE_WEIGHT = 32'h8002_0000;
  parameter longint BASE_RESULT = 32'h8004_0000;
  parameter longint DESC_RING   = 32'h8006_0000;
  parameter longint COMP_RING   = 32'h8006_2000;
  parameter int DESC_STRIDE = 32;  // байт на дескриптор
  parameter int COMP_STRIDE = 16;  // байт на завершение

  // индекс в sim-массиве (1 Мб): маскируем DDR-окно, чтобы адрес 0x8000_0000+ попал в mem[0..]
  function automatic [31:0] memidx(input [31:0] a);
    memidx = (a & 32'h000F_FFFF) >> 3;   // окно 1 Мб внутри 0x8000_0000
  endfunction

  // =================== тест ===================
  integer fd64, fw64, wc, nj;
  logic [63:0] word;
  logic [31:0] rd;
  longint cyc_last, stalled;

  initial begin
    // стартовое состояние
    S_AXI_AWADDR=0; S_AXI_AWVALID=0; S_AXI_WDATA=0; S_AXI_WSTRB=0;
    S_AXI_WVALID=0; S_AXI_BREADY=0; S_AXI_ARADDR=0; S_AXI_ARVALID=0; S_AXI_RREADY=0;
    for (i=0;i<131072;i=i+1) mem[i]=64'h0;

    // ---- загрузка реальных векторов (64-бит words) в память ----
    // data:  vec64.dat (NJOBS*N_PER_JOB слов) в BASE_DATA
    fd64=$fopen("vec64.dat","r");
    if (fd64==0) begin $display("FAIL: vec64.dat не открыт"); $finish; end
    wc=0;
    while (!$feof(fd64) && wc < NJOBS*N_PER_JOB) begin
      if ($fscanf(fd64,"%h\n",word)!=1) break;
      mem[32'(memidx(BASE_DATA)) + wc] = word; wc=wc+1;
    end
    $fclose(fd64);
    // weights: w64.dat в BASE_WEIGHT
    fw64=$fopen("w64.dat","r");
    if (fw64==0) begin $display("FAIL: w64.dat не открыт"); $finish; end
    wc=0;
    while (!$feof(fw64) && wc < NJOBS*N_PER_JOB) begin
      if ($fscanf(fw64,"%h\n",word)!=1) break;
      mem[32'(memidx(BASE_WEIGHT)) + wc] = word; wc=wc+1;
    end
    $fclose(fw64);
    $display("loaded real words: data=%0d weights=%0d (NJOBS=%0d, N_PER_JOB=%0d, NUM_MAC=%0d, ADDERS=%0d)",
             NJOBS*N_PER_JOB, NJOBS*N_PER_JOB, NJOBS, N_PER_JOB, NUM_MAC, ADDERS);

    // ---- сборка кольца дескрипторов ----
    // размер задачи N: чередуем 32/40(long)/16/33, чтобы накрыть partial+long-dot
    for (nj=0; nj<NJOBS; nj=nj+1) begin
      integer N;
      longint daddr, waddr, raddr;
      if (LONG_EN) begin
        case (nj % 4)
          0: N = NUM_MAC;
          1: N = NUM_MAC + 8;         // long-dot (2 прохода)
          2: N = NUM_MAC/2;            // partial
          default: N = NUM_MAC + 1;    // long-dot (2 прохода, остаток 1)
        endcase
      end else begin
        N = NUM_MAC;                    // только single-pass (контрольный тест)
      end
      daddr = BASE_DATA   + 32'(nj*N_PER_JOB*8);
      waddr = BASE_WEIGHT + 32'(nj*N_PER_JOB*8);
      raddr = BASE_RESULT + 32'(nj*8);
      // дескриптор 32 Б = 4 слова: {data,weights,result,{n,tag}}
      mem[32'(memidx(DESC_RING)) + nj*4 + 0] = daddr;
      mem[32'(memidx(DESC_RING)) + nj*4 + 1] = waddr;
      mem[32'(memidx(DESC_RING)) + nj*4 + 2] = raddr;
      mem[32'(memidx(DESC_RING)) + nj*4 + 3] = {16'h0, 16'(N), 16'(nj)};
    end

    repeat (10) @(posedge clk);
    rst_n <= 1;
    repeat (10) @(posedge clk);

    // --- запуск пакета через планировщик (как TdotScheduler.dot_batch) ---
    axi_lite_write(8'h4c, DESC_RING[31:0]);  axi_lite_write(8'h50, 32'h0);  // DESC_BASE
    axi_lite_write(8'h54, COMP_RING[31:0]);  axi_lite_write(8'h58, 32'h0);  // COMP_BASE
    axi_lite_write(8'h44, 32'(NJOBS));                                       // SCHED_WPTR
    axi_lite_write(8'h40, 32'h0000_0001);                                    // SCHED_CTRL: sched_en=1

    // --- опрос RPTR с детектором заморозки ---
    cyc_last = 0; stalled = 0;
    forever begin
      @(posedge clk); @(posedge clk); @(posedge clk);
      axi_lite_read(8'h48, rd);                 // SCHED_RPTR
      if (rd != cyc_last) begin
        cyc_last = rd; stalled = 0;
      end else begin
        stalled = stalled + 3;
        if (stalled > WATCHDOG) begin
          $display(">>> HANG: RPTR замер на %0d из %0d задач (нет прогресса %0d тактов)",
                   cyc_last, NJOBS, stalled);
`ifdef PROBE_TREE
          $display("    sched: cstate=%0d rstate=%0d rd_iss=%0d rd_recv=%0d rd_done=%0d",
                   dut.cstate, dut.rstate, dut.rd_issued, dut.rd_recv, dut.rd_done);
          $display("    sched: rptr_q=%0d wptr_q=%0d busy_ok=%0d",
                   dut.sched_rptr_q, dut.sched_wptr_q, dut.busy_q);
          $display("    u_core: phase=%0d t_lvl=%0d t_cnt=%0d collected=%0d rnd_issue=%0d tree_can=%0d",
                   dut.u_core.phase, dut.u_core.t_lvl, dut.u_core.t_cnt,
                   dut.u_core.collected, dut.u_core.rnd_issue, dut.u_core.tree_can_issue);
          $display("    u_acc: add_phase=%0d  (acc_valid_out=%0d)",
                   dut.u_acc.u_add.phase, dut.u_acc.valid_out);
`endif
          $fatal(1);
        end
      end
      if (rd >= NJOBS) begin
            // контроль корректности: вывести результаты первых 5 задач для сверки с Python-эталоном
            for (integer q=20; q<25; q=q+1) begin
                logic [63:0] rw;
                rw = mem[32'(memidx(COMP_RING)) + q*2];   // W0 завершения: {tag[15:0], result[47:0]}
                $display("  comp[%0d] = tag=%0d result=%012h", q, rw[63:48], rw[47:0]);
            end
            $display("PASS: планировщик выполнил все %0d задач кольца без зависаний (последний RPTR=%0d)",
                     NJOBS, rd);
            $finish;
          end
    end
  end

// аварийный стоп: если ни RPTR-завершение, ни HANG не сработали — обрезаем по времени
  initial begin
    #20000000;   // 20 мс симуляционного времени
    $display("GLOBAL TIMEOUT (20 ms): задачи не завершились за отведённое время — вероятно, движок крутится без прогресса");
    $finish;
  end

endmodule