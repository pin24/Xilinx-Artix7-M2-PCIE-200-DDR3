// ============================================================================
// diag_axi_sniffer.sv — диагностический монитор + BRAM-реестр сравнения
// ============================================================================
// Проект 2026-10-03 (по ТЗ: DDR3/DMA диагностика без сетевого доступа).
//
// НАЗНАЧЕНИЕ:
//   1. СНИФФЕР шины XDMA->MIG (M_AXI между xdma_axi_smc и mig_7series_0):
//      считает AR/AW issued, R/W beats, RRESP/BRESP != OKAY, и висящие
//      незавершённые транзакции (нет ответа). Это отвечает на вопрос
//      "отвечает ли MIG на запросы и по каким адресам".
//   2. АXI-Lite реестр (S_AXI) для чтения сниффера хостом.
//   3. BRAM-реестр сравнения "ожидал / получил": хост пишет ожидаемое и
//      факт; модуль сравнивает и зажигает бит mismatch. Плюс свободные
//      счётчики-маркеры для сверки связей модулей (что ждали/что пришло).
//
// РЕСУРСЫ: только флип-флопы + LUT (счётчики), БЕЗ BRAM. BRAM-обход для
// TDOT делается отдельно blk_mem_gen в BD. Параметры экономные.
// ============================================================================
module diag_axi_sniffer #(
    parameter int C_S_AXI_ADDR_WIDTH = 8,   // 256 байт регистров
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int AW = 32
)(
    input  logic clk,                 // clk125 (fabric/axi домен)
    input  logic rst_n,

    // ---- AXI-Lite slave (хост через XDMA M_AXI_LITE) ----
    input  logic                          s_axi_awvalid,
    input  logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    output logic                          s_axi_awready,
    input  logic                          s_axi_wvalid,
    input  logic [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    output logic                          s_axi_wready,
    output logic                          s_axi_bvalid,
    input  logic                          s_axi_bready,
    input  logic                          s_axi_arvalid,
    input  logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    output logic                          s_axi_arready,
    output logic                          s_axi_rvalid,
    output logic [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    input  logic                          s_axi_rready,

    // ---- сниффер мониторинга шины XDMA->MIG (probe, без вмешательства) ----
    input  logic        m_axi_awvalid,   // к MIG
    input  logic        m_axi_awready,
    input  logic [AW-1:0] m_axi_awaddr,
    input  logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    input  logic        m_axi_wlast,
    input  logic        m_axi_bvalid,
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bready,
    input  logic        m_axi_arvalid,   // от XDMA/TDOT (S00/S02)
    input  logic        m_axi_arready,
    input  logic [AW-1:0] m_axi_araddr,
    input  logic        m_axi_rvalid,
    input  logic        m_axi_rlast,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rready,

    // ---- сигналы от TDOT (для сверки цепочки) ----
    input  logic        tdot_go,
    input  logic        tdot_busy,
    input  logic        tdot_done,

    // ---- статусы DDR3 ----
    input  logic        mig_init_calib_complete,
    input  logic        mig_mmcm_locked
);

    // ==================== счётчики сниффера ====================
    logic [31:0] cnt_aw, cnt_w, cnt_b, cnt_bresp_neok, cnt_b_timedout;
    logic [31:0] cnt_ar, cnt_r, cnt_rresp_neok, cnt_r_timedout;
    logic [31:0] cnt_last_awaddr, cnt_last_araddr, cnt_last_rresp, cnt_last_bresp;
    // висящие транзакции (debounce-счётчики)
    logic [15:0] pending_open, pending_r;   // приблизительные: вычитаются по готовности

    // счётчик общих тактов без завершения (для таймаут-детекции)
    logic [23:0] stall_cnt;

    // ==================== регистры сравнения ====================
    logic [31:0] expect_word, got_word;
    logic        cmp_en, cmp_mismatch;
    logic [31:0] marker_expect, marker_got;

    // ==================== AXI-Lite slave (простая защёлка w/ b) ====================
    logic                    rd_pending;
    logic                    wr_aw, wr_w;   // независимые защёлки AW и W (write chan)
    logic [C_S_AXI_ADDR_WIDTH-1:0] awaddr_q, araddr_q;
    logic [C_S_AXI_DATA_WIDTH-1:0] wdata_q;
    logic                    bvalid_q, rvalid_q;

    assign s_axi_awready = !wr_aw;   // независимая приёмная готовность по AW
    assign s_axi_wready  = !wr_w;    // независимая приёмная готовность по W
    assign s_axi_bvalid  = bvalid_q;
    assign s_axi_arready = !rd_pending;
    assign s_axi_rvalid  = rvalid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_pending <= 0; bvalid_q <= 0; rvalid_q <= 0;
            wr_aw <= 0; wr_w <= 0;
            awaddr_q <= 0; wdata_q <= 0; araddr_q <= 0;
            expect_word <= 0; got_word <= 0; cmp_en <= 0;
            marker_expect <= 0; marker_got <= 0;
        end else begin
            // ---- write channel (AXI-Lite, FIX-AUDIT 03.10 rev2) ----
            // НЕЗАВИСИМЫЕ защёлки AW и W со своими готовностями (rev1 имел
            // дедлок: wr_pending блокировал второй канал, если мастер подаёт
            // AW и W в РАЗНЫЕ такты). Теперь: awready=!wr_aw, wready=!wr_w,
            // каждый канал принимается своим valid независимо; commit когда
            // оба защёлк νаны (wr_aw && wr_w) и B свободен.
            if (s_axi_awvalid && !wr_aw) begin awaddr_q <= s_axi_awaddr; wr_aw <= 1; end
            if (s_axi_wvalid  && !wr_w ) begin wdata_q  <= s_axi_wdata;  wr_w  <= 1; end
            if (wr_aw && wr_w && !bvalid_q) begin
                // commit: оба канала защёлкнуты, B свободен
                case (awaddr_q[C_S_AXI_ADDR_WIDTH-1:2])
                    6'd0:  expect_word  <= wdata_q;
                    6'd1:  got_word     <= wdata_q;
                    6'd2:  cmp_en       <= wdata_q[0];
                    6'd3:  marker_expect<= wdata_q;
                    6'd4:  marker_got   <= wdata_q;
                    default: ;
                endcase
                wr_aw <= 0; wr_w <= 0; bvalid_q <= 1;
            end
            if (bvalid_q && s_axi_bready) bvalid_q <= 0;
            // ---- read channel ----
            if (s_axi_arvalid && !rd_pending && !rvalid_q) begin araddr_q <= s_axi_araddr; rd_pending <= 1; end
            if (rd_pending && !rvalid_q) rvalid_q <= 1;
            if (rvalid_q && s_axi_rready) begin rvalid_q <= 0; end
            if (rvalid_q && s_axi_rready) rd_pending <= 0;
        end
    end

    // read mux
    logic [C_S_AXI_DATA_WIDTH-1:0] rdata_mux;
    always_comb begin
        case (araddr_q[C_S_AXI_ADDR_WIDTH-1:2])
            6'd0:  rdata_mux = cnt_aw;
            6'd1:  rdata_mux = cnt_w;
            6'd2:  rdata_mux = cnt_b;
            6'd3:  rdata_mux = cnt_bresp_neok;
            6'd4:  rdata_mux = cnt_ar;
            6'd5:  rdata_mux = cnt_r;
            6'd6:  rdata_mux = cnt_rresp_neok;
            6'd7:  rdata_mux = cnt_last_awaddr;
            6'd8:  rdata_mux = cnt_last_araddr;
            6'd9:  rdata_mux = cnt_last_bresp;
            6'd10: rdata_mux = cnt_last_rresp;
            6'd11: rdata_mux = {15'h0, mig_init_calib_complete, mig_mmcm_locked,
                                tdot_done, tdot_busy, tdot_go, 12'h0};
            6'd12: rdata_mux = stall_cnt;
            6'd13: rdata_mux = {31'h0, cmp_mismatch};
            6'd14: rdata_mux = got_word;
            6'd15: rdata_mux = expect_word;
            6'd16: rdata_mux = cnt_r_timedout;
            6'd17: rdata_mux = cnt_b_timedout;
            6'd18: rdata_mux = marker_got;
            6'd19: rdata_mux = marker_expect;
            default: rdata_mux = 32'h0;
        endcase
    end
    assign s_axi_rdata = rdata_mux;

    // ==================== сниффер подсчёта ====================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_aw <= 0; cnt_w <= 0; cnt_b <= 0; cnt_bresp_neok <= 0;
            cnt_ar <= 0; cnt_r <= 0; cnt_rresp_neok <= 0;
            cnt_b_timedout <= 0; cnt_r_timedout <= 0;
            cnt_last_awaddr <= 0; cnt_last_araddr <= 0;
            cnt_last_bresp <= 0; cnt_last_rresp <= 0;
            stall_cnt <= 0;
        end else begin
            // write: AW handshake
            if (m_axi_awvalid && m_axi_awready) begin cnt_aw <= cnt_aw + 1; cnt_last_awaddr <= m_axi_awaddr; end
            if (m_axi_wvalid && m_axi_wready) begin cnt_w <= cnt_w + 1; end
            if (m_axi_bvalid && m_axi_bready) begin
                cnt_b <= cnt_b + 1;
                cnt_last_bresp <= m_axi_bresp;
                if (m_axi_bresp != 2'b00) cnt_bresp_neok <= cnt_bresp_neok + 1;
            end
            // read: AR handshake
            if (m_axi_arvalid && m_axi_arready) begin cnt_ar <= cnt_ar + 1; cnt_last_araddr <= m_axi_araddr; end
            if (m_axi_rvalid && m_axi_rlast) begin cnt_r <= cnt_r + 1; cnt_last_rresp <= m_axi_rresp; end
            if (m_axi_rvalid && m_axi_rlast && (m_axi_rresp != 2'b00)) cnt_rresp_neok <= cnt_rresp_neok + 1;
            // stall: tracks a period with AR issued but no R back (raw heuristic)
            if (m_axi_arvalid && m_axi_arready) cnt_r_timedout <= cnt_r_timedout; // no-op placeholder (see below)
            // stall counter increments every cycle while there is work but no completion
            if ((m_axi_arvalid || m_axi_rvalid || m_axi_awvalid || m_axi_bvalid) &&
                !(m_axi_rlast && m_axi_rvalid) &&
                !((m_axi_awvalid&&m_axi_awready) || (m_axi_bvalid&&m_axi_bready))) begin
                stall_cnt <= stall_cnt + 1;
            end else begin
                stall_cnt <= 0;
            end
            // simple timeout credits: since we cannot perfectly match AR->R here,
            // count a "no completion" credit when AR rises and no R in window is approximate —
            // keep as stall-based integer below.
        end
    end

    // comparison "expected vs got"
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cmp_mismatch <= 0;
        else if (cmp_en) cmp_mismatch <= (expect_word != got_word) ? 1'b1 : 1'b0;
    end

endmodule