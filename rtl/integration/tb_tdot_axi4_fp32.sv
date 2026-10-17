// ============================================================================
// tb_tdot_axi4_fp32.sv - тест AXI4-мастера в режиме ELEM_FMT=1 (fp32 вход/выход)
// ----------------------------------------------------------------------------
// Память заполняется fp32-упакованными данными (2 fp32 на 64-бит слово).
// Раскладка (в байтах) на один случай (NUM_MAC элементов data + weights):
//   data[0..NUM_MAC-1]  : база = ncase*2*NUM_MAC*4, по 4 байта на fp32
//   weights[0..NUM_MAC-1]: база = ncase*2*NUM_MAC*4 + NUM_MAC*4
//   result               : база = 0x800 + ncase*4 (4 байта fp32)
// Ядро: ELEM_FMT=1 -> загружает fp32, конвертирует в tf48 (F2T), считает dot,
// результат tf48->fp32 (T2F) пишет как 4 байта. Сверку ведёт Python-скрипт
// verify_tdot_axi4_fp32.py.
// ============================================================================
module tb_tdot_axi4_fp32;

    parameter int NUM_MAC = 32;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;   // 100 МГц

    // счётчики событий F2T (для отладки синхронизации)
    integer cnt_push = 0, cnt_mv = 0;

    logic [7:0]  S_AXI_AWADDR, S_AXI_ARADDR;
    logic        S_AXI_AWVALID, S_AXI_WVALID, S_AXI_BREADY, S_AXI_ARVALID, S_AXI_RREADY;
    logic [31:0] S_AXI_WDATA;
    logic [3:0]  S_AXI_WSTRB;
    logic        S_AXI_AWREADY, S_AXI_WREADY, S_AXI_BVALID, S_AXI_ARREADY, S_AXI_RVALID;
    logic [31:0] S_AXI_RDATA;

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
    logic        M_AXI_BVALID, M_AXI_BREADY, M_AXI_RVALID, M_AXI_RREADY, M_AXI_RLAST;
    logic        sched_irq;
    logic [63:0] M_AXI_RDATA;
    logic diag_go, diag_busy, diag_done, diag_f2t_sv, diag_f2t_mv, diag_f2t_dv;

    tdot_axi4 #(
        .NUM_MAC(NUM_MAC),
        .BURST_RD_LEN(16),
        .BURST_WR_LEN(8),
        .ELEM_FMT(1)
    ) dut (
        .S_AXI_ACLK(clk), .S_AXI_ARESETN(rst_n),
        .S_AXI_AWADDR(S_AXI_AWADDR), .S_AXI_AWPROT(1'b0),
        .S_AXI_AWVALID(S_AXI_AWVALID), .S_AXI_AWREADY(S_AXI_AWREADY),
        .S_AXI_WDATA(S_AXI_WDATA), .S_AXI_WSTRB(S_AXI_WSTRB),
        .S_AXI_WVALID(S_AXI_WVALID), .S_AXI_WREADY(S_AXI_WREADY),
        .S_AXI_BRESP(), .S_AXI_BVALID(S_AXI_BVALID), .S_AXI_BREADY(S_AXI_BREADY),
        .S_AXI_ARADDR(S_AXI_ARADDR), .S_AXI_ARPROT(1'b0),
        .S_AXI_ARVALID(S_AXI_ARVALID), .S_AXI_ARREADY(S_AXI_ARREADY),
        .S_AXI_RDATA(S_AXI_RDATA), .S_AXI_RRESP(),
        .S_AXI_RVALID(S_AXI_RVALID), .S_AXI_RREADY(S_AXI_RREADY),
        .M_AXI_ACLK(clk), .M_AXI_ARESETN(rst_n),
        .M_AXI_AWID(M_AXI_AWID), .M_AXI_AWADDR(M_AXI_AWADDR), .M_AXI_AWLEN(M_AXI_AWLEN),
        .M_AXI_AWSIZE(M_AXI_AWSIZE), .M_AXI_AWBURST(M_AXI_AWBURST),
        .M_AXI_AWLOCK(M_AXI_AWLOCK), .M_AXI_AWCACHE(M_AXI_AWCACHE),
        .M_AXI_AWPROT(M_AXI_AWPROT), .M_AXI_AWQOS(M_AXI_AWQOS),
        .M_AXI_AWVALID(M_AXI_AWVALID), .M_AXI_AWREADY(M_AXI_AWREADY),
        .M_AXI_WDATA(M_AXI_WDATA), .M_AXI_WSTRB(M_AXI_WSTRB),
        .M_AXI_WLAST(M_AXI_WLAST), .M_AXI_WVALID(M_AXI_WVALID), .M_AXI_WREADY(M_AXI_WREADY),
        .M_AXI_BID(M_AXI_AWID), .M_AXI_BRESP(M_AXI_BRESP),
        .M_AXI_BVALID(M_AXI_BVALID), .M_AXI_BREADY(M_AXI_BREADY),
        .M_AXI_ARID(M_AXI_ARID), .M_AXI_ARADDR(M_AXI_ARADDR), .M_AXI_ARLEN(M_AXI_ARLEN),
        .M_AXI_ARSIZE(M_AXI_ARSIZE), .M_AXI_ARBURST(M_AXI_ARBURST),
        .M_AXI_ARLOCK(M_AXI_ARLOCK), .M_AXI_ARCACHE(M_AXI_ARCACHE),
        .M_AXI_ARPROT(M_AXI_ARPROT), .M_AXI_ARQOS(M_AXI_ARQOS),
        .M_AXI_ARVALID(M_AXI_ARVALID), .M_AXI_ARREADY(M_AXI_ARREADY),
        .M_AXI_RID(M_AXI_ARID), .M_AXI_RDATA(M_AXI_RDATA), .M_AXI_RRESP(M_AXI_RRESP),
        .M_AXI_RLAST(M_AXI_RLAST), .M_AXI_RVALID(M_AXI_RVALID), .M_AXI_RREADY(M_AXI_RREADY),
        .sched_irq(sched_irq),
        .diag_go(diag_go), .diag_busy(diag_busy), .diag_done(diag_done),
        .diag_f2t_sv(diag_f2t_sv), .diag_f2t_mv(diag_f2t_mv), .diag_f2t_dv(diag_f2t_dv)
    );

    // dump FIFO contents at CS_LOAD entry (после заполнения expander'ом)
    logic was_load_active = 0;
    always_ff @(posedge clk) begin
        if (dut.load_active && !was_load_active)
            $display("FIFO@load: %h %h %h %h", dut.fifo_mem[0], dut.fifo_mem[1], dut.fifo_mem[2], dut.fifo_mem[3]);
        was_load_active <= dut.load_active;
    end

    // счётчики F2T (отладка синхронизации; не влияют на результат)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cnt_push <= 0; cnt_mv <= 0; end
        else begin
            if (dut.pf_push) cnt_push <= cnt_push + 1;
            if (diag_f2t_mv) cnt_mv  <= cnt_mv + 1;
        end
    end

    // ---------------- модель памяти (64-бит, 1 Мб = 131072 слов) ----------------
    logic [63:0] mem [0:131071];
    integer init_file, i;

    // AXI slave: read path (как в tb_tdot_axi4.sv)
    logic [31:0] ar_pend_addr;
    logic [7:0]  ar_pend_len;
    logic        ar_pend_valid;
    logic [7:0]  rd_beats_left;
    logic [31:0] rd_word_addr;
    assign M_AXI_AWREADY = 1'b1;
    assign M_AXI_WREADY  = 1'b1;
    assign M_AXI_ARREADY = ~ar_pend_valid;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_pend_valid <= 0; M_AXI_RVALID <= 1'b0; M_AXI_RDATA <= 64'h0; M_AXI_RLAST <= 1'b0;
        end else begin
            if (!ar_pend_valid && M_AXI_ARVALID && M_AXI_ARREADY) begin
                ar_pend_len <= M_AXI_ARLEN; ar_pend_valid <= 1'b1; rd_beats_left <= M_AXI_ARLEN;
                rd_word_addr <= M_AXI_ARADDR >> 3;
            end
            if (ar_pend_valid) begin
                if (!M_AXI_RVALID) begin
                    M_AXI_RVALID <= 1'b1; M_AXI_RDATA <= mem[rd_word_addr]; M_AXI_RLAST <= (rd_beats_left == 0);
                end else if (M_AXI_RREADY) begin
                    if (M_AXI_RLAST) begin M_AXI_RVALID <= 1'b0; ar_pend_valid <= 1'b0; end
                    else begin rd_word_addr <= rd_word_addr + 1; rd_beats_left <= rd_beats_left - 1;
                              M_AXI_RDATA <= mem[rd_word_addr + 1]; M_AXI_RLAST <= (rd_beats_left == 1); end
                end
            end
        end
    end

    // AXI slave: write path
    logic [31:0] wr_word_addr;
    logic [7:0]  wr_beats_left;
    logic        wr_active;
    wire [31:0] wr_word_addr_comb = (M_AXI_AWVALID && M_AXI_AWREADY) ? (M_AXI_AWADDR >> 3) : wr_word_addr;
    assign M_AXI_BRESP = 2'b00;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin M_AXI_BVALID <= 1'b0; wr_active <= 1'b0; end
        else begin
            if (!wr_active && M_AXI_AWVALID && M_AXI_AWREADY) begin wr_beats_left <= M_AXI_AWLEN; wr_active <= 1'b1; end
            if (M_AXI_WVALID && M_AXI_WREADY) begin
                mem[wr_word_addr_comb] <= M_AXI_WDATA; wr_word_addr <= wr_word_addr_comb + 1;
                if (M_AXI_WLAST || wr_beats_left == 0) begin M_AXI_BVALID <= 1'b1; wr_active <= 1'b0; end
                else wr_beats_left <= wr_beats_left - 1;
            end
            if (M_AXI_BVALID && M_AXI_BREADY) M_AXI_BVALID <= 1'b0;
        end
    end

    // хост: AXI-Lite access (как в tb_tdot_axi4.sv)
    integer k;
    task axi_lite_write(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            S_AXI_AWADDR = addr; S_AXI_AWVALID = 1; S_AXI_WDATA = data; S_AXI_WSTRB = 4'hF; S_AXI_WVALID = 1; S_AXI_BREADY = 1;
            @(posedge clk);
            k = 0;
            while (!(S_AXI_AWREADY && S_AXI_WREADY)) begin @(posedge clk); k = k + 1; if (k > 50) begin $display("W TIMEOUT %02h", addr); $finish; end end
            @(posedge clk);
            S_AXI_AWVALID = 0; S_AXI_WVALID = 0;
            k = 0;
            while (!S_AXI_BVALID) begin @(posedge clk); k = k + 1; if (k > 50) begin $display("B TIMEOUT %02h", addr); $finish; end end
            @(posedge clk); S_AXI_BREADY = 0;
        end
    endtask
    task axi_lite_read(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            S_AXI_ARADDR = addr; S_AXI_ARVALID = 1; S_AXI_RREADY = 0;
            k = 0;
            while (!S_AXI_RVALID) begin @(posedge clk); k = k + 1; if (k > 80) begin $display("R TIMEOUT %02h", addr); $finish; end end
            data = S_AXI_RDATA; S_AXI_RREADY = 1; @(posedge clk); S_AXI_ARVALID = 0; S_AXI_RREADY = 0;
        end
    endtask

    // ---------------- тест ----------------
    integer f;
    logic [31:0] rd;
    logic [63:0] rdata, wdata;
    integer ncase;

    initial begin
        $dumpfile("sim/tb_tdot_axi4_fp32.vcd");
        $dumpvars(0, tb_tdot_axi4_fp32);
        S_AXI_AWADDR = 0; S_AXI_AWVALID = 0; S_AXI_WDATA = 0; S_AXI_WSTRB = 0;
        S_AXI_WVALID = 0; S_AXI_BREADY = 0; S_AXI_ARADDR = 0; S_AXI_ARVALID = 0; S_AXI_RREADY = 0;
        for (i = 0; i < 131072; i = i + 1) mem[i] = 64'h0;

        f = $fopen("sim/tb_tdot_axi4_fp32_in.hex", "r");
        if (f == 0) begin $display("ERROR: cannot open fp32 input hex"); $finish; end
        ncase = 0;
        while (!$feof(f)) begin
            rdata = 64'h0;
            if ($fscanf(f, "%h\n", rdata) != 1) break;
            mem[ncase] = rdata;
            ncase = ncase + 1;
        end
        $fclose(f);
        $display("Loaded %0d fp32 words", ncase);

        repeat (10) @(posedge clk);
        rst_n <= 1;
        repeat (10) @(posedge clk);

        f = $fopen("sim/tb_tdot_axi4_fp32_out.hex", "w");
        for (ncase = 0; ncase < 4; ncase = ncase + 1) begin
            // data база = ncase*2*NUM_MAC*4 (байты); weights = + NUM_MAC*4
            axi_lite_write(8'h14, ncase * 2 * NUM_MAC * 4);            // DATA_ADDR_LO
            axi_lite_write(8'h18, 32'h0000_0000);                      // DATA_ADDR_HI
            axi_lite_write(8'h1c, ncase * 2 * NUM_MAC * 4 + NUM_MAC * 4); // WEIGHTS_ADDR_LO
            axi_lite_write(8'h20, 32'h0000_0000);                      // WEIGHTS_ADDR_HI
            axi_lite_write(8'h24, 32'h0000_0800 + ncase * 4);          // RESULT_ADDR_LO (4 байта)
            axi_lite_write(8'h28, 32'h0000_0000);                      // RESULT_ADDR_HI
            axi_lite_write(8'h08, 32'(NUM_MAC));                       // N_IN = NUM_MAC
            axi_lite_write(8'h00, 32'h0000_0001);                      // GO

            begin
                integer k;
                logic [31:0] st;
                k = 0;
                do begin
                    axi_lite_read(8'h04, st); k = k + 1;
                    if (k > 40000) begin
                        $display("TIMEOUT fp32 case %0d, STATUS=%08h", ncase, st);
                        $display("DBG cstate=%0d rstate=%0d rd_idx=%0d fp_written=%0d pf_wr=%0d pf_rd=%0d f2t_sv=%0d f2t_mv=%0d f2t_sd=%h", dut.cstate, dut.rstate, dut.rd_idx, dut.fp_written, dut.pf_wr, dut.pf_rd, diag_f2t_sv, diag_f2t_mv, dut.f2t_s_data);
                        $finish;
                    end
                end while (!(st & 2));
            end

            // результат — 4 байта fp32 по result_addr
            wdata = mem[(32'h0000_0800 + ncase * 4) >> 3];
            $fwrite(f, "%08h\n", wdata[31:0]);
            $display("fp32 case %0d RESULT=%08h core_result=%h push=%0d mv=%0d",
                     ncase, wdata[31:0], dut.core_result, cnt_push, cnt_mv);
        end
        $fclose(f);
        repeat (10) @(posedge clk);
        $finish;
    end
endmodule