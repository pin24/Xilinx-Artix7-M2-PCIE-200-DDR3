// ============================================================================
// tb_tdot_sched.sv - RTL-верификация аппаратного ПЛАНИРОВЩИКА tdot_axi4
// ============================================================================
// Эмуляция xsim. Модель памяти (read+write, burst INCR) как в tb_tdot_axi4.
// Сценарии:
//   A) 4 задачи (n=8, n=16, n=8, n=24, все data=weights=1.0) с ОДНИМ
//      doorbell SCHED_WPTR=4. Движок должен сам взять задачу 1, DONE,
//      записать completion + результат, инкремент DONE_CNT, взять задачу 2
//      БЕЗ нового GO и т.д. Ожидаем dot = n. IRQ должен подняться при
//      опустошении кольца.
//   B) REARM: irq_ack, ещё 2 задачи (n=8, tag 0xAAAA/0xBBBB), doorbell 6,
//      проверка продолжения кольца (rptr 4->6, DONE_CNT=6).
// Выход пишется в sim/sched_out.hex, проверяется python-скриптом.
// ============================================================================
module tb_tdot_sched;

    // Собранная конфигурация (xdma_ddr3_core_top.sv): NUM_MAC=16, ADDERS=4
    parameter int NUM_MAC = 16;
    parameter int ADDERS  = 4;

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
        .BURST_RD_LEN(16), .BURST_WR_LEN(8)
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

    // ---------------- AXI slave: read path (как tb_tdot_axi4) ----------------
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

    // ---------------- AXI slave: write path (как tb_tdot_axi4) ----------------
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

    // ---------------- helper: заполнение descriptor в памяти ----------------
    task put_desc(input integer slot, input [47:0] da, input [47:0] wa,
                  input [47:0] ra, input [15:0] n, input [15:0] tag);
        integer base;
        begin
            base = 32'h0000_0000 + slot*32;   // DESC_BASE
            mem[base>>3]      = {16'h0, da};
            mem[(base+8)>>3]  = {16'h0, wa};
            mem[(base+16)>>3] = {16'h0, ra};
            mem[(base+24)>>3] = {n, tag};
        end
    endtask

    // ---------------- тест ----------------
    logic [31:0] rd;
    logic [63:0] wdata;
    integer slot, idx, loops;
    integer out_f;
    logic [31:0] done_cnt, rptr, status;

    initial begin
        S_AXI_AWADDR = 0; S_AXI_AWVALID = 0; S_AXI_WDATA = 0; S_AXI_WSTRB = 0;
        S_AXI_WVALID = 0; S_AXI_BREADY = 0;
        S_AXI_ARADDR = 0; S_AXI_ARVALID = 0; S_AXI_RREADY = 0;
        for (i = 0; i < 131072; i = i + 1) mem[i] = 64'h0;

        // ---- загрузка памяти из sched_mem_init.hex (addr data) ----
        begin
            integer a;
            logic [63:0] v;
            f = $fopen("sched_mem_init.hex", "r");
            if (f == 0) begin $display("ERROR: no sched_mem_init.hex"); $finish; end
            i = 0;
            while (!$feof(f)) begin
                if ($fscanf(f, "%h %h\n", a, v) != 2) break;
                mem[a>>3] = v;
                i = i + 1;
            end
            $fclose(f);
            $display("Loaded %0d mem words from sched_mem_init.hex", i);
        end

        repeat (10) @(posedge clk);
        rst_n <= 1;
        repeat (10) @(posedge clk);

        out_f = $fopen("sim/sched_out.hex","w");

        // ================= Сценарий A: базовая очередь из 4 задач =============
        $display("=== A: установка планировщика ===");
        axi_lite_write(8'h40, 32'h4);          // flush (reset rptr)
        axi_lite_write(8'h4C, 32'h0000_0000);  // DESC_BASE_LO = 0x0
        axi_lite_write(8'h50, 32'h0000_0000);  // DESC_BASE_HI
        axi_lite_write(8'h54, 32'h0000_4000);  // COMP_BASE_LO = 0x4000
        axi_lite_write(8'h58, 32'h0000_0000);  // COMP_BASE_HI
        axi_lite_write(8'h40, 32'h3);          // sched_en=1, irq_en=1 (flush 0)
        axi_lite_write(8'h44, 32'h4);          // doorbell WPTR = 4 задач

        // ждём завершения: DONE_CNT >= 4
        loops = 0;
        axi_lite_read(8'h60, done_cnt);
        while (done_cnt < 4) begin
            repeat (200) @(posedge clk);
            axi_lite_read(8'h60, done_cnt);
            loops = loops + 1;
            if (loops > 200) begin
                $display("A TIMEOUT: DONE_CNT=%0d", done_cnt);
                $display("  status=%08h rptr=%08h irq=%b busy=%b",
                         rd, rptr, sched_irq, diag_busy);
                $finish;
            end
        end

        axi_lite_read(8'h48, rptr);   // SCHED_RPTR
        axi_lite_read(8'h60, done_cnt);
        axi_lite_read(8'h5C, status);
        $display("=== A: DONE. RPTR=%0d DONE_CNT=%0d STATUS=%08h sched_irq=%b",
                 rptr, done_cnt, status, sched_irq);
        $fdisplay(out_f, "A rptr=%0d done_cnt=%0d status=%08x sched_irq=%b",
                  rptr, done_cnt, status, sched_irq);
        $fdisplay(out_f, "A irq_state irq_pending=%b sched_irq=%b",
                  status[1], sched_irq);

        // результат, записанный ядром в отдельные result_addr (помимо completion)
        for (idx = 0; idx < 4; idx = idx + 1) begin
            logic [63:0] rw;
            rw = mem[(32'h0000_3000 + idx*32'h100)>>3];
            $display("A result_addr[%0d]=%012h", idx, rw[47:0]);
            $fdisplay(out_f, "A res_mem %0d=%012x", idx, rw[47:0]);
        end

        // снять completion (4 записи по 16Б) из памяти
        for (idx = 0; idx < 4; idx = idx + 1) begin
            logic [63:0] w0, w1;
            w0 = mem[(32'h0000_4000 + idx*16)>>3];
            w1 = mem[(32'h0000_4000 + idx*16 + 8)>>3];
            $display("A comp[%0d]: tag=%04h result=%012h status=%02h passes=%0d",
                     idx, w0[63:48], w0[47:0], w1[7:0], w1[15:8]);
            $fdisplay(out_f, "A comp %0d tag=%04x result=%012x sat=%b align=%b passes=%0d",
                      idx, w0[63:48], w0[47:0], w1[0], w1[1], w1[15:8]);
        end

        // ================= Сценарий B: IRQ-ack + подливка ещё 2 задач ========
        $display("=== B: irq_ack + ре-арм ===");
        if (!status[1] || !sched_irq)
            $display("B WARN: irq_pending не поднят (status=%08h sched_irq=%b) — ожидали IRQ при опустошении",
                     status, sched_irq);
        axi_lite_write(8'h40, 32'h3 | (1<<3));   // irq_ack (и сохранить en/irq_en)
        // проверить, что irq_pending сброшен
        axi_lite_read(8'h5C, status);
        $display("B после irq_ack: STATUS=%08h sched_irq=%b", status, sched_irq);
        $fdisplay(out_f, "B irq_ack done status=%08x sched_irq=%b", status, sched_irq);

        // подливка 2 задач: списать descriptor slot 4,5, данные в region 0x1400/0x1500
        // (заполним 8 слов 1.0 в data/wgt)
        for (i = 0; i < 8; i = i + 1) begin
            mem[(32'h0000_1400 + i*8)>>3] = 64'h0000001000000000;  // 1.0 data
            mem[(32'h0000_1500 + i*8)>>3] = 64'h0000001000000000;  // 1.0 weights
        end
        put_desc(4, 32'h0000_1400, 32'h0000_1500, 32'h0000_3400, 16'd8, 16'hAAAA);
        put_desc(5, 32'h0000_1400, 32'h0000_1500, 32'h0000_3500, 16'd8, 16'hBBBB);
        axi_lite_write(8'h44, 32'h6);    // doorbell WPTR = 6

        loops = 0;
        axi_lite_read(8'h60, done_cnt);
        while (done_cnt < 6) begin
            repeat (200) @(posedge clk);
            axi_lite_read(8'h60, done_cnt);
            loops = loops + 1;
            if (loops > 200) begin
                $display("B TIMEOUT: DONE_CNT=%0d", done_cnt); $finish;
            end
        end
        axi_lite_read(8'h48, rptr);
        axi_lite_read(8'h60, done_cnt);
        axi_lite_read(8'h5C, status);
        $display("=== B: DONE. RPTR=%0d DONE_CNT=%0d STATUS=%08h", rptr, done_cnt, status);
        $fdisplay(out_f, "B rptr=%0d done_cnt=%0d status=%08x", rptr, done_cnt, status);
        for (idx = 4; idx < 6; idx = idx + 1) begin
            logic [63:0] w0, w1;
            w0 = mem[(32'h0000_4000 + idx*16)>>3];
            w1 = mem[(32'h0000_4000 + idx*16 + 8)>>3];
            $display("B comp[%0d]: tag=%04h result=%012h status=%02h passes=%0d",
                     idx, w0[63:48], w0[47:0], w1[7:0], w1[15:8]);
            $fdisplay(out_f, "B comp %0d tag=%04x result=%012x sat=%b align=%b passes=%0d",
                      idx, w0[63:48], w0[47:0], w1[0], w1[1], w1[15:8]);
        end
        $fclose(out_f);

        // ================= Результаты из регистровых зеркал (CORE_RES) =======
        axi_lite_read(8'h2C, rd); // CORE_RES0 (последней задачи)
        $display("CORE_RES0(last)=%08h", rd);
        $fdisplay(out_f, "CORE_RES0=%08x", rd);

        repeat (10) @(posedge clk);
        $display("=== PASS: планировщик отработал 6 задач без GO ===");
        $finish;
    end

endmodule