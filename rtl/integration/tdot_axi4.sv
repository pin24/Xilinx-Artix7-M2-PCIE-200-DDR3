// ============================================================================
// tdot_axi4.sv - ПОЛНЫЙ AXI4-мастер вокруг compute_dot_par_raw (TFloat48)
// ============================================================================
// Ядро САМО читает векторы data/weights из DDR3 (или BRAM) через AXI4
// (INCR-burst), вычисляет dot и пишет результат обратно в память.
//
// Адресное пространство (карта из BD):
//   BRAM     0x0000_0000 .. 0x0000_1FFF
//   DDR3     0x8000_0000 .. 0x8FFF_FFFF   (256 МБ)
//
// Формат данных в памяти: каждый TFloat48 занимает 64-битное слово
// (распакованный формат 8 байт/элемент), старшие 16 бит слова не используются:
//   data[i]     по адресу data_start    + i*8
//   weights[i]  по адресу weights_start + i*8
//   результат   по адресу result_addr   (64-битное слово, младшие 48 бит)
//
// Регистры (32-бит, байтовый адрес, из S_AXI):
//   [0x00] CTRL    бит0 GO (самосброс через такт)
//   [0x04] STATUS  бит0 BUSY, бит1 DONE
//   [0x08] N_IN    число пар (1..NUM_MAC)
//   [0x0C] RES0    результат [31:0]            (DONE)
//   [0x10] RES1    {16'h0, результат[47:32]}   (DONE)
//   [0x14] DATA_ADDR_LO    data_start[31:0]
//   [0x18] DATA_ADDR_HI    data_start[63:32]
//   [0x1C] WEIGHTS_ADDR_LO weights_start[31:0]
//   [0x20] WEIGHTS_ADDR_HI weights_start[63:32]
//   [0x24] RESULT_ADDR_LO  result_addr[31:0]
//   [0x28] RESULT_ADDR_HI  result_addr[63:32]
//   [0x2C] CORE_RES0 результат [31:0], [0x30] CORE_RES1 {16'h0, результат[47:32]}
//                  - read-only зеркала результата ядра
//
// Протокол работы (GO=1):
//   (1) burst-чтение N_IN слов data    (по BURST_RD_LEN слов/транзакция)
//   (2) burst-чтение N_IN слов weights
//   (3) загрузка в compute_dot_par_raw (неиспользуемые MAC-слоты = 0)
//   (4) вычисление (valid_in -> valid_out)
//   (5) запись результата (1 слово) по result_addr
//   (6) DONE=1, BUSY=0
//
// Часы: S_AXI_ACLK и M_AXI_ACLK должны быть ОДНИМ сигналом (в интеграции оба
// = axi_aclk). CDC между AXI-Lite-регистрами и мастером не предусмотрен.
// ============================================================================
module tdot_axi4 #(
    parameter int NUM_MAC = 32,
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int C_S_AXI_ADDR_WIDTH = 8,
    parameter int C_M_AXI_ID_WIDTH   = 1,
    parameter int C_M_AXI_ADDR_WIDTH = 32,
    parameter int C_M_AXI_DATA_WIDTH = 64,
    parameter int BURST_RD_LEN = 16,   // макс. слов в одной read-транзакции
    parameter int BURST_WR_LEN = 8     // макс. слов в одной write-транзакции
)(
    // ---- AXI-Lite slave (регистры команд/статуса) ----
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
    input  logic                                  S_AXI_RREADY,

    // ---- AXI4 master (данные в DDR3/BRAM) ----
    input  logic                                  M_AXI_ACLK,
    input  logic                                  M_AXI_ARESETN,
    output logic [C_M_AXI_ID_WIDTH-1:0]           M_AXI_AWID,
    output logic [C_M_AXI_ADDR_WIDTH-1:0]         M_AXI_AWADDR,
    output logic [7:0]                            M_AXI_AWLEN,
    output logic [2:0]                            M_AXI_AWSIZE,
    output logic [1:0]                            M_AXI_AWBURST,
    output logic                                  M_AXI_AWLOCK,
    output logic [3:0]                            M_AXI_AWCACHE,
    output logic [2:0]                            M_AXI_AWPROT,
    output logic [3:0]                            M_AXI_AWQOS,
    output logic                                  M_AXI_AWVALID,
    input  logic                                  M_AXI_AWREADY,
    output logic [C_M_AXI_DATA_WIDTH-1:0]         M_AXI_WDATA,
    output logic [C_M_AXI_DATA_WIDTH/8-1:0]       M_AXI_WSTRB,
    output logic                                  M_AXI_WLAST,
    output logic                                  M_AXI_WVALID,
    input  logic                                  M_AXI_WREADY,
    input  logic [C_M_AXI_ID_WIDTH-1:0]           M_AXI_BID,
    input  logic [1:0]                            M_AXI_BRESP,
    input  logic                                  M_AXI_BVALID,
    output logic                                  M_AXI_BREADY,
    output logic [C_M_AXI_ID_WIDTH-1:0]           M_AXI_ARID,
    output logic [C_M_AXI_ADDR_WIDTH-1:0]         M_AXI_ARADDR,
    output logic [7:0]                            M_AXI_ARLEN,
    output logic [2:0]                            M_AXI_ARSIZE,
    output logic [1:0]                            M_AXI_ARBURST,
    output logic                                  M_AXI_ARLOCK,
    output logic [3:0]                            M_AXI_ARCACHE,
    output logic [2:0]                            M_AXI_ARPROT,
    output logic [3:0]                            M_AXI_ARQOS,
    output logic                                  M_AXI_ARVALID,
    input  logic                                  M_AXI_ARREADY,
    input  logic [C_M_AXI_ID_WIDTH-1:0]           M_AXI_RID,
    input  logic [C_M_AXI_DATA_WIDTH-1:0]         M_AXI_RDATA,
    input  logic [1:0]                            M_AXI_RRESP,
    input  logic                                  M_AXI_RLAST,
    input  logic                                  M_AXI_RVALID,
    output logic                                  M_AXI_RREADY
);

    localparam int AW    = C_M_AXI_ADDR_WIDTH;
    localparam int DW    = C_M_AXI_DATA_WIDTH;
    localparam int SW    = DW / 8;                  // байт в слове (8)
    localparam int AXI_SZ = $clog2(SW);             // 3 (8 байт)
    localparam int FIFO_DEPTH = 2 * NUM_MAC;        // хватает на обе выборки
    localparam int FIFO_PTRW = $clog2(FIFO_DEPTH);  // бит адреса FIFO
    localparam int RD_LEN_W = $clog2(BURST_RD_LEN);
    // NOTE: RD_LEN_W объявлен, но не используется в текущей логике. Оставлен
    // для будущих расширений (например, динамический BURST_RD_LEN).

    logic clk, rst_n;
    assign clk   = M_AXI_ACLK;
    assign rst_n = M_AXI_ARESETN;

    // ==================== ядро ====================
    logic [48*NUM_MAC-1:0] core_data, core_weights;
    logic core_valid_in, core_valid_out;
    logic [47:0] core_result;

    compute_dot_par_raw #(.NUM_MAC(NUM_MAC)) u_core (
        .clk(clk), .rst_n(rst_n),
        .data_in(core_data), .weights(core_weights), .valid_in(core_valid_in),
        .result_out(core_result), .valid_out(core_valid_out)
    );

    // ==================== регистры (AXI-Lite) ====================
    logic go_reg;
    logic [31:0] n_in_reg;
    logic [63:0] data_start_reg, weights_start_reg, result_addr_reg;
    logic [31:0] res0_reg, res1_reg;
    logic busy_q, done_q;

    // AXI-Lite write channel: приём AW и W НЕЗАВИСИМЫЙ, с защёлками глубиной 1.
    // Запись применяется (commit), когда защёлкнуты ОБА (адрес и данные),
    // а bvalid свободен. Это устраняет тупик/потерю записи, когда AWVALID
    // и WVALID не совпадают в одном такте.
    logic awready, wready, bvalid;
    logic aw_latched, w_latched;    // занятость защёлок адреса/данных
    logic [C_S_AXI_ADDR_WIDTH-1:0] awaddr_q;
    logic [C_S_AXI_DATA_WIDTH-1:0] wdata_q;

    wire aw_hs     = S_AXI_AWVALID && awready;            // handshake AW
    wire w_hs      = S_AXI_WVALID  && wready;             // handshake W
    wire wr_commit = aw_latched && w_latched && !bvalid;  // commit: оба защёлкнуты, B свободен

    // состояние на следующий такт (для формирования готовностей без тупиков)
    wire aw_latched_n = aw_hs ? 1'b1 : (wr_commit ? 1'b0 : aw_latched);
    wire w_latched_n  = w_hs  ? 1'b1 : (wr_commit ? 1'b0 : w_latched);
    wire bvalid_n     = wr_commit ? 1'b1 :
                        (bvalid && S_AXI_BREADY) ? 1'b0 : bvalid;
    wire wr_commit_n  = aw_latched_n && w_latched_n && !bvalid_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awready <= 0; wready <= 0; bvalid <= 0;
            aw_latched <= 0; w_latched <= 0;
            awaddr_q <= 0; wdata_q <= 0;
            go_reg <= 0; n_in_reg <= NUM_MAC;
            data_start_reg <= 0; weights_start_reg <= 0; result_addr_reg <= 0;
        end else begin
            // приём AW/W в защёлки по handshake каждого канала независимо
            if (aw_hs) awaddr_q <= S_AXI_AWADDR;
            if (w_hs)  wdata_q  <= S_AXI_WDATA;
            aw_latched <= aw_latched_n;   // handshake заполняет, commit освобождает
            w_latched  <= w_latched_n;
            bvalid     <= bvalid_n;       // ответ: выставляется по commit, сброс по BREADY
            // готовности: защёлка свободна ИЛИ освободится этим тактом (commit).
            // Если обе защёлки заняты и bvalid висит - готовности сняты,
            // пока не освободится место.
            awready <= !aw_latched_n || wr_commit_n;
            wready  <= !w_latched_n  || wr_commit_n;
            // применение записи из защёлок
            if (wr_commit) begin
                case (awaddr_q[5:2])
                    4'd0: begin
                        go_reg <= wdata_q[0];
                    end
                    4'd2: n_in_reg <= wdata_q;
                    4'd5: data_start_reg[31:0]    <= wdata_q;
                    4'd6: data_start_reg[63:32]   <= wdata_q;
                    4'd7: weights_start_reg[31:0] <= wdata_q;
                    4'd8: weights_start_reg[63:32]<= wdata_q;
                    4'd9: result_addr_reg[31:0]   <= wdata_q;
                    4'd10: result_addr_reg[63:32] <= wdata_q;
                    default: ;
                endcase
            end else if (go_reg) begin
                go_reg <= 0;   // самосброс GO
            end
        end
    end

    // AXI-Lite read channel: независимый приём AR (защёлка адреса), ответ
    // (rvalid + rdata) выставляется в следующем такте, сброс по rvalid && RREADY.
    // Новый AR не принимается, пока висит непрочитанный ответ.
    logic arready, rvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] araddr_q;
    wire ar_hs = S_AXI_ARVALID && arready;   // handshake AR
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arready <= 0; rvalid <= 0; araddr_q <= 0;
        end else begin
            // готовность к приёму AR: через такт после ARVALID и только
            // при отсутствии висящего ответа
            if (S_AXI_ARVALID && !arready && !rvalid) begin
                arready <= 1;
            end else begin
                arready <= 0;
            end
            // приём AR: фиксируем адрес, rvalid - в следующем такте
            if (ar_hs) begin
                araddr_q <= S_AXI_ARADDR;
                rvalid   <= 1;
            end else if (rvalid && S_AXI_RREADY) begin
                rvalid <= 0;
            end
        end
    end

    logic [C_S_AXI_DATA_WIDTH-1:0] rdata;
    always_comb begin
        case (araddr_q[5:2])
            4'd0: rdata = {31'b0, go_reg};
            4'd1: rdata = {30'b0, done_q, busy_q};
            4'd2: rdata = n_in_reg;
            4'd3: rdata = res0_reg;                      // результат [31:0]
            4'd4: rdata = res1_reg;                      // {16'h0, результат [47:32]}
            4'd5: rdata = data_start_reg[31:0];
            4'd6: rdata = data_start_reg[63:32];
            4'd7: rdata = weights_start_reg[31:0];
            4'd8: rdata = weights_start_reg[63:32];
            4'd9: rdata = result_addr_reg[31:0];
            4'd10: rdata = result_addr_reg[63:32];
            4'd11: rdata = core_result[31:0];            // CORE_RES0: результат [31:0]
            4'd12: rdata = {16'h0, core_result[47:32]};  // CORE_RES1: результат [47:32]
            default: rdata = 32'h0;
        endcase
    end

    assign S_AXI_AWREADY = awready;
    assign S_AXI_WREADY  = wready;
    assign S_AXI_BRESP   = 2'b00;
    assign S_AXI_BVALID  = bvalid;
    assign S_AXI_ARREADY = arready;
    assign S_AXI_RRESP   = 2'b00;
    assign S_AXI_RVALID  = rvalid;
    assign S_AXI_RDATA   = rdata;

    // ==================== FIFO собранных TFloat48 (из чтений) ====================
    logic [47:0] fifo_mem [0:FIFO_DEPTH-1];
    logic [FIFO_PTRW:0] fifo_wr, fifo_rd;
    logic fifo_push, fifo_pop;
    logic [47:0] fifo_q;
    logic fifo_clr;   // принудительный сброс указателей при новом запуске (из контроллера)
    // NOTE: fifo_full объявлен для отладки/будущего расширения (backpressure
    // на read-channel при заполнении). В текущей логике не используется, т.к.
    // FIFO_DEPTH = 2*NUM_MAC гарантирует, что все N_IN+NUM_MAC слов помещаются.
    wire fifo_full  = (fifo_wr - fifo_rd) >= FIFO_DEPTH;
    wire fifo_empty = (fifo_wr == fifo_rd);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) fifo_wr <= 0;
        else if (fifo_clr) fifo_wr <= 0;      // новый запуск: сброс указателя записи
        else if (fifo_push) fifo_wr <= fifo_wr + 1;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) fifo_rd <= 0;
        else if (fifo_clr) fifo_rd <= 0;      // новый запуск: сброс указателя чтения
        else if (fifo_pop) fifo_rd <= fifo_rd + 1;
    end
    always_ff @(posedge clk) begin
        if (fifo_push) fifo_mem[fifo_wr[FIFO_PTRW-1:0]] <= M_AXI_RDATA[47:0];
    end
    assign fifo_q = fifo_mem[fifo_rd[FIFO_PTRW-1:0]];

    // ==================== read-мастер (INCR-burst) ====================
    logic [AW-1:0] ar_addr_r;
    logic [7:0]    ar_len_r;
    logic          ar_valid_r, r_ready_r;

    localparam int RST_IDLE = 0;
    localparam int RST_ACT  = 1;
    localparam int RST_DONE = 2;
    logic [1:0] rstate;
    logic        rd_start;
    logic [AW-1:0] rd_addr;
    logic [31:0]   rd_total;
    logic [31:0]   rd_issued, rd_recv;
    logic          rd_done;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate <= RST_IDLE;
            ar_addr_r <= 0; ar_len_r <= 0;
            ar_valid_r <= 0; r_ready_r <= 0;
            rd_issued <= 0; rd_recv <= 0;
        end else begin
            case (rstate)
                RST_IDLE: begin
                    if (rd_start) begin
                        rd_issued <= 0; rd_recv <= 0;
                        r_ready_r <= 1;
                        rstate <= RST_ACT;
                    end
                end
                RST_ACT: begin
                    // выдача AR на очередной burst
                    if (!ar_valid_r && (rd_issued < rd_total)) begin
                        ar_addr_r <= rd_addr + (rd_issued * SW);
                        ar_len_r  <= (rd_total - rd_issued >= BURST_RD_LEN) ?
                                     (BURST_RD_LEN - 1) : (rd_total - rd_issued - 1);
                        ar_valid_r <= 1;
                    end
                    if (ar_valid_r && M_AXI_ARREADY) begin
                        ar_valid_r <= 0;
                        rd_issued <= rd_issued + ar_len_r + 1;
                    end
                    // приём данных
                    if (M_AXI_RVALID && r_ready_r) begin
                        rd_recv  <= rd_recv + 1;
                        if (rd_recv + 1 >= rd_total) begin
                            r_ready_r <= 0;
                            rstate <= RST_DONE;
                        end
                    end
                end
                RST_DONE: begin
                    // defensive: гарантировать, что ar_valid_r не висит,
                    // если ARREADY пришёл в RST_ACT, а rstate переключился
                    ar_valid_r <= 0;
                    rstate <= RST_IDLE;
                end
            endcase
        end
    end
    assign fifo_push = (rstate == RST_ACT) && M_AXI_RVALID && r_ready_r;
    assign rd_done   = (rstate == RST_DONE);

    assign M_AXI_ARID    = '0;
    assign M_AXI_ARADDR  = ar_addr_r;
    assign M_AXI_ARLEN   = ar_len_r;
    assign M_AXI_ARSIZE  = AXI_SZ;
    assign M_AXI_ARBURST = 2'b01;       // INCR
    assign M_AXI_ARLOCK  = 1'b0;
    assign M_AXI_ARCACHE = 4'b0011;
    assign M_AXI_ARPROT  = 3'b000;
    assign M_AXI_ARQOS   = 4'b0000;
    assign M_AXI_ARVALID = ar_valid_r;
    assign M_AXI_RREADY  = r_ready_r;

    // ==================== write-мастер (1 слово) ====================
    logic [AW-1:0] aw_addr_r;
    logic [DW-1:0] w_data_r;
    logic [SW-1:0] w_strb_r;
    logic          aw_valid_r, w_valid_r, w_last_r, b_ready_r;

    localparam int WST_IDLE = 0;
    localparam int WST_ACT  = 1;
    localparam int WST_DONE = 2;
    logic [1:0] wstate;
    logic        wr_start;
    logic [AW-1:0] wr_addr;
    logic [DW-1:0] wr_data;
    logic          wr_done;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate <= WST_IDLE;
            aw_addr_r <= 0; w_data_r <= 0; w_strb_r <= 0;
            aw_valid_r <= 0; w_valid_r <= 0; w_last_r <= 0; b_ready_r <= 0;
        end else begin
            case (wstate)
                WST_IDLE: begin
                    if (wr_start) begin
                        aw_addr_r <= wr_addr;
                        w_data_r  <= wr_data;
                        w_strb_r  <= {SW{1'b1}};
                        aw_valid_r <= 1;
                        w_valid_r  <= 1;
                        w_last_r   <= 1;
                        b_ready_r  <= 1;
                        wstate <= WST_ACT;
                    end
                end
                WST_ACT: begin
                    if (aw_valid_r && M_AXI_AWREADY) aw_valid_r <= 0;
                    if (w_valid_r  && M_AXI_WREADY) begin
                        w_valid_r <= 0; w_last_r <= 0;
                    end
                    if (M_AXI_BVALID && b_ready_r) begin
                        b_ready_r <= 0;
                        wstate <= WST_DONE;
                    end
                end
                WST_DONE: begin
                    wstate <= WST_IDLE;
                end
            endcase
        end
    end
    assign wr_done = (wstate == WST_DONE);

    assign M_AXI_AWID    = '0;
    assign M_AXI_AWADDR  = aw_addr_r;
    assign M_AXI_AWLEN   = 8'd0;
    assign M_AXI_AWSIZE  = AXI_SZ;
    assign M_AXI_AWBURST = 2'b01;
    assign M_AXI_AWLOCK  = 1'b0;
    assign M_AXI_AWCACHE = 4'b0011;
    assign M_AXI_AWPROT  = 3'b000;
    assign M_AXI_AWQOS   = 4'b0000;
    assign M_AXI_AWVALID = aw_valid_r;
    assign M_AXI_WDATA   = w_data_r;
    assign M_AXI_WSTRB   = w_strb_r;
    assign M_AXI_WLAST   = w_last_r;
    assign M_AXI_WVALID  = w_valid_r;
    assign M_AXI_BREADY  = b_ready_r;

    // ==================== контроллер ====================
    localparam int CS_IDLE = 0;
    localparam int CS_RD_DATA = 1;
    localparam int CS_RD_WEIGHTS = 2;
    localparam int CS_LOAD = 3;
    localparam int CS_RUN = 4;
    localparam int CS_WAIT = 5;
    localparam int CS_WR = 6;
    localparam int CS_DONE = 7;

    logic [2:0] cstate;
    logic go_q;
    wire go_pulse  = go_reg && !go_q;
    // GO принимается только когда ядро свободно (busy_q=0): повторный GO во
    // время выполнения перезапускал бы FSM и портил содержимое FIFO.
    wire go_accept = go_pulse && !busy_q;
    assign fifo_clr = go_accept;   // на новом запуске сбрасываем указатели FIFO
    logic [$clog2(2*NUM_MAC):0] load_idx;
    logic load_active;
    logic [31:0] n_in_eff;

    always_comb begin
        if (n_in_reg == 0 || n_in_reg > NUM_MAC)
            n_in_eff = NUM_MAC;
        else
            n_in_eff = n_in_reg;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            go_q <= 0;
            cstate <= CS_IDLE;
            core_valid_in <= 0;
            rd_start <= 0; wr_start <= 0;
            rd_addr <= 0; rd_total <= 0;
            wr_addr <= 0; wr_data <= 0;
            load_idx <= 0; load_active <= 0;
            core_data <= 0; core_weights <= 0;
            res0_reg <= 0; res1_reg <= 0;
            busy_q <= 0; done_q <= 0;
        end else begin
            go_q <= go_reg;
            core_valid_in <= 0;
            rd_start <= 0; wr_start <= 0;
            if (go_accept) begin
                busy_q <= 1; done_q <= 0;
                cstate <= CS_RD_DATA;
                rd_addr <= data_start_reg[AW-1:0];
                rd_total <= n_in_eff;
                rd_start <= 1;
            end
            case (cstate)
                CS_RD_DATA: begin
                    if (rd_done) begin
                        cstate <= CS_RD_WEIGHTS;
                        rd_addr <= weights_start_reg[AW-1:0];
                        rd_total <= n_in_eff;
                        rd_start <= 1;
                    end
                end
                CS_RD_WEIGHTS: begin
                    if (rd_done) begin
                        cstate <= CS_LOAD;
                        load_idx <= 0;
                        load_active <= 1;
                    end
                end
                CS_LOAD: begin
                    if (load_active) begin
                        if (load_idx < NUM_MAC) begin
                            if (load_idx < n_in_eff)
                                core_data[48*load_idx +: 48] <= fifo_q;
                            else
                                core_data[48*load_idx +: 48] <= 0;
                            load_idx <= load_idx + 1;
                        end else if (load_idx < 2*NUM_MAC) begin
                            if (load_idx - NUM_MAC < n_in_eff)
                                core_weights[48*(load_idx-NUM_MAC) +: 48] <= fifo_q;
                            else
                                core_weights[48*(load_idx-NUM_MAC) +: 48] <= 0;
                            load_idx <= load_idx + 1;
                        end else begin
                            load_active <= 0;
                            cstate <= CS_RUN;
                        end
                    end
                end
                CS_RUN: begin
                    core_valid_in <= 1;
                    cstate <= CS_WAIT;
                end
                CS_WAIT: begin
                    if (core_valid_out) begin
                        res0_reg <= core_result[31:0];              // результат [31:0]
                        res1_reg <= {16'h0, core_result[47:32]};    // результат [47:32]
                        cstate <= CS_WR;
                        wr_addr <= result_addr_reg[AW-1:0];
                        wr_data <= {16'h0, core_result};
                        wr_start <= 1;
                    end
                end
                CS_WR: begin
                    if (wr_done) begin
                        cstate <= CS_DONE;
                    end
                end
                CS_DONE: begin
                    busy_q <= 0; done_q <= 1;
                    cstate <= CS_IDLE;
                end
            endcase
        end
    end

    // fifo_pop в фазе загрузки: pop ТОЛЬКО в такты, когда элемент реально
    // потребляется из FIFO (слот заполняется из fifo_q). При n_in_eff < NUM_MAC
    // слоты-заглушки заполняются нулём БЕЗ pop — иначе fifo_rd уходит за
    // пределы загруженных данных и weights читаются со смещением (мусор).
    always_comb begin
        fifo_pop = 1'b0;
        if (cstate == CS_LOAD && load_active && (load_idx < 2*NUM_MAC)) begin
            if (load_idx < NUM_MAC)
                fifo_pop = (load_idx < n_in_eff);              // data-фаза
            else
                fifo_pop = ((load_idx - NUM_MAC) < n_in_eff);  // weights-фаза
        end
    end

endmodule
