// ============================================================================
// icap_ctrl.sv — ICAP-контроллер: хост пишет слова напрямую в DATA
// ============================================================================
// Регистры (32-бит, байтовый адрес, декод [3:2]):
//   [0x00] CTRL   bit0 GO (самосброс), bit1 STOP
//   [0x04] STATUS bit0 READY (mailbox свободен - можно писать следующее слово),
//                 bit1 BUSY (сессия: от GO до STOP)
//   [0x08] DATA   write-only, 32-бит слово для ICAP
//
// Протокол работы:
//   1. Хост пишет CTRL.GO=1 -> BUSY=1.
//   2. Хост ждёт STATUS.READY=1 (READY=1 и до GO).
//   3. Хост пишет слова битстрима по одному в DATA; после каждой записи
//      контроллер делает ОДНО окно выборки (CSIB=0 ровно на 1 такт icap_clk),
//      затем READY=1 снова. Каждое слово доставляется в ICAP ровно один раз.
//   4. Битстрим заканчивается словами DESYNC (уже в файле .bin).
//   5. Хост пишет CTRL.STOP=1 -> BUSY=0, CSIB принудительно поднимается.
//
// ПОРЯДОК БАЙТОВ: ICAPE2 в режиме X32 потребляет байты слова от I[7:0] вверх
// (первый байт битстрима должен оказаться на I[7:0]). Поэтому ХОСТ преобразует
// каждое 32-битное big-endian слово битстрима в little-endian (bswap32) перед
// записью в DATA (см. pytorch_layer/icap_load.py: чтение .bin как "<I").
// RTL передаёт слова на I БЕЗ преобразований.
//
// Тактирование: S_AXI_ACLK = 125 МГц (AXI-домен) превышает максимум ICAPE2
// (100 МГц), поэтому ICAPE2 тактируется делёным клоком: BUFGCE_DIV /2 ->
// icap_clk = 62.5 МГц (Vivado создаёт generated clock автоматически).
// Между доменами - toggle-handshake (req/ack, go/stop) с 2FF-синхронизаторами
// (* ASYNC_REG *). Слово DATA стабильно весь цикл передачи: fast-домен не
// меняет word_q до возврата ack. Записи DATA во время занятого mailbox не
// теряются: AXI-коммит в DATA задерживается (AW/W защёлки держатся, шина
// получает backpressure) до освобождения mailbox.
//
// Ссылки: UG470 (7 Series Configuration, ICAP), UG472 (Clocking, BUFGCE_DIV).
// ============================================================================
module icap_ctrl #(
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int C_S_AXI_ADDR_WIDTH = 8
)(
    input  logic                                  S_AXI_ACLK,
    input  logic                                  S_AXI_ARESETN,
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]         S_AXI_AWADDR,
    input  logic                                  S_AXI_AWPROT,
    input  logic                                  S_AXI_AWVALID,
    output logic                                  S_AXI_AWREADY,
    input  logic [C_S_AXI_DATA_WIDTH-1:0]         S_AXI_WDATA,
    input  logic [C_S_AXI_DATA_WIDTH/8-1:0]       S_AXI_WSTRB,
    input  logic                                  S_AXI_WVALID,
    output logic                                  S_AXI_WREADY,
    output logic [1:0]                            S_AXI_BRESP,
    output logic                                  S_AXI_BVALID,
    input  logic                                  S_AXI_BREADY,
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]         S_AXI_ARADDR,
    input  logic                                  S_AXI_ARPROT,
    input  logic                                  S_AXI_ARVALID,
    output logic                                  S_AXI_ARREADY,
    output logic [C_S_AXI_DATA_WIDTH-1:0]         S_AXI_RDATA,
    output logic [1:0]                            S_AXI_RRESP,
    output logic                                  S_AXI_RVALID,
    input  logic                                  S_AXI_RREADY
);

    localparam int ADDR_LSB = 2;

    // ==================== mailbox (fast-домен) ==================================
    logic [C_S_AXI_DATA_WIDTH-1:0] word_q;  // активное слово (стабильно на цикл передачи)
    logic in_flight;                        // слово в slow-домене, ack не вернулся
    logic req_toggle;                       // fast -> slow: новое слово
    logic ack_toggle;                       // slow -> fast: слово доставлено
    logic ack_toggle_prev;
    // CDC slow→fast: 2FF синхронизаторы с ASYNC_REG для Vivado CDC analyzer
    // (без ASYNC_REG Vivado может разместить FF разрозненно, что увеличивает
    // риск метастабильности при 125 МГц → 62.5 МГц переходе)
    (* ASYNC_REG = "TRUE" *) logic ack_sync_ff1, ack_sync_ff2;
    (* ASYNC_REG = "TRUE" *) logic busy_sync_ff1, busy_sync_ff2;     // BUSY (slow -> fast, для STATUS)

    wire mbox_busy = in_flight;             // занят mailbox (гейт commit в DATA)

    // ==================== AXI-Lite slave (fast-домен 125 МГц) ===================
    // Независимый приём AW и W (защёлки глубиной 1): фазы могут приходить в
    // разных тактах - запись коммитится, когда собраны обе и bvalid свободен.
    logic awready, wready, bvalid;
    logic aw_latched, w_latched;
    logic [C_S_AXI_ADDR_WIDTH-1:0] awaddr_q;
    logic [C_S_AXI_DATA_WIDTH-1:0] wdata_q;

    wire aw_hs = S_AXI_AWVALID && awready;
    wire w_hs  = S_AXI_WVALID  && wready;

    // коммит в DATA разрешён только при свободном mailbox; при занятом -
    // защёлки AW/W держатся, шина получает backpressure
    wire wr_commit_en = (awaddr_q[ADDR_LSB+:2] != 2'd2) || !mbox_busy;
    wire wr_commit = aw_latched && w_latched && !bvalid && wr_commit_en;

    wire aw_latched_n = aw_hs ? 1'b1 : (wr_commit ? 1'b0 : aw_latched);
    wire w_latched_n  = w_hs  ? 1'b1 : (wr_commit ? 1'b0 : w_latched);
    wire bvalid_n     = wr_commit ? 1'b1 :
                        (bvalid && S_AXI_BREADY) ? 1'b0 : bvalid;
    wire wr_commit_n  = aw_latched_n && w_latched_n && !bvalid_n;

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            awready <= 0; wready <= 0; bvalid <= 0;
            aw_latched <= 0; w_latched <= 0;
            awaddr_q <= 0; wdata_q <= 0;
        end else begin
            if (aw_hs) awaddr_q <= S_AXI_AWADDR;
            if (w_hs)  wdata_q  <= S_AXI_WDATA;
            aw_latched <= aw_latched_n;
            w_latched  <= w_latched_n;
            bvalid     <= bvalid_n;
            awready <= !aw_latched_n || wr_commit_n;
            wready  <= !w_latched_n  || wr_commit_n;
        end
    end

    // ==================== read channel ==========================================
    logic arready, rvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] araddr_q;
    wire ar_hs = S_AXI_ARVALID && arready;
    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            arready <= 0; rvalid <= 0; araddr_q <= 0;
        end else begin
            if (S_AXI_ARVALID && !arready && !rvalid) begin
                arready <= 1;
            end else begin
                arready <= 0;
            end
            if (ar_hs) begin
                araddr_q <= S_AXI_ARADDR;
                rvalid   <= 1;
            end else if (rvalid && S_AXI_RREADY) begin
                rvalid <= 0;
            end
        end
    end

    // ==================== CTRL/STATUS (fast-домен) ==============================
    logic go_reg, stop_reg;
    logic go_toggle, stop_toggle;       // toggle-флаги для CDC в slow-домен

    wire wr_commit_ctrl = wr_commit && (awaddr_q[ADDR_LSB+:2] == 2'd0);
    wire wr_commit_data = wr_commit && (awaddr_q[ADDR_LSB+:2] == 2'd2);

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            go_reg <= 0; stop_reg <= 0;
            go_toggle <= 0; stop_toggle <= 0;
        end else begin
            if (wr_commit_ctrl) begin
                go_reg   <= wdata_q[0];
                stop_reg <= wdata_q[1];
            end else begin
                go_reg   <= 0;   // самосброс
                stop_reg <= 0;
            end
            if (wr_commit_ctrl && wdata_q[0]) go_toggle   <= ~go_toggle;
            if (wr_commit_ctrl && wdata_q[1]) stop_toggle <= ~stop_toggle;
        end
    end

    // ==================== mailbox: приём слов (fast-домен) ======================
    wire ack_edge = (ack_sync_ff2 != ack_toggle_prev); // вернулся ack

    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            word_q <= 0; in_flight <= 0;
            req_toggle <= 0;
            ack_toggle_prev <= 0;
            ack_sync_ff1 <= 0; ack_sync_ff2 <= 0;
        end else begin
            // 2FF синхронизатор ack (slow -> fast)
            ack_sync_ff1    <= ack_toggle;
            ack_sync_ff2    <= ack_sync_ff1;
            ack_toggle_prev <= ack_sync_ff2;

            // in_flight: новая запись имеет приоритет над возвратом ack
            if (wr_commit_data) in_flight <= 1;
            else if (ack_edge)  in_flight <= 0;

            // загрузка активного слота (только при свободном mailbox)
            if (wr_commit_data) begin
                word_q     <= wdata_q;
                req_toggle <= ~req_toggle;
            end
        end
    end

    assign S_AXI_AWREADY = awready;
    assign S_AXI_WREADY  = wready;
    assign S_AXI_BRESP   = 2'b00;
    assign S_AXI_BVALID  = bvalid;
    assign S_AXI_ARREADY = arready;
    assign S_AXI_RRESP   = 2'b00;
    assign S_AXI_RVALID  = rvalid;

    logic [C_S_AXI_DATA_WIDTH-1:0] rdata;
    always_comb begin
        case (araddr_q[ADDR_LSB+:2])
            2'd0: rdata = {30'b0, stop_reg, go_reg};
            2'd1: rdata = {30'b0, busy_sync_ff2, !mbox_busy}; // {BUSY, READY}
            default: rdata = 32'h0;
        endcase
    end
    assign S_AXI_RDATA = rdata;

    // ==================== slow-домен (icap_clk = 62.5 МГц) ======================
    // Artix-7: BUFGCE_DIV не поддерживается. Делим S_AXI_ACLK (125 МГц) на 2
    // через register с BUFG, получаем icap_clk = 62.5 МГц.
    logic icap_clk_int;
    logic icap_clk;
    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) icap_clk_int <= 0;
        else                icap_clk_int <= ~icap_clk_int;
    end
    BUFG u_icap_bufg (.I(icap_clk_int), .O(icap_clk));

    // сброс slow-домена (async assert, sync deassert к icap_clk)
    logic icap_rst_n;
    always_ff @(posedge icap_clk or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) icap_rst_n <= 0;
        else               icap_rst_n <= 1;
    end

    (* ASYNC_REG = "TRUE" *) logic req_sync_ff1, req_sync_ff2, req_prev;
    (* ASYNC_REG = "TRUE" *) logic go_sync_ff1, go_sync_ff2, go_prev;
    (* ASYNC_REG = "TRUE" *) logic stop_sync_ff1, stop_sync_ff2, stop_prev;
    logic busy_q;
    logic icap_cs, icap_rw;
    logic [C_S_AXI_DATA_WIDTH-1:0] icap_data;

    always_ff @(posedge icap_clk or negedge icap_rst_n) begin
        if (!icap_rst_n) begin
            req_sync_ff1 <= 0; req_sync_ff2 <= 0; req_prev <= 0;
            go_sync_ff1 <= 0; go_sync_ff2 <= 0; go_prev <= 0;
            stop_sync_ff1 <= 0; stop_sync_ff2 <= 0; stop_prev <= 0;
            busy_q <= 0;
            ack_toggle <= 0;
            icap_cs <= 1; icap_rw <= 1; icap_data <= 0;
        end else begin
            // 2FF синхронизаторы toggle-флагов (fast -> slow)
            req_sync_ff1  <= req_toggle;  req_sync_ff2  <= req_sync_ff1;
            go_sync_ff1   <= go_toggle;   go_sync_ff2   <= go_sync_ff1;
            stop_sync_ff1 <= stop_toggle; stop_sync_ff2 <= stop_sync_ff1;

            // окно выборки: на req-edge открываем CSIB на РОВНО 1 такт
            if (req_sync_ff2 != req_prev) begin
                req_prev   <= req_sync_ff2;
                icap_data  <= word_q;    // слово стабильно весь цикл (handshake)
                icap_cs    <= 0;
                icap_rw    <= 0;
                ack_toggle <= ~ack_toggle;
            end else begin
                icap_cs <= 1;
                icap_rw <= 1;
            end

            // STOP перекрывает окно: принудительно закрываем
            if (stop_sync_ff2 != stop_prev) begin
                stop_prev <= stop_sync_ff2;
                busy_q    <= 0;
                icap_cs   <= 1;
                icap_rw   <= 1;
            end else if (go_sync_ff2 != go_prev) begin
                go_prev <= go_sync_ff2;
                busy_q  <= 1;            // сессия начата
            end
        end
    end

    // STATUS.BUSY: slow -> fast (2FF)
    always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            busy_sync_ff1 <= 0; busy_sync_ff2 <= 0;
        end else begin
            busy_sync_ff1 <= busy_q;
            busy_sync_ff2 <= busy_sync_ff1;
        end
    end

    // ==================== ICAPE2 ================================================
    ICAPE2 #(
        .ICAP_WIDTH("X32"),
        .SIM_CFG_FILE_NAME("NONE")
    ) u_icap (
        .O(),                // статусная шина не используется
        .CLK(icap_clk),      // 62.5 МГц (лимит ICAPE2 для Artix-7: 100 МГц)
        .CSIB(icap_cs),
        .I(icap_data),
        .RDWRB(icap_rw)
    );

endmodule
