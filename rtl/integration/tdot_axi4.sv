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
//   [0x08] N_IN    число пар (1..MAX_N_TOTAL=16*NUM_MAC; >NUM_MAC = long-dot,
//                  авто-разбиение на проходы с аккумулятором)
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
// Планировщик (ring-buffer команд в DDR3, irq):
//   [0x40] SCHED_CTRL   бит0 sched_en, бит1 irq_en, бит2 flush (действие),
//                       бит3 irq_ack (действие: сброс irq_pending)
//   [0x44] SCHED_WPTR   хостовый указатель записи (8 бит, кольцо mod 256)
//   [0x48] SCHED_RPTR   RO текущий указатель чтения (8 бит)
//   [0x4C/0x50] DESC_BASE_LO/HI  база таблицы дескрипторов (полный AXI-адрес)
//   [0x54/0x58] COMP_BASE_LO/HI  база области завершений
//   [0x5C] SCHED_STATUS RO: бит0 sched_busy, бит1 irq_pending
//   [0x60] DONE_CNT     RO счётчик завершённых задач (16 бит, free-running)
// Кольцо: 256 дескрипторов (таблица 8 КБ) / 256 завершений (4 КБ), указатели
// 8-бит с естественным переполнением (mod 256).
//
// Дескриптор 32 Б (4×64b, LE): W0 data_addr[47:0], W1 weights_addr[47:0],
//   W2 result_addr[47:0], W3 {32'h0, n_total[15:0], tag[15:0]}.
// Адреса — полные AXI (обрезаются до C_M_AXI_ADDR_WIDTH=32).
// Завершение 16 Б (2×64b): W0 {tag[15:0], result[47:0]},
//   W1 {48'h0, passes[7:0], status[7:0]} (status: 0=OK).
//
// Протокол одиночной задачи (GO=1, легаси):
//   (1) burst-чтение N_IN слов data    (по BURST_RD_LEN слов/транзакция)
//   (2) burst-чтение N_IN слов weights
//   (3) загрузка в compute_dot_par_raw (неиспользуемые MAC-слоты = 0)
//   (4) вычисление (valid_in -> valid_out)
//   (5) запись результата (1 слово) по result_addr
//   (6) DONE=1, BUSY=0
// Long-dot: N_IN > NUM_MAC — цикл проходов по NUM_MAC пар: чтение чанка,
//   вычисление частичной суммы, накопление tfadd48 (pass 0 — без сложения),
//   затем запись итога. Каждая задача планировщика — тот же цикл с
//   n_total из дескриптора + запись completion (16 Б) в COMP_BASE + rptr*16.
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
    output logic                                  M_AXI_RREADY,

    // ---- IRQ планировщика (уровень 1, держится до irq_ack; домен S/M_AXI) ----
    output logic                                  sched_irq
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

    // Long-dot: максимум проходов по NUM_MAC пар (сатурация n_total).
    localparam int MAX_PASSES  = 16;
    localparam int MAX_N_TOTAL = MAX_PASSES * NUM_MAC;

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

    // ==================== аккумулятор long-dot ====================
    // acc = (pass 0) частичная сумма дерева; (pass k>0) tfadd48(acc, partial).
    // Входы держатся стабильными до valid_out (acc_q не меняется, core_result
    // защёлкнут в result_out_reg ядра до следующей задачи).
    logic acc_valid_q;                 // уже есть накопленный результат (pass 0 завершён)
    logic [47:0] acc_q;
    logic        acc_start_q;          // импульс запуска tfadd48
    logic        add_valid_w;
    logic [47:0] add_res_w;

    tfadd48 u_acc (
        .clk(clk), .rst_n(rst_n),
        .valid_in(acc_start_q), .a(acc_q), .b(core_result),
        .valid_out(add_valid_w), .result(add_res_w)
    );

    // ==================== регистры (AXI-Lite) ====================
    logic go_reg;
    logic [31:0] n_in_reg;
    logic [63:0] data_start_reg, weights_start_reg, result_addr_reg;
    logic [31:0] res0_reg, res1_reg;
    logic busy_q, done_q;

    // ---- регистры планировщика ----
    logic        sched_en_q;        // SCHED_CTRL.bit0
    logic        sched_irq_en_q;    // SCHED_CTRL.bit1
    logic        sched_flush_q;     // SCHED_CTRL.bit2 (действие, самоочистка)
    logic [7:0]  sched_wptr_q;      // хостовый указатель записи (кольцо mod 256)
    logic [7:0]  sched_rptr_q;      // указатель чтения (движет движок, mod 256)
    logic [63:0] desc_base_q;       // база таблицы дескрипторов (DDR3)
    logic [63:0] comp_base_q;       // база области завершений (DDR3)
    logic        irq_pending_q;     // поднято при опустошении очереди, сброс irq_ack
    logic        sched_busy_q;      // движок исполняет задачу
    logic [15:0] done_cnt_q;        // счётчик завершённых задач

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
            sched_en_q <= 0; sched_irq_en_q <= 0; sched_flush_q <= 0;
            sched_wptr_q <= 0;
            desc_base_q <= 0; comp_base_q <= 0;
            // sched_rptr_q/irq_pending_q/done_cnt_q — в блоке контроллера
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
                case (awaddr_q[7:2])
                    6'd0: begin
                        go_reg <= wdata_q[0];
                    end
                    6'd2: n_in_reg <= wdata_q;
                    6'd5: data_start_reg[31:0]    <= wdata_q;
                    6'd6: data_start_reg[63:32]   <= wdata_q;
                    6'd7: weights_start_reg[31:0] <= wdata_q;
                    6'd8: weights_start_reg[63:32]<= wdata_q;
                    6'd9: result_addr_reg[31:0]   <= wdata_q;
                    6'd10: result_addr_reg[63:32] <= wdata_q;
                    // ---- планировщик ----
                    6'd16: begin
                        sched_en_q     <= wdata_q[0];
                        sched_irq_en_q <= wdata_q[1];
                        sched_flush_q  <= wdata_q[2];        // самоочистка в else-ветке
                        // irq_ack (wdata_q[3]) — обрабатывается контроллером (sched_ack_pulse)
                    end
                    6'd17: sched_wptr_q <= wdata_q[7:0];
                    6'd19: desc_base_q[31:0]  <= wdata_q;
                    6'd20: desc_base_q[63:32] <= wdata_q;
                    6'd21: comp_base_q[31:0]  <= wdata_q;
                    6'd22: comp_base_q[63:32] <= wdata_q;
                    default: ;
                endcase
            end else begin
                if (go_reg) go_reg <= 0;         // самосброс GO
                if (sched_flush_q) sched_flush_q <= 0; // самоочистка flush
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
        case (araddr_q[7:2])
            6'd0: rdata = {31'b0, go_reg};
            6'd1: rdata = {30'b0, done_q, busy_q};
            6'd2: rdata = n_in_reg;
            6'd3: rdata = res0_reg;                      // результат [31:0]
            6'd4: rdata = res1_reg;                      // {16'h0, результат [47:32]}
            6'd5: rdata = data_start_reg[31:0];
            6'd6: rdata = data_start_reg[63:32];
            6'd7: rdata = weights_start_reg[31:0];
            6'd8: rdata = weights_start_reg[63:32];
            6'd9: rdata = result_addr_reg[31:0];
            6'd10: rdata = result_addr_reg[63:32];
            6'd11: rdata = core_result[31:0];            // CORE_RES0: результат [31:0]
            6'd12: rdata = {16'h0, core_result[47:32]};  // CORE_RES1: результат [47:32]
            // ---- планировщик ----
            6'd16: rdata = {28'b0, irq_pending_q, sched_flush_q,
                            sched_irq_en_q, sched_en_q};
            6'd17: rdata = {24'h0, sched_wptr_q};
            6'd18: rdata = {24'h0, sched_rptr_q};
            6'd19: rdata = desc_base_q[31:0];
            6'd20: rdata = desc_base_q[63:32];
            6'd21: rdata = comp_base_q[31:0];
            6'd22: rdata = comp_base_q[63:32];
            6'd23: rdata = {30'b0, irq_pending_q, sched_busy_q};
            6'd24: rdata = {16'h0, done_cnt_q};
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
    // LUTRAM→BRAM (выбранный вариант оптимизации): fifo_mem вынесен в BRAM
    // (ram_style="block", 64x48 укладывается в 1x RAMB36 / 2x RAMB18).
    // Чтение BRAM синхронное: fifo_q отстаёт от адреса fifo_rd на 1 такт.
    // Контроллер CS_LOAD переведён на 2-стадийный конвейер:
    //   стадия 1 (rd_idx): pop + выдача BRAM-чтения слова для слота rd_idx;
    //   стадия 2 (load_idx = rd_idx-1): потребление fifo_q в слот load_idx.
    // Эквивалентность прежней (LUTRAM, асинхронное чтение) и новой логики
    // проверена моделью scripts/check_tdot_load.py (колонка BRAM) для
    // NUM_MAC=8/16/32 × N_IN=0..NUM_MAC, включая N_IN<NUM_MAC (фикс CS_LOAD,
    // commit a86ef65).
    (* ram_style = "block" *) logic [47:0] fifo_mem [0:FIFO_DEPTH-1];
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
    // синхронное чтение BRAM. Без сброса fifo_q: выходной регистр BRAM
    // аппаратного сброса не имеет, лишний reset сломал бы маппинг в BRAM.
    always_ff @(posedge clk) begin
        fifo_q <= fifo_mem[fifo_rd[FIFO_PTRW-1:0]];
    end

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
    // Вся механика AXI (чтения/записи) и полный жизненный цикл задачи — здесь.
    // Multi-pass (long-dot): задача = цикл проходов по chunk_n = min(n_left,
    // NUM_MAC) пар: чтение чанка data/weights -> загрузка -> частичная сумма ->
    // аккумуляция (pass 0 — без сложения) -> ... -> запись результата.
    // Задачи планировщика добавляют: fetch дескриптора (CS_FETCH_DESC),
    // entry CS_SCHED_KICK и запись completion 16 Б (CS_CMP1..3) + rptr/done_cnt.
    localparam int CS_IDLE        = 0;
    localparam int CS_RD_DATA     = 1;
    localparam int CS_RD_WEIGHTS  = 2;
    localparam int CS_LOAD        = 3;
    localparam int CS_RUN         = 4;
    localparam int CS_WAIT        = 5;
    localparam int CS_ACCUM_WAIT  = 6;
    localparam int CS_WR          = 7;
    localparam int CS_DONE        = 8;
    localparam int CS_FETCH_DESC  = 9;
    localparam int CS_SCHED_KICK  = 10;
    localparam int CS_CMP1        = 11;
    localparam int CS_CMP2        = 12;
    localparam int CS_CMP3        = 13;

    logic [3:0] cstate;
    logic go_q;
    wire go_pulse  = go_reg && !go_q;
    // Внешний GO принимается только когда ядро свободно и планировщик выключен
    // (иначе внешний GO мог бы вклиниться в очередь задач).
    wire go_accept = go_pulse && !busy_q && !sched_en_q;
    wire job_start = go_accept;       // легаси-старт
    assign fifo_clr = job_start || (cstate == CS_SCHED_KICK);

    // ---- планировщик: только решение о выборке (вся механика в контроллере) ----
    wire sched_pull = sched_en_q && !busy_q && !sched_flush_q &&
                      (sched_rptr_q != sched_wptr_q);
    wire sched_ack_pulse = wr_commit && (awaddr_q[7:2] == 6'd16) && wdata_q[3];

    logic use_sched_q;                // текущая задача пришла от планировщика
    logic [63:0] cur_data_q, cur_weights_q, cur_result_q;  // база задачи
    logic [31:0] n_left_q;            // сколько пар осталось (включая текущий проход)
    logic [31:0] elems_done_q;        // пар обработано с начала задачи
    logic [7:0]  passes_q;            // завершено проходов в текущей задаче

    // дескриптор (снимается с fifo во время fetch)
    logic        fetch_active;
    logic [1:0]  fetch_cnt;
    logic [63:0] desc_w [0:3];
    logic [47:0] job_data_addr_q, job_weights_addr_q, job_result_addr_q;
    logic [15:0] job_n_total_q, job_tag_q;

    // нормализация n_total: 0 -> NUM_MAC (легаси-семантика), сатурация до MAX
    wire [31:0] n_total_sched  = (job_n_total_q == 16'd0)      ? NUM_MAC :
                                 (job_n_total_q > MAX_N_TOTAL) ? MAX_N_TOTAL :
                                                                 {16'h0, job_n_total_q};
    wire [31:0] n_total_legacy = (n_in_reg == 32'd0)           ? NUM_MAC :
                                 (n_in_reg > MAX_N_TOTAL)      ? MAX_N_TOTAL :
                                                                 n_in_reg;

    // размер текущего прохода
    logic [31:0] chunk_n;
    always_comb begin
        chunk_n = (n_left_q > NUM_MAC) ? NUM_MAC : n_left_q;
    end
    // сигнатура CS_LOAD (zero-fill слотов >= chunk_n) — прежняя семантика
    logic [31:0] n_in_eff;
    assign n_in_eff = chunk_n;

    wire last_pass = (n_left_q <= NUM_MAC);   // текущий проход — последний

    logic [$clog2(2*NUM_MAC):0] load_idx;
    logic [$clog2(2*NUM_MAC):0] rd_idx;    // стадия 1 конвейера: слот, читаемый из BRAM сейчас
    logic load_active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            go_q <= 0;
            cstate <= CS_IDLE;
            core_valid_in <= 0;
            rd_start <= 0; wr_start <= 0;
            rd_addr <= 0; rd_total <= 0;
            wr_addr <= 0; wr_data <= 0;
            load_idx <= 0; rd_idx <= 0; load_active <= 0;
            core_data <= 0; core_weights <= 0;
            res0_reg <= 0; res1_reg <= 0;
            busy_q <= 0; done_q <= 0;
            acc_valid_q <= 0; acc_q <= 0; acc_start_q <= 0;
            use_sched_q <= 0;
            cur_data_q <= 0; cur_weights_q <= 0; cur_result_q <= 0;
            n_left_q <= 0; elems_done_q <= 0; passes_q <= 0;
            sched_rptr_q <= 0; done_cnt_q <= 0; irq_pending_q <= 0;
            fetch_active <= 0; fetch_cnt <= 0;
            for (int i = 0; i < 4; i++) desc_w[i] <= 64'h0;
            job_data_addr_q <= 0; job_weights_addr_q <= 0;
            job_result_addr_q <= 0; job_n_total_q <= 0; job_tag_q <= 0;
        end else begin
            go_q <= go_reg;
            core_valid_in <= 0;
            rd_start <= 0; wr_start <= 0; acc_start_q <= 0;
            // irq_ack действует в любом состоянии (SCHED_CTRL.bit3)
            if (sched_ack_pulse) irq_pending_q <= 1'b0;
            if (job_start) begin
                busy_q <= 1; done_q <= 0;
                acc_valid_q <= 0;
                use_sched_q <= 1'b0;
                cur_data_q    <= data_start_reg;
                cur_weights_q <= weights_start_reg;
                cur_result_q  <= result_addr_reg;
                n_left_q      <= n_total_legacy;
                elems_done_q  <= 0;
                passes_q      <= 0;
                cstate <= CS_RD_DATA;
                rd_addr  <= data_start_reg[AW-1:0];
                rd_total <= (n_total_legacy > NUM_MAC) ? NUM_MAC : n_total_legacy;
                rd_start <= 1;
            end
            case (cstate)
                CS_IDLE: begin
                    if (sched_flush_q) begin
                        sched_rptr_q <= 8'h0;            // flush очереди
                    end else if (sched_pull) begin
                        // fetch дескриптора: 4 слова (32 Б) с DESC_BASE+rptr*32
                        fetch_active <= 1;
                        fetch_cnt <= 0;
                        rd_addr  <= desc_base_q[AW-1:0] + {19'h0, sched_rptr_q, 5'b0};
                        rd_total <= 32'd4;
                        rd_start <= 1;
                        cstate <= CS_FETCH_DESC;
                    end
                end
                CS_FETCH_DESC: begin
                    // слова дескриптора приходят в FIFO (мусор для загрузки,
                    // будет очищен fifo_clr в CS_SCHED_KICK) — снимаем копию
                    if (fetch_active && fifo_push) begin
                        desc_w[fetch_cnt] <= M_AXI_RDATA;
                        fetch_cnt <= fetch_cnt + 1;
                    end
                    if (rd_done) begin
                        // последнее слово захвачено в предыдущем такте
                        fetch_active <= 0;
                        job_data_addr_q    <= desc_w[0][47:0];
                        job_weights_addr_q <= desc_w[1][47:0];
                        job_result_addr_q  <= desc_w[2][47:0];
                        job_n_total_q      <= desc_w[3][31:16];
                        job_tag_q          <= desc_w[3][15:0];
                        cstate <= CS_SCHED_KICK;
                    end
                end
                CS_SCHED_KICK: begin
                    // entry действия задачи планировщика
                    busy_q <= 1; done_q <= 0;
                    acc_valid_q <= 0;
                    use_sched_q <= 1'b1;
                    cur_data_q    <= {16'h0, job_data_addr_q};
                    cur_weights_q <= {16'h0, job_weights_addr_q};
                    cur_result_q  <= {16'h0, job_result_addr_q};
                    n_left_q      <= n_total_sched;
                    elems_done_q  <= 0;
                    passes_q      <= 0;
                    cstate <= CS_RD_DATA;
                    rd_addr  <= job_data_addr_q[AW-1:0];
                    rd_total <= (n_total_sched > NUM_MAC) ? NUM_MAC
                                                          : n_total_sched;
                    rd_start <= 1;
                end
                CS_RD_DATA: begin
                    if (rd_done) begin
                        cstate <= CS_RD_WEIGHTS;
                        rd_addr  <= cur_weights_q[AW-1:0] + elems_done_q * SW;
                        rd_total <= chunk_n;
                        rd_start <= 1;
                    end
                end
                CS_RD_WEIGHTS: begin
                    if (rd_done) begin
                        cstate <= CS_LOAD;
                        load_idx <= 0;
                        rd_idx <= 0;
                        load_active <= 1;
                    end
                end
                // 2-стадийный конвейер загрузки (BRAM: синхронное чтение).
                // Инвариант: во время такта X BRAM читает mem[fifo_rd] = слово
                // слота rd_idx, а fifo_q в такте X содержит слово слота
                // load_idx = rd_idx-1 (прочитано в такте X-1).
                CS_LOAD: begin
                    if (load_active) begin
                        // стадия 1: pop + выдача чтения слова для слота rd_idx
                        if (rd_idx < 2*NUM_MAC)
                            rd_idx <= rd_idx + 1;
                        // стадия 2: потребление fifo_q в слот load_idx
                        if (rd_idx > load_idx) begin
                            if (load_idx < NUM_MAC)
                                core_data[48*load_idx +: 48] <=
                                    (load_idx < n_in_eff) ? fifo_q : 48'h0;
                            else
                                core_weights[48*(load_idx-NUM_MAC) +: 48] <=
                                    ((load_idx-NUM_MAC) < n_in_eff) ? fifo_q : 48'h0;
                            load_idx <= load_idx + 1;
                        end else if ((rd_idx == 2*NUM_MAC) && (load_idx == 2*NUM_MAC)) begin
                            // всё выдано и всё потреблено
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
                        if (!acc_valid_q) begin
                            // pass 0: без сложения
                            acc_valid_q <= 1;
                            acc_q <= core_result;
                            passes_q <= passes_q + 8'd1;
                            if (last_pass) begin
                                // сразу пишем результат (как в легаси-версии)
                                res0_reg <= core_result[31:0];
                                res1_reg <= {16'h0, core_result[47:32]};
                                cstate <= CS_WR;
                                wr_addr <= cur_result_q[AW-1:0];
                                wr_data <= {16'h0, core_result};
                                wr_start <= 1;
                            end else begin
                                // к следующему проходу
                                n_left_q     <= n_left_q - chunk_n;
                                elems_done_q <= elems_done_q + chunk_n;
                                cstate <= CS_RD_DATA;
                                rd_addr  <= cur_data_q[AW-1:0]
                                            + (elems_done_q + chunk_n) * SW;
                                rd_total <= (n_left_q - chunk_n > NUM_MAC) ?
                                            NUM_MAC : (n_left_q - chunk_n);
                                rd_start <= 1;
                            end
                        end else begin
                            // pass k>0: сложение в аккумуляторе
                            acc_start_q <= 1;
                            cstate <= CS_ACCUM_WAIT;
                        end
                    end
                end
                CS_ACCUM_WAIT: begin
                    if (add_valid_w) begin
                        acc_q <= add_res_w;
                        passes_q <= passes_q + 8'd1;
                        if (last_pass) begin
                            res0_reg <= add_res_w[31:0];
                            res1_reg <= {16'h0, add_res_w[47:32]};
                            cstate <= CS_WR;
                            wr_addr <= cur_result_q[AW-1:0];
                            wr_data <= {16'h0, add_res_w};
                            wr_start <= 1;
                        end else begin
                            n_left_q     <= n_left_q - chunk_n;
                            elems_done_q <= elems_done_q + chunk_n;
                            cstate <= CS_RD_DATA;
                            rd_addr  <= cur_data_q[AW-1:0]
                                        + (elems_done_q + chunk_n) * SW;
                            rd_total <= (n_left_q - chunk_n > NUM_MAC) ?
                                        NUM_MAC : (n_left_q - chunk_n);
                            rd_start <= 1;
                        end
                    end
                end
                CS_WR: begin
                    if (wr_done) begin
                        cstate <= CS_DONE;
                    end
                end
                CS_DONE: begin
                    busy_q <= 0; done_q <= 1;
                    cstate <= use_sched_q ? CS_CMP1 : CS_IDLE;
                end
                // ---- completion записи задачи планировщика ----
                CS_CMP1: begin
                    // W0: {tag[15:0], result[47:0]}
                    wr_addr  <= comp_base_q[AW-1:0] + {20'h0, sched_rptr_q, 4'b0};
                    wr_data  <= {job_tag_q, res1_reg[15:0], res0_reg};
                    wr_start <= 1;
                    cstate <= CS_CMP2;
                end
                CS_CMP2: begin
                    if (wr_done) begin
                        // W1: {48'h0, passes[7:0], status[7:0]}
                        wr_addr  <= comp_base_q[AW-1:0]
                                    + {20'h0, sched_rptr_q, 4'b0} + SW;
                        wr_data  <= {48'h0, passes_q, 8'h00};
                        wr_start <= 1;
                        cstate <= CS_CMP3;
                    end
                end
                CS_CMP3: begin
                    if (wr_done) begin
                        sched_rptr_q <= sched_rptr_q + 8'd1;
                        done_cnt_q   <= done_cnt_q + 16'd1;
                        // опустошение очереди -> IRQ (уровень, до irq_ack)
                        if (sched_irq_en_q &&
                            (sched_rptr_q + 8'd1 == sched_wptr_q))
                            irq_pending_q <= 1'b1;
                        cstate <= CS_IDLE;
                    end
                end
                default: cstate <= CS_IDLE;
            endcase
        end
    end

    assign sched_irq = sched_irq_en_q && irq_pending_q;


    // fifo_pop в фазе загрузки: pop ТОЛЬКО в такт выдачи BRAM-чтения
    // (стадия 1, слот rd_idx) и только когда слово реально есть в FIFO.
    // При n_in_eff < NUM_MAC слоты-заглушки заполняются нулём БЕЗ pop —
    // иначе fifo_rd уходит за пределы загруженных данных и weights
    // читаются со смещением (мусор). См. фикс CS_LOAD (commit a86ef65)
    // и модель check_tdot_load.py.
    always_comb begin
        fifo_pop = 1'b0;
        if (cstate == CS_LOAD && load_active && (rd_idx < 2*NUM_MAC)) begin
            if (rd_idx < NUM_MAC)
                fifo_pop = (rd_idx < n_in_eff);              // data-фаза
            else
                fifo_pop = ((rd_idx - NUM_MAC) < n_in_eff);  // weights-фаза
        end
    end

endmodule
