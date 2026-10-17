// ============================================================================
// tb_tdot_sched32.sv - RTL-верификация ПЛАНИРОВЩИКА tdot_axi4 при
//                      NUM_MAC=32, ADDERS=16 (задача планирования 2), часть 2.
// ============================================================================
// Эмуляция xsim (без синтеза/железа). AXI-модель памяти (read/write INCR).
// Сценарии (см. файл sched32_datagen.py):
//   A  SANITY : 4 задачи n=8,32,16,40 tags 0x1111..0x4444, ОДИН doorbell
//               -> результат = n, DONE_CNT=4, completion записаны, IRQ при
//               опустошении кольца.
//   B  REARM  : irq_ack, +2 задачи n=8 tags 0xAAAA/0xBBBB, doorbell 6.
//   C  SAT    : flush, 1 задача n=700 -> CLAMP до MAX_N_TOTAL=512, sat=1,
//               результат=512, passes=16, DONE пришёл (не завис).
//   W  WRAP   : flush, программно заполнить slots 0..255 (n=2, tag=idx),
//               прогрессивные doorbell до 260 задач -> rptr пересекает 256;
//               после done>=47 перезаписать slots 0..3 на задачи 256..259
//               (tags 0x100..0x103) -> comp slot 0/3 должны нести 0x100/0x103
//               (доказательство re-fetch + wrap по mod 256). DONE_CNT=267,
//               rptr=260&0xFF=4, sched_busy снят после опустошения.
// Выход в sim/sched32_out.hex, сверяется python-скриптом.
// ============================================================================
module tb_tdot_sched32;

    parameter int NUM_MAC = 32;
    parameter int ADDERS  = 16;
    parameter int MAX_PASSES = 16;
    parameter int MAX_N_TOTAL = MAX_PASSES * NUM_MAC;  // 512

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

    tdot_axi4 #(
        .NUM_MAC(NUM_MAC), .ADDERS(ADDERS),
        .BURST_RD_LEN(32), .BURST_WR_LEN(8)
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
        .diag_go(diag_go), .diag_busy(diag_busy), .diag_done(diag_done)
    );

    // ---------------- модель памяти (64-бит, 1 Мб) ----------------
    logic [63:0] mem [0:131071];
    integer f, i;

    // ---------------- AXI slave: read path ----------------
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
                    M_AXI_RVALID <= 1'b1;
                    M_AXI_RDATA  <= mem[rd_word_addr];
                    M_AXI_RLAST  <= (rd_beats_left == 0);
                end else if (M_AXI_RREADY) begin
                    if (M_AXI_RLAST) begin
                        M_AXI_RVALID  <= 1'b0;
                        ar_pend_valid <= 1'b0;
                    end else begin
                        rd_word_addr  <= rd_word_addr + 1;
                        rd_beats_left <= rd_beats_left - 1;
                        M_AXI_RDATA   <= mem[rd_word_addr + 1];
                        M_AXI_RLAST   <= (rd_beats_left == 1);
                    end
                end
            end
        end
    end

    // ---------------- AXI slave: write path ----------------
    logic [31:0] wr_word_addr;
    logic [7:0]  wr_beats_left;
    logic        wr_active;
    wire [31:0] wr_word_addr_comb =
        (M_AXI_AWVALID && M_AXI_AWREADY) ? (M_AXI_AWADDR >> 3) : wr_word_addr;
    assign M_AXI_BRESP = 2'b00;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            M_AXI_BVALID <= 1'b0; wr_active <= 1'b0;
        end else begin
            if (!wr_active && M_AXI_AWVALID && M_AXI_AWREADY) begin
                wr_beats_left <= M_AXI_AWLEN;
                wr_active <= 1'b1;
            end
            if (M_AXI_WVALID && M_AXI_WREADY) begin
                mem[wr_word_addr_comb] <= M_AXI_WDATA;
                wr_word_addr <= wr_word_addr_comb + 1;
                if (M_AXI_WLAST || wr_beats_left == 0) begin
                    M_AXI_BVALID <= 1'b1; wr_active <= 1'b0;
                end else begin
                    wr_beats_left <= wr_beats_left - 1;
                end
            end
            if (M_AXI_BVALID && M_AXI_BREADY) M_AXI_BVALID <= 1'b0;
        end
    end

    // ---------------- хост: AXI-Lite access ----------------
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
            @(posedge clk);
            S_AXI_BREADY = 0;
        end
    endtask
    task axi_lite_read(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            S_AXI_ARADDR = addr; S_AXI_ARVALID = 1; S_AXI_RREADY = 0;
            k = 0;
            while (!S_AXI_RVALID) begin
                @(posedge clk); k = k + 1;
                if (k > 50) begin $display("R TIMEOUT addr=%02h", addr); $finish; end
            end
            data = S_AXI_RDATA;
            S_AXI_RREADY = 1;
            @(posedge clk);
            S_AXI_ARVALID = 0; S_AXI_RREADY = 0;
        end
    endtask

    // ---------------- helper: descriptor в памяти ----------------
    task put_desc(input [7:0] slot, input [47:0] da, input [47:0] wa,
                  input [47:0] ra, input [15:0] n, input [15:0] tag);
        logic [31:0] base;
        begin
            base = 32'h0000_0000 + (slot & 8'hFF) * 32;   // DESC_BASE
            mem[base>>3]      = {16'h0, da};
            mem[(base+8)>>3]  = {16'h0, wa};
            mem[(base+16)>>3] = {16'h0, ra};
            mem[(base+24)>>3] = {n, tag};
        end
    endtask

    // ---------------- ждём done_cnt >= target ----------------
    integer loops;
    task wait_done(input integer target, input integer limit_q, input string tag);
        logic [31:0] dc;
        begin
            loops = 0;
            axi_lite_read(8'h60, dc);
            while (dc < target) begin
                repeat (200) @(posedge clk);
                axi_lite_read(8'h60, dc);
                loops = loops + 1;
                if (loops > limit_q) begin
                    $display("%s TIMEOUT: DONE_CNT=%0d (target %0d)", tag, dc, target);
                    $finish;
                end
            end
        end
    endtask

    // ---------------- тест ----------------
    logic [31:0] rd;
    integer slot, idx, w;
    integer out_f;
    logic [31:0] done_cnt, rptr, status;

    parameter int DATA_POOL = 32'h0000_2000;
    parameter int WGT_POOL  = 32'h0000_3000;
    parameter int RES_POOL  = 32'h0000_5000;
    parameter int COMP_BASE = 32'h0000_6000;

    initial begin
        S_AXI_AWADDR = 0; S_AXI_AWVALID = 0; S_AXI_WDATA = 0; S_AXI_WSTRB = 0;
        S_AXI_WVALID = 0; S_AXI_BREADY = 0;
        S_AXI_ARADDR = 0; S_AXI_ARVALID = 0; S_AXI_RREADY = 0;
        for (i = 0; i < 131072; i = i + 1) mem[i] = 64'h0;

        // ---- загрузка памяти: descriptors A/B/C + ones pool ----
        begin
            integer a;
            logic [63:0] v;
            f = $fopen("sched32_mem_init.hex", "r");
            if (f == 0) begin $display("ERROR: no sched32_mem_init.hex"); $finish; end
            i = 0;
            while (!$feof(f)) begin
                if ($fscanf(f, "%h %h\n", a, v) != 2) break;
                mem[a>>3] = v;
                i = i + 1;
            end
            $fclose(f);
            $display("Loaded %0d mem words from sched32_mem_init.hex", i);
        end

        repeat (10) @(posedge clk);
        rst_n <= 1;
        repeat (20) @(posedge clk);

        out_f = $fopen("sim/sched32_out.hex","w");

        // ================= A: SANITY 4 задачи ===============================
        $display("=== A: setup planner @ NUM_MAC=%0d ADDERS=%0d ===", NUM_MAC, ADDERS);
        axi_lite_write(8'h40, 32'h4);          // flush (reset rptr)
        axi_lite_write(8'h4C, 32'h0000_0000);  // DESC_BASE_LO
        axi_lite_write(8'h50, 32'h0000_0000);  // DESC_BASE_HI
        axi_lite_write(8'h54, 32'h0000_6000);  // COMP_BASE_LO
        axi_lite_write(8'h58, 32'h0000_0000);  // COMP_BASE_HI
        axi_lite_write(8'h40, 32'h3);          // sched_en=1, irq_en=1
        axi_lite_write(8'h44, 32'h4);          // doorbell WPTR=4
        wait_done(4, 200, "A");                 // DONE_CNT>=4
        axi_lite_read(8'h48, rptr);
        axi_lite_read(8'h60, done_cnt);
        axi_lite_read(8'h5C, status);
        $fdisplay(out_f, "A rptr=%0d done_cnt=%0d status=%08x sched_irq=%b",
                  rptr, done_cnt, status, sched_irq);
        $fdisplay(out_f, "A irq_state irq_pending=%b sched_irq=%b", status[1], sched_irq);
        for (idx = 0; idx < 4; idx = idx + 1) begin
            logic [63:0] w0, w1;
            w0 = mem[(COMP_BASE + idx*16)>>3];
            w1 = mem[(COMP_BASE + idx*16 + 8)>>3];
            $fdisplay(out_f, "A comp %0d tag=%04x result=%012x sat=%b align=%b passes=%0d",
                      idx, w0[63:48], w0[47:0], w1[0], w1[1], w1[15:8]);
        end

        // ================= B: REARM (irq_ack + 2 задач) =====================
        $display("=== B: irq_ack + rearm ===");
        if (!status[1] || !sched_irq)
            $display("B WARN: irq_pending не поднят после A");
        axi_lite_write(8'h40, 32'h3 | (1<<3));   // irq_ack
        axi_lite_read(8'h5C, status);
        $fdisplay(out_f, "B irq_ack done status=%08x sched_irq=%b", status, sched_irq);
        // +2 задач n=8 tags 0xAAAA/0xBBBB, slot 4,5 (в файле уже есть desc)
        axi_lite_write(8'h44, 32'h6);            // doorbell WPTR=6
        wait_done(6, 200, "B");
        axi_lite_read(8'h48, rptr);
        axi_lite_read(8'h60, done_cnt);
        $fdisplay(out_f, "B rptr=%0d done_cnt=%0d", rptr, done_cnt);
        for (idx = 4; idx < 6; idx = idx + 1) begin
            logic [63:0] w0, w1;
            w0 = mem[(COMP_BASE + idx*16)>>3];
            w1 = mem[(COMP_BASE + idx*16 + 8)>>3];
            $fdisplay(out_f, "B comp %0d tag=%04x result=%012x sat=%b align=%b passes=%0d",
                      idx, w0[63:48], w0[47:0], w1[0], w1[1], w1[15:8]);
        end

        // ================= C: SAT n=700 -> clamp 512 ========================
        $display("=== C: saturation n=700 (clamp %0d) ===", MAX_N_TOTAL);
        put_desc(8'h0, DATA_POOL, WGT_POOL,
                 RES_POOL + 16'h400, 16'd700, 16'hC0DE);
        axi_lite_write(8'h40, 32'h4);            // flush: rptr->0
        axi_lite_write(8'h40, 32'h3);            // sched_en, irq_en (flush 0)
        axi_lite_write(8'h44, 32'h1);            // doorbell WPTR=1 (slot0 = n=700)
        wait_done(7, 400, "C");
        axi_lite_read(8'h48, rptr);
        axi_lite_read(8'h60, done_cnt);
        axi_lite_read(8'h5C, status);
        $fdisplay(out_f, "C rptr=%0d done_cnt=%0d status=%08x", rptr, done_cnt, status);
        begin
            logic [63:0] w0, w1;
            w0 = mem[(COMP_BASE + 0*16)>>3];
            w1 = mem[(COMP_BASE + 0*16 + 8)>>3];
            $fdisplay(out_f, "C comp tag=%04x result=%012x sat=%b align=%b passes=%0d",
                      w0[63:48], w0[47:0], w1[0], w1[1], w1[15:8]);
            $fdisplay(out_f, "C res_mem_512=%012x", mem[(RES_POOL + 12'h400)>>3][47:0]);
        end

        // ================= W: WRAP кольца через 256 =========================
        $display("=== W: wrap ring through 256 ===");
        axi_lite_write(8'h40, 32'h4);            // flush: rptr->0
        axi_lite_write(8'h40, 32'h3);
        // программно заливаем descriptors slots 0..255: n=2, tag=idx
        for (slot = 0; slot < 256; slot = slot + 1)
            put_desc(slot[7:0], DATA_POOL, WGT_POOL,
                     RES_POOL + (slot & 8'hFF)*8, 16'd2, slot & 16'hFF);
        // прогрессивный doorbell: наполняем до 260 задач, пересекая wptr=256
        // wptr и rptr 8-бит: ступени дают rptr 0->64->128->192->256->260.
        begin
            integer wtarget;
            wtarget = 64;
            while (wtarget <= 256) begin
                axi_lite_write(8'h44, wtarget & 8'hFF);
                wait_done(7 + wtarget, 400, "Wb");
                wtarget = wtarget + 64;
            end
            // после того как rptr прошёл 64 (задачи 256..259 ещё не в слотах),
            // перезаписываем slots 0..3 на задачи 256..259 (tags 0x100..0x103)
            // дожидаемся done=47 (7 базовых + 40 задач), перезаписка с запасом
            wait_done(47, 400, "Wpre");
            for (idx = 0; idx < 4; idx = idx + 1)
                put_desc(idx[7:0], DATA_POOL, WGT_POOL,
                         RES_POOL + idx*8, 16'd2, 16'h100 + idx);
            // финал: doorbell до 260
            axi_lite_write(8'h44, 32'h4);        // WPTR = 260 & 0xFF = 4
            wait_done(267, 600, "Wfinal");
        end
        axi_lite_read(8'h48, rptr);
        axi_lite_read(8'h60, done_cnt);
        axi_lite_read(8'h5C, status);
        $fdisplay(out_f, "W rptr=%0d done_cnt=%0d status=%08x sched_irq=%b",
                  rptr, done_cnt, status, sched_irq);
        // проверить comp-слоты wrap: slot 0 -> tag 0x100 (task 256), slot 3 -> 0x103 (task 259)
        for (idx = 0; idx < 4; idx = idx + 1) begin
            logic [63:0] w0;
            w0 = mem[(COMP_BASE + idx*16)>>3];
            $fdisplay(out_f, "W comp %0d tag=%04x", idx, w0[63:48]);
        end
        begin
            logic [63:0] w0;
            w0 = mem[(COMP_BASE + 255*16)>>3];
            $fdisplay(out_f, "W comp 255 tag=%04x", w0[63:48]);
        end

        $fclose(out_f);
        repeat (10) @(posedge clk);
        $display("=== DONE: все сценарии исполнены ===");
        $finish;
    end

endmodule