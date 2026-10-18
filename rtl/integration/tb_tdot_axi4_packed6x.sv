// ============================================================================
// tb_tdot_axi4_packed6x.sv - ВЕРИФИКАЦИЯ ELEM_FMT=2 (PACKED6, 6 байт/элемент)
// ----------------------------------------------------------------------------
// Покрывает те же сценарии, что fp32x, но для PACKED6 (tf48 плотно по 6 байт):
//   1) partial / нечётный N_IN            -> хвостовое слово частичное
//   2) long-dot N_IN > NUM_MAC            -> multi-pass + аккумулятор tfadd48
//   3) планировщик в PACKED6 (CS_CMP1..3)
//   4) align_q-fault                       -> статус/пропуск
//   5) multi-burst (BURST_RD_LEN < words)
//   6) случайный составной прогон
//
// Данные в памяти: PACKED6 байт-поток N*6 байт на элемент; питон упаковывает
// их в 64-бит слов (mem hex "addr value"). Результат = tf48 (48 бит), ядро
// пишет 6 байт по word-выровненному result_addr (WSTRB=0x3F; TB-модель памяти
// пишет полное слово {16'h0, result48}).
//
// Формат задач (packed6x_tasks.txt): <kind> <n> <data> <weights> <result>
//   <tag> <b64lo> <b64hi>  (kind: 1=GO, 2=sched; адреса байтовые)
// Выход: sim/packed6x_out.hex.
// ============================================================================
module tb_tdot_axi4_packed6x;

    parameter int NUM_MAC = 32;
    parameter int BURST_RD_LEN = 16;
    parameter int BURST_WR_LEN = 8;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;   // 100 МГц

    // ---- AXI-Lite (хост) ----
    logic [7:0] S_AXI_AWADDR, S_AXI_ARADDR;
    logic S_AXI_AWVALID, S_AXI_WVALID, S_AXI_BREADY, S_AXI_ARVALID, S_AXI_RREADY;
    logic [31:0] S_AXI_WDATA;
    logic [3:0]  S_AXI_WSTRB;
    logic S_AXI_AWREADY, S_AXI_WREADY, S_AXI_BVALID, S_AXI_ARREADY, S_AXI_RVALID;
    logic [31:0] S_AXI_RDATA;

    // ---- AXI4 master ----
    logic [0:0] M_AXI_AWID, M_AXI_ARID;
    logic [31:0] M_AXI_AWADDR, M_AXI_ARADDR;
    logic [7:0] M_AXI_AWLEN, M_AXI_ARLEN;
    logic [2:0] M_AXI_AWSIZE, M_AXI_ARSIZE;
    logic [1:0] M_AXI_AWBURST, M_AXI_ARBURST;
    logic M_AXI_AWLOCK, M_AXI_ARLOCK;
    logic [3:0] M_AXI_AWCACHE, M_AXI_ARCACHE;
    logic [2:0] M_AXI_AWPROT, M_AXI_ARPROT;
    logic [3:0] M_AXI_AWQOS, M_AXI_ARQOS;
    logic M_AXI_AWVALID, M_AXI_ARVALID, M_AXI_AWREADY, M_AXI_ARREADY;
    logic [63:0] M_AXI_WDATA;
    logic [7:0]  M_AXI_WSTRB;
    logic M_AXI_WLAST, M_AXI_WVALID, M_AXI_WREADY;
    logic [1:0] M_AXI_BRESP, M_AXI_RRESP;
    logic M_AXI_BVALID, M_AXI_BREADY, M_AXI_RVALID, M_AXI_RREADY, M_AXI_RLAST;
    logic sched_irq;
    logic [63:0] M_AXI_RDATA;
    logic diag_go, diag_busy, diag_done;
    logic diag_f2t_sv, diag_f2t_mv, diag_f2t_dv;

    tdot_axi4 #(
        .NUM_MAC(NUM_MAC),
        .BURST_RD_LEN(BURST_RD_LEN),
        .BURST_WR_LEN(BURST_WR_LEN),
        .ELEM_FMT(2)
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

    // ---------------- модель памяти (64-бит, 1 Мб = 131072 слов) ----------------
    logic [63:0] mem [0:131071];
    integer f, i;
    logic [31:0] base_addr;
    logic [63:0] base_word;

    // ---- AXI slave: read path ----
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
            ar_pend_valid <= 0; M_AXI_RVALID <= 1'b0;
            M_AXI_RDATA <= 64'h0; M_AXI_RLAST <= 1'b0;
        end else begin
            if (!ar_pend_valid && M_AXI_ARVALID && M_AXI_ARREADY) begin
                ar_pend_len   <= M_AXI_ARLEN;
                ar_pend_valid <= 1'b1;
                rd_beats_left <= M_AXI_ARLEN;
                rd_word_addr  <= M_AXI_ARADDR >> 3;
            end
            if (ar_pend_valid) begin
                if (!M_AXI_RVALID) begin
                    M_AXI_RVALID <= 1'b1; M_AXI_RDATA <= mem[rd_word_addr];
                    M_AXI_RLAST  <= (rd_beats_left == 0);
                end else if (M_AXI_RREADY) begin
                    if (M_AXI_RLAST) begin M_AXI_RVALID <= 1'b0; ar_pend_valid <= 1'b0; end
                    else begin
                        rd_word_addr  <= rd_word_addr + 1;
                        rd_beats_left <= rd_beats_left - 1;
                        M_AXI_RDATA   <= mem[rd_word_addr + 1];
                        M_AXI_RLAST   <= (rd_beats_left == 1);
                    end
                end
            end
        end
    end

    // ---- AXI slave: write path ----
    logic [31:0] wr_word_addr;
    logic [7:0]  wr_beats_left;
    logic        wr_active;
    wire [31:0] wr_word_addr_comb =
        (M_AXI_AWVALID && M_AXI_AWREADY) ? (M_AXI_AWADDR >> 3) : wr_word_addr;
    assign M_AXI_BRESP = 2'b00;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin M_AXI_BVALID <= 1'b0; wr_active <= 1'b0; end
        else begin
            if (!wr_active && M_AXI_AWVALID && M_AXI_AWREADY) begin
                wr_beats_left <= M_AXI_AWLEN; wr_active <= 1'b1;
            end
            if (M_AXI_WVALID && M_AXI_WREADY) begin
                // Gap-2: AXI-модель памяти УВАЖАЕТ WSTRB (байт-стробы). Результат
                // PACKED6 пишется 6 байт (WSTRB=0x3F) -> верхние 2 байта слова
                // сохраняют ядовитый сентинел (проверяется верификатором). Раньше
                // писалось полное слово -> WSTRB не валидировался.
                for (int bb = 0; bb < 8; bb = bb + 1)
                    if (M_AXI_WSTRB[bb])
                        mem[wr_word_addr_comb][8*bb +: 8] <= M_AXI_WDATA[8*bb +: 8];
                wr_word_addr <= wr_word_addr_comb + 1;
                if (M_AXI_WLAST || wr_beats_left == 0) begin
                    M_AXI_BVALID <= 1'b1; wr_active <= 1'b0;
                end else wr_beats_left <= wr_beats_left - 1;
            end
            if (M_AXI_BVALID && M_AXI_BREADY) M_AXI_BVALID <= 1'b0;
        end
    end

    // ---- хост: AXI-Lite access ----
    integer k;
    task axi_lite_write(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            S_AXI_AWADDR = addr; S_AXI_AWVALID = 1;
            S_AXI_WDATA = data; S_AXI_WSTRB = 4'hF; S_AXI_WVALID = 1;
            S_AXI_BREADY = 1;
            @(posedge clk);
            k = 0;
            while (!(S_AXI_AWREADY && S_AXI_WREADY)) begin
                @(posedge clk); k = k + 1;
                if (k > 50) begin $display("W TIMEOUT addr=%02h", addr); $finish; end
            end
            @(posedge clk);
            S_AXI_AWVALID = 0; S_AXI_WVALID = 0;
            k = 0;
            while (!S_AXI_BVALID) begin
                @(posedge clk); k = k + 1;
                if (k > 50) begin $display("W TIMEOUT2 addr=%02h", addr); $finish; end
            end
            @(posedge clk); S_AXI_BREADY = 0;
        end
    endtask
    task axi_lite_read(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            S_AXI_ARADDR = addr; S_AXI_ARVALID = 1; S_AXI_RREADY = 0;
            k = 0;
            while (!S_AXI_RVALID) begin
                @(posedge clk); k = k + 1;
                if (k > 80) begin $display("R TIMEOUT addr=%02h", addr); $finish; end
            end
            data = S_AXI_RDATA; S_AXI_RREADY = 1;
            @(posedge clk); S_AXI_ARVALID = 0; S_AXI_RREADY = 0;
        end
    endtask

    // ---------------- manifest заданий ----------------
    integer n_task = 0;
    integer tkind  [0:63];
    integer tn     [0:63];
    integer tdata  [0:63];
    integer twgt   [0:63];
    integer tres   [0:63];
    integer ttag   [0:63];
    logic [63:0] tbl  [0:63];

    // ---------------- тест ----------------
    integer idx;
    integer n_go, n_sched;
    logic [31:0] rd32;
    logic [31:0] st;
    logic [63:0] rw;
    integer out_f;
    integer loops;
    integer j;
    logic [63:0] w0, w1;

    initial begin
        S_AXI_AWADDR = 0; S_AXI_AWVALID = 0; S_AXI_WDATA = 0; S_AXI_WSTRB = 0;
        S_AXI_WVALID = 0; S_AXI_BREADY = 0;
        S_AXI_ARADDR = 0; S_AXI_ARVALID = 0; S_AXI_RREADY = 0;
        for (i = 0; i < 131072; i = i + 1) mem[i] = 64'h0;

        // ---- загрузка памяти ----
        f = $fopen("sim/packed6x_mem.hex", "r");
        if (f == 0) begin $display("ERROR: no packed6x_mem.hex"); $finish; end
        i = 0;
        while (!$feof(f)) begin
            if ($fscanf(f, "%x %x\n", base_addr, base_word) != 2) break;
            mem[base_addr >> 3] = base_word;
            i = i + 1;
        end
        $fclose(f);
        $display("Loaded %0d mem words from packed6x_mem.hex", i);

        // ---- загрузка manifest ----
        f = $fopen("sim/packed6x_tasks.txt", "r");
        if (f == 0) begin $display("ERROR: no packed6x_tasks.txt"); $finish; end
        n_task = 0;
        while (!$feof(f)) begin
            logic [31:0] blo, bhi;
            if ($fscanf(f, "%d %d %d %d %d %d %x %x\n",
                        tkind[n_task], tn[n_task], tdata[n_task], twgt[n_task],
                        tres[n_task], ttag[n_task], blo, bhi) != 8) break;
            tbl[n_task] = {bhi, blo};
            n_task = n_task + 1;
            if (n_task > 63) break;
        end
        $fclose(f);
        $display("Loaded %0d tasks from packed6x_tasks.txt", n_task);

        repeat (10) @(posedge clk);
        rst_n <= 1;
        repeat (10) @(posedge clk);

        out_f = $fopen("sim/packed6x_out.hex","w");

        // ================= GO-задания (kind=1) =================
        for (idx = 0; idx < n_task; idx = idx + 1) begin
            if (tkind[idx] != 1) continue;
            axi_lite_write(8'h14, 32'(tdata[idx]));           // DATA_ADDR_LO
            axi_lite_write(8'h18, 32'h0000_0000);             // DATA_ADDR_HI
            axi_lite_write(8'h1c, 32'(twgt[idx]));            // WEIGHTS_ADDR_LO
            axi_lite_write(8'h20, 32'h0000_0000);             // WEIGHTS_ADDR_HI
            axi_lite_write(8'h24, 32'(tres[idx]));            // RESULT_ADDR_LO
            axi_lite_write(8'h28, 32'h0000_0000);             // RESULT_ADDR_HI
            axi_lite_write(8'h08, 32'(tn[idx]));              // N_IN
            axi_lite_write(8'h00, 32'h0000_0001);             // GO

            loops = 0;
            do begin
                axi_lite_read(8'h04, st); loops = loops + 1;
                if (loops > 200000) begin
                    $display("TIMEOUT packed6x GO case idx=%0d n=%0d STATUS=%08h", idx, tn[idx], st);
                    $display("  cstate=%0d rstate=%0d", dut.cstate, dut.rstate);
                    $finish;
                end
            end while (!(st & 2));

            // ждём READ-мастер полностью idle (после align-фолта чтение ещё идёт)
            loops = 0;
            while (dut.rstate != 2'd0) begin
                @(posedge clk); loops = loops + 1;
                if (loops > 200000) begin $display("GO %0d: RSTATE not idle", idx); $finish; end
            end

            rw = mem[tres[idx] >> 3];
            $fdisplay(out_f, "GO %0d %016x", idx, rw);
            $display("packed6x GO idx=%0d n=%0d res_addr=%08x word=%016x status=%02h",
                     idx, tn[idx], tres[idx], rw, st[1:0]);
        end

        // ================= Планировщик (kind=2) =================
        n_sched = 0;
        for (idx = 0; idx < n_task; idx = idx + 1) if (tkind[idx] == 2) n_sched = n_sched + 1;
        if (n_sched > 0) begin
            logic [31:0] done_cnt, rptr, status;
            axi_lite_write(8'h40, 32'h4);          // flush
            axi_lite_write(8'h4C, 32'h0000_0000);  // DESC_BASE_LO = 0x0
            axi_lite_write(8'h50, 32'h0000_0000);  // DESC_BASE_HI
            axi_lite_write(8'h54, 32'h0000_8000);  // COMP_BASE_LO = 0x8000
            axi_lite_write(8'h58, 32'h0000_0000);  // COMP_BASE_HI
            axi_lite_write(8'h40, 32'h3);          // sched_en=1, irq_en=1
            axi_lite_write(8'h44, 32'(n_sched));   // doorbell WPTR

            loops = 0;
            axi_lite_read(8'h60, done_cnt);
            while (done_cnt < n_sched) begin
                repeat (500) @(posedge clk);
                axi_lite_read(8'h60, done_cnt);
                loops = loops + 1;
                if (loops > 600) begin
                    $display("SCHED TIMEOUT: DONE_CNT=%0d/%0d", done_cnt, n_sched);
                    $display("  cstate=%0d rstate=%0d irq=%b", dut.cstate, dut.rstate, sched_irq);
                    $finish;
                end
            end

            axi_lite_read(8'h48, rptr);
            axi_lite_read(8'h60, done_cnt);
            axi_lite_read(8'h5C, status);
            $fdisplay(out_f, "SUM %d %d %b", rptr, done_cnt, (status[1] && sched_irq));

            j = 0;
            for (idx = 0; idx < n_task; idx = idx + 1) begin
                if (tkind[idx] != 2) continue;
                w0 = mem[(32'h0000_8000 + j*16) >> 3];
                w1 = mem[(32'h0000_8000 + j*16 + 8) >> 3];
                rw = mem[tres[idx] >> 3];
                $fdisplay(out_f, "CMP %0d %016x %016x %016x %04x", idx, w0, w1, rw, ttag[idx]);
                $display("packed6x sched idx=%0d n=%0d tag=%04x w0=%016x w1=%016x res=%016x",
                         idx, tn[idx], ttag[idx], w0, w1, rw);
                j = j + 1;
            end
        end

        $fclose(out_f);
        repeat (10) @(posedge clk);
        $display("=== packed6x DONE: tasks=%0d go=%0d sched=%0d ===", n_task, n_task - n_sched, n_sched);
        $finish;
    end
endmodule