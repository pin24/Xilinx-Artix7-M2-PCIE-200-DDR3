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
//   [0x64] CORE_PARAMS  RO: [7:0]=NUM_MAC, [15:8]=ADDERS (параметры компиляции)
//   [0x68] MAGIC        RO: 0x54444F54 ('TDOT') — идентификация блока драйвером
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
    parameter int ADDERS  = 4,        // barrel-аддеров в дереве compute_dot_par_raw (1 = последовательный)
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int C_S_AXI_ADDR_WIDTH = 8,
    parameter int C_M_AXI_ID_WIDTH   = 1,
    parameter int C_M_AXI_ADDR_WIDTH = 32,
    parameter int C_M_AXI_DATA_WIDTH = 64,
    parameter int BURST_RD_LEN = 32,   // макс. слов в одной read-транзакции (P3b: длиннее burst = выше обмен)
    parameter int BURST_WR_LEN = 8,    // макс. слов в одной write-транзакции
    parameter int ELEM_FMT = 0,        // 0=легаси tf48 (8 байт/элемент, без конверсии);
                                       // 1=fp32 вход/выход (4 байта/элемент): F2T на загрузке, T2F на записи;
                                       // 2=PACKED6 tf48 (6 байт/элемент плотно): barrel 6<->8, конвертеры ВЫКЛ
    parameter logic [31:0] BUILD_ID = 32'h0 // git-коммит битстрима (OBS 0x70; 0 = не передан)
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
    output logic                                  sched_irq,

    // ---- DIAG-статус (2026-10-03): наблюдение за ядром без доступа внутрь ----
    output logic                                  diag_go,    // внешний GO принят / ядро стартует
    output logic                                  diag_busy,  // busy_q (ядро исполняет)
    output logic                                  diag_done,  // done_q
    // ---- DIAG fp32 (ELEM_FMT=1): конвертер F2T на входе ----
    output logic                                  diag_f2t_sv,  // F2T s_axis_tvalid
    output logic                                  diag_f2t_mv,  // F2T m_axis_tvalid
    output logic                                  diag_f2t_dv   // F2T d_valid[DL] (out_v)
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

    // ---- ELEM_FMT: геометрия элемента ----
    // 0: легаси tf48, 8 байт/элемент, 1 элемент на 64-бит слово (данные уже tf48).
    // 1: fp32, 4 байта/элемент, 2 элемента на 64-бит слово, F2T/T2F.
    // 2: PACKED6 tf48, 6 байт/элемент плотно, barrel 6<->8 (конвертеры выкл).
    localparam logic FP32_MODE   = (ELEM_FMT == 1);
    localparam logic PACKED6_MODE = (ELEM_FMT == 2);
    localparam int  BPE       = PACKED6_MODE ? 6 : (FP32_MODE ? 4 : 8);
                                                                          // байт на элемент (stride)
    localparam int  ELEMS_PER_BEAT = FP32_MODE ? 2 : 1;     // элемента на 64-бит beat
    // число слов, читаемых на chunk_n элементов (fp32: ceil(n/2), PACKED6: ceil(n*6/8), легаси: n)
    localparam logic [0:0] FP32_CONV = FP32_MODE;
    function automatic [31:0] words_fn(input [31:0] cnt);
        if (PACKED6_MODE)
            words_fn = (cnt * 6 + 7) >> 3;         // ceil(cnt*6/8)
        else if (FP32_MODE)
            words_fn = (cnt + 1) >> 1;             // ceil(cnt/2)
        else
            words_fn = cnt;
    endfunction
    // GAP-1 RTL-FIX: число слов чтения, начинающегося с байтового смещения `skip`
    // (start_skip != 0 на проходах k>0). PACKED6-проход k начинается с байта
    // elems*6: слово-адрес = floor(elems*6/8)*8, внутри 1-го слова смещение
    // (elems*6)%8; чанк занимает ceil((skip + cnt*6)/8) слов (на 1 больше, чем без
    // skip, если (skip + cnt*6) переваливает через границу 8). Для fp32/легаси
    // skip не используется -> эквивалентно words_fn.
    function automatic [31:0] words_skip_fn(input [31:0] skip_b, input [31:0] cnt);
        if (PACKED6_MODE)
            words_skip_fn = (skip_b + cnt * 6 + 7) >> 3;   // ceil((skip + cnt*6)/8)
        else if (FP32_MODE)
            words_skip_fn = (cnt + 1) >> 1;                // ceil(cnt/2)
        else
            words_skip_fn = cnt;
    endfunction

    logic clk, rst_n;
    assign clk   = M_AXI_ACLK;
    assign rst_n = M_AXI_ARESETN;

    // ---- BUG-054: локальный буфер сброса ядра (fix recovery rst->CLR, 32/16) ----
    // Внешний rst_n приходит от proc_sys_reset 125M внутри BD (rst_core_125M) и
    // разводится на CLR-входы ВСЕХ регистров ядра (огромный fanout) — FATAL
    // recovery-путь rst_core_125M -> gen_ad[7].u_add/fq_q_reg[44]/CLR (-1.595).
    // 2-стадийный синхронизатор-буфер на clk образует локальный асинхронный
    // сброс для ядра И аккумулятора (u_core, u_acc): деассерция на 2 такта позже
    // внешней (корректно: старт задачи всегда после reset_assert), а recovery-путь
    // CLR начинается с регистра рядом с ядром (короткий reset-tree), а не из
    // удалённого BD-IP. Внешние контроллеры/AXI-Lite/FIFO остаются на rst_n.
    (* ASYNC_REG = "TRUE" *)
    logic rst_core_b0, rst_core_buf;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_core_b0  <= 1'b0;   // активный НИЗКИЙ сброс (как rst_n)
            rst_core_buf <= 1'b0;
        end else begin
            rst_core_b0  <= 1'b1;
            rst_core_buf <= rst_core_b0;
        end
    end

    // ==================== ядро ====================
    logic [48*NUM_MAC-1:0] core_data, core_weights;
    logic core_valid_in, core_valid_out;
    logic [47:0] core_result;

    compute_dot_par_raw #(.NUM_MAC(NUM_MAC), .ADDERS(ADDERS)) u_core (
        .clk(clk), .rst_n(rst_core_buf),
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
        .clk(clk), .rst_n(rst_core_buf),
        .valid_in(acc_start_q), .a(acc_q), .b(core_result),
        .valid_out(add_valid_w), .result(add_res_w)
    );

    // ==================== конвертеры fp32 (ELEM_FMT=1) ====================
    // F2T на входе CS_LOAD: fifo_q[31:0] (fp32) -> tf48 (ядро). T2F на выходе
    // CS_WR: core_result (tf48) -> fp32. Инстанцируются/используются только при
    // (ELEM_FMT==1); при ELEM_FMT=0 (легаси) все связанные сигналы заведены
    // константами, а модули конвертеров не входят в дерево компиляции.
    // ---- сигналы конвертеров (объявлены ДО gen_conv, чтобы порты соединялись) ----
    logic        f2t_s_valid, f2t_m_valid;
    logic [31:0] f2t_s_data;
    logic [47:0] f2t_m_data;
    logic        f2t_d_valid;    // = F2T out_v (отладка)
    logic        t2f_s_valid, t2f_m_valid;
    logic [47:0] t2f_s_data;
    logic [31:0] t2f_m_data;
    if (FP32_MODE) begin : gen_conv
        // конвертеры используют сигналы, объявленные на уровне модуля
        // (f2t_s_valid/f2t_s_data/f2t_m_valid/f2t_m_data и t2f_*) - они управляются
        // ниже: входы - feed/результат в контроллере, выходы - из конвертеров.
        f32_to_tf48_pipe u_f2t (
            .clk(clk), .rst_n(rst_core_buf),
            .s_axis_tvalid(f2t_s_valid), .s_axis_tdata(f2t_s_data),
            .m_axis_tvalid(f2t_m_valid), .m_axis_tdata(f2t_m_data),
            .diag_d_valid(f2t_d_valid)
        );
        tf48_to_f32_pipe u_t2f (
            .clk(clk), .rst_n(rst_core_buf),
            .s_axis_tvalid(t2f_s_valid), .s_axis_tdata(t2f_s_data),
            .m_axis_tvalid(t2f_m_valid), .m_axis_tdata(t2f_m_data)
        );
    end
    if (!FP32_MODE) begin : gen_conv_off
        // в легаси конвертеры не инстанцированы; выходы держим не-X (мёртвый код)
        assign f2t_m_valid = 1'b0;
        assign f2t_m_data  = 48'h0;
        assign t2f_m_valid = 1'b0;
        assign t2f_m_data  = 32'h0;
        // f2t_s_valid/f2t_s_data/t2f_s_valid/t2f_s_data управляются гейтированными
        // assign ниже (fp_feeding/FP32_MODE константы -> 0 в легаси)
    end

    // ==================== регистры (AXI-Lite) ====================
    logic go_reg;
    logic [31:0] n_in_reg;
    logic [63:0] data_start_reg, weights_start_reg, result_addr_reg;
    logic [31:0] res0_reg, res1_reg;
    logic busy_q, done_q;

    // ==================== наблюдаемость (OBS, Task 35, openTPU-inspired) ====
    // Счётчики/снимки размещены на СВОБОДНЫХ смещениях (0x6C+), т.к. 0x64/0x68
    // в main-карте заняты CORE_PARAMS/MAGIC (host-контракт). Отличие от
    // ветки XDMA_DDR3_TMUL (там OBS_CTRL@0x64/BUILD_ID@0x68): см. ADDRESS_MAP§OBS.
    localparam int        OBS_REGMAP_V  = 1;
    localparam logic [3:0] CAPS_L2BURST = $clog2(BURST_RD_LEN);
    localparam logic [3:0] CAPS_ADDERS  = (ADDERS > 15) ? 4'd15 : ADDERS[3:0];
    localparam logic [7:0] CAPS_NUMMAC  = NUM_MAC[7:0];
    localparam logic [2:0] CAPS_ELEMFMT = ELEM_FMT[2:0];
    logic        obs_freeze_q;   // OBS_CTRL.bit1: пауза событийного счёта
    logic        obs_clear_q;    // OBS_CTRL.bit0: импульс обнуления
    logic        obs_snap;       // SNAP: импульс защёлкивания теней
    logic [63:0] cnt_cycles;
    logic [31:0] cnt_busy, cnt_mem, cnt_load, cnt_compute;
    logic [31:0] cnt_ar, cnt_beat, cnt_ar_stall, cnt_r_wait;
    logic [31:0] cnt_wr, cnt_job, cnt_fifo_full;
    logic [63:0] snap_cycles;
    logic [31:0] snap_busy, snap_mem, snap_load, snap_compute;
    logic [31:0] snap_ar, snap_beat, snap_ar_stall, snap_r_wait;
    logic [31:0] snap_wr, snap_job, snap_fifo_full;

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
            obs_freeze_q <= 0; obs_clear_q <= 0; obs_snap <= 0;
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
                    // ---- наблюдаемость (OBS; 0x6C=6'd27, 0xAC=6'd43) ----
                    6'd27: begin
                        obs_freeze_q <= wdata_q[1];
                        obs_clear_q  <= wdata_q[0];   // импульс, самоочистка ниже
                    end
                    6'd43: obs_snap <= 1'b1;          // любое значение = снимок
                    default: ;
                endcase
            end else begin
                if (go_reg) go_reg <= 0;         // самосброс GO
                if (sched_flush_q) sched_flush_q <= 0; // самоочистка flush
                if (obs_clear_q) obs_clear_q <= 0;     // импульс CLEAR
                if (obs_snap) obs_snap <= 0;           // импульс SNAP
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
            // 6'd25 [0x64] CORE_PARAMS RO: [7:0]=NUM_MAC, [15:8]=ADDERS -
            // фиксирует параметры компиляции ядра для автоопределения драйвером.
            6'd25: rdata = {16'h0, ADDERS[7:0], NUM_MAC[7:0]};
            // 6'd26 [0x68] MAGIC RO: 0x54444F54 ('TDOT') - identity for driver
            6'd26: rdata = 32'h54444F54;
            // ---- наблюдаемость (OBS; WORD = BAJТЫ: 6'd27=0x6C, ... 6'd56=0xE0) ----
            6'd27: rdata = {30'b0, obs_freeze_q, 1'b0};          // OBS_CTRL (RO-статус)
            6'd28: rdata = BUILD_ID;                             // BUILD_ID
            6'd29: rdata = {8'(OBS_REGMAP_V), 4'b0, CAPS_ELEMFMT, 1'b1,
                            CAPS_L2BURST, CAPS_ADDERS, CAPS_NUMMAC}; // CAPS (0x74; ELEM_FMT[22:20])
            6'd30: rdata = cnt_cycles[31:0];                     // CYCLES_LO
            6'd31: rdata = cnt_cycles[63:32];                    // CYCLES_HI
            6'd32: rdata = cnt_busy;                             // BUSY_CYCLES
            6'd33: rdata = cnt_mem;                              // MEM_CYCLES
            6'd34: rdata = cnt_load;                             // LOAD_CYCLES
            6'd35: rdata = cnt_compute;                          // COMPUTE_CYCLES
            6'd36: rdata = cnt_ar;                               // AR_CNT
            6'd37: rdata = cnt_beat;                             // BEAT_CNT
            6'd38: rdata = cnt_ar_stall;                         // AR_STALL
            6'd39: rdata = cnt_r_wait;                           // R_WAIT
            6'd40: rdata = cnt_wr;                               // WR_CNT
            6'd41: rdata = cnt_job;                              // JOB_CNT
            6'd42: rdata = cnt_fifo_full;                        // FIFO_FULL_EV
            6'd43: rdata = 32'h0;                                // SNAP (write-only)
            6'd44: rdata = snap_cycles[31:0];                    // CYCLES_LO_S
            6'd45: rdata = snap_cycles[63:32];                   // CYCLES_HI_S
            6'd46: rdata = snap_busy;                            // BUSY_S
            6'd47: rdata = snap_mem;                             // MEM_S
            6'd48: rdata = snap_load;                            // LOAD_S
            6'd49: rdata = snap_compute;                         // COMPUTE_S
            6'd50: rdata = snap_ar;                              // AR_S
            6'd51: rdata = snap_beat;                            // BEAT_S
            6'd52: rdata = snap_ar_stall;                        // AR_STALL_S
            6'd53: rdata = snap_r_wait;                          // R_WAIT_S
            6'd54: rdata = snap_wr;                              // WR_S
            6'd55: rdata = snap_job;                             // JOB_S
            6'd56: rdata = snap_fifo_full;                       // FIFO_FULL_S
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
    // ---- ELEM_FMT: расширитель beat / данные fifo ----
    logic [47:0]   fifo_wdata;
    logic          rd_accept_ok;      // приём beat завершён (1 = байт принят)
    // REVIEW-FIX 2026-10-18 (registered RREADY / timing): rd_ready_gate — это
    // «гейт» M_AXI_RREADY (= r_ready_r && rd_ready_gate), формируемый ЗАРЕГИСТРИРОВАННО
    // в PACKED6 (rbuf_room_q — место во входном staging-буфере rbuf), чтобы
    // разомкнуть комбинационный путь barrel(n_left/nbytes/emitted) -> M_AXI_RREADY
    // (WNS -4.25ns @125МГц). Для fp32 gate = rd_accept_ok (= fp_exp_busy, уже
    // регистр), для легаси = 1 — поведение этих режимов НЕ изменяется. Управляется
    // внутри gen_fifo_*.
    logic          rd_ready_gate;
    logic          fp_exp_busy;       // расширяем текущий beat (защёлкнут, hi не выдана)
    logic [63:0]   fp_beat_q;         // защёлкнутый beat (для второй половинки)
    logic          rd_fp32_exp_en;    // включать расширитель fp32 (чтение данных/весов)
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
        if (fifo_push) fifo_mem[fifo_wr[FIFO_PTRW-1:0]] <= fifo_wdata;
    end
    // синхронное чтение BRAM. Без сброса fifo_q: выходной регистр BRAM
    // аппаратного сброса не имеет, лишний reset сломал бы маппинг в BRAM.
    always_ff @(posedge clk) begin
        fifo_q <= fifo_mem[fifo_rd[FIFO_PTRW-1:0]];
    end

// (см. объявления расширителя выше, у fifo_clr; блок логики ниже).
    // Легаси: 1 beat (64 бит) = 1 элемент tf48 ([47:0]).
    // fp32  : 1 beat = 2 fp32 (по 4 байта) -> 2 записи fifo за 2 такта;
    //         RREADY отжимается на такте приёма, байт считается принятым только
    //         когда выданы ОБЕ половинки (rd_accept_ok). Расширитель активен
    //         ТОЛЬКО при чтении данных/весов (rd_fp32_exp_en); дескрипторы
    //         планировщика всегда читаются по слову (beat = 1 элемент).

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
    // комбинационные величины очередного AR-burst (4KB-кламп, Task 35/OBS);
    // объявлены здесь, т.к. xvlog требует объявления до использования в RST_ACT.
    logic [AW-1:0]  ar_addr_w;
    logic [12:0]    bnd_bytes_w;   // 13 бит: 4096 не влезает в 12 бит (12'h1000=0)
    logic [10:0]    bnd_words_w;
    logic [7:0]     len_full_w, ar_len_w;
    logic           ar_hs_w, ar_beat_w;

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
                    // выдача AR на очередной burst. P3b: BURST_RD_LEN=32
                    // (256 Б на AR). AXI4 запрещает пересекать 4KB-границу
                    // (spec A4.3.1) — длина burst клампится до границы.
                    // Здесь (main) кламп добавлен вместе с OBS (Task 35),
                    // чтобы закрыть латентный дефект при ×8-выровненном,
                    // но не 4KB-выровненном адресе.
                    if (!ar_valid_r && (rd_issued < rd_total) && !fifo_full) begin
                        ar_addr_r <= ar_addr_w;
                        ar_len_r  <= ar_len_w;
                        ar_valid_r <= 1;
                    end
                    if (ar_valid_r && M_AXI_ARREADY) begin
                        ar_valid_r <= 0;
                        rd_issued <= rd_issued + ar_len_r + 1;
                    end
                    // приём данных (fp32: только когда обе половинки beat выданы)
                    // REVIEW-FIX 2026-10-18: счёт по РЕАЛЬНОМУ рукопожатию M_AXI_RREADY
                    // (зарегистрирован в PACKED6), а не по комбинационному rd_accept_ok,
                    // чтобы rd_recv рос ровно на том такте, где beat фактически принят
                    // (для легаси/fp32 ≡ прежнее условие: rd_accept_ok=1/fp_exp_busy).
                    if (M_AXI_RVALID && M_AXI_RREADY) begin
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
    // REVIEW-FIX 2026-10-18 (timing): M_AXI_RREADY выходит как AND двух РЕГИСТРОВ
    // (r_ready_r и rd_ready_gate) -> barrel->порт комбинационный путь разомкнут.
    // В PACKED6 rd_ready_gate = rbuf_room_q (регистр «есть место во входном буфере
    // rbuf», см. gen_fifo_p6): путь сокращён до 3-бит счётчик rbuf_cnt -> компаратор
    // -> flop -> AND -> порт (короткий, ~2 регистра + комбинационный AND). rbuf —
    // 4-словный staging-буфер между AXI-slave и баррелем 6->8: slave-рукопожатие
    // идёт в rbuf, баррель потребляет из него по своей живой p6_wready, поэтому
    // beat, пришедший на такте эмита барреля, удерживается в rbuf без потери, а
    // backpressure на slave — через RREADY (AXI-легально: slave держит RVALID, пока
    // RREADY низкий). rbuf_room_q имеет 1 слот запаса -> регистр смотрит на такт
    // вперёд и rbuf никогда не переполняется (макс cnt<=2 < глубина 4), указатели
    // не сталкиваются, порядок сохраняется. Вне rd-фаз (desc-fetch) gate=1 ->
    // RREADY = r_ready_r (как в легаси). fp32/легаси gate — по прежней схеме.
    assign M_AXI_RREADY  = r_ready_r && rd_ready_gate;

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
    logic [SW-1:0] wr_strb_q;    // GAP-2-FIX: WSTRB, зарегистрированный в КОНТРОЛЛЕРЕ на такте
                                 // запуска записи. Прежний комбинационный wr_strb_ctl (= f(cstate))
                                 // сэмплировался write-мастером на СЛЕДУЮЩЕМ такте, когда cstate уже
                                 // ушёл из CS_WAIT/CS_ACCUM_WAIT в CS_WR -> WSTRB=0x3F НИКОГДА не
                                 // доходил до AXI, писались все 8 байт.
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
                        w_strb_r  <= wr_strb_q;
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
    localparam int CS_T2F_WAIT    = 14;   // ELEM_FMT=1: ждём выход tf48->fp32 (T2F)

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
    logic        sat_q;               // n_total был > MAX_N_TOTAL (насыщение) -> completion status
    logic        align_q;             // адрес задачи не кратен 8 (AXI-выравнивание) -> completion status

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
    logic [31:0] chunk_words;      // GAP-1-FIX: 64-бит слов чтения ВЕСОВ прохода.
    //                            // проход k: начало с байта elems_done_q*6, смещение
    //                            // start_skip=(elems_done_q*6)%8 => слов=ceil((skip+chunk*6)/8).
    always_comb begin
        chunk_n = (n_left_q > NUM_MAC) ? NUM_MAC : n_left_q;
        chunk_words = words_skip_fn(elems_done_q * 6 % 8, chunk_n);
    end
    // слова первого прохода (n_left_q ещё не обновлён при старте задачи; skip=0)
    wire [31:0] fp_first   = (n_total_legacy > NUM_MAC) ? NUM_MAC : n_total_legacy;
    wire [31:0] first_words = words_fn(fp_first);
    wire [31:0] sp_first   = (n_total_sched > NUM_MAC) ? NUM_MAC : n_total_sched;
    wire [31:0] sched_first_words = words_fn(sp_first);
    // слова следующего прохода (n_left_q ещё не вычтен здесь — считаем остаток)
    // GAP-1-FIX: skip следующего чтения = ((elems_done_q + chunk_n)*6)%8.
    wire [31:0] next_chunk  = (n_left_q - chunk_n > NUM_MAC) ? NUM_MAC : (n_left_q - chunk_n);
    wire [31:0] next_skip   = (elems_done_q + chunk_n) * 6 % 8;
    // ---- PIPELINE-FIX 2026-10-18: предвычисление rd_total следующего прохода ----
    // Критический путь синтеза (NUM_MAC=32, PACKED6, 125МГц): переходы
    // CS_WAIT/CS_ACCUM_WAIT -> CS_RD_DATA строили цепочку
    // `n_left_q -> chunk_n/next_chunk -> words_skip_fn -> rd_total_reg/D` комбинационно
    // в такт перехода (23 уровня, включая u_p6rd/u_acc/u_add carry-chain; WNS до
    // -1.711ns). Решение без изменения функции и формата words_skip_fn: слова
    // следующего прохода считаются ЗАРАНЕЕ 2-стадийным конвейером, пока проход
    // крутит ядро (в CS_WAIT/CS_ACCUM_WAIT/CS_RD_* n_left_q и elems_done_q стабильны
    // и равны значениям текущего прохода => next_words корректен), а в такт перехода
    // копируется готовый регистр: rd_total <= next_words_q (reg->reg, цепочка разбита
    // на 2 ступени: стадия A ловит next_chunk_q/next_skip_q, стадия B гонит
    // words_skip_fn из регистров стадии A). rd_issued/rd_recv считают с нуля на том
    // же такте rd_start (сэмплируют rd_total на 1 такт позже в RST_ACT), поэтому
    // перенос вычисления на 2 такта раньше на тайминг счёта чтения не влияет.
    logic [31:0] next_chunk_q, next_skip_q, next_words_q;
    // ---- PIPELINE-FIX 2026-10-19: prefetch АДРЕСА следующего прохода ----
    // Дефект полного flat P&R @125МГц (NUM_MAC=32/ADDERS=4 PACKED6):
    // `u_tdot/n_left_q_reg[18]/C -> u_tdot/rd_addr_reg[2]/CE` (slack -0.049ns).
    // Переходы CS_WAIT/CS_ACCUM_WAIT -> CS_RD_DATA строили комбинационную цепь
    // `n_left_q -> chunk_n -> (elems_done_q+chunk_n)*BPE / (*6/8)*8 + cur_data_q
    // -> rd_addr_reg/CE` (множитель/делитель/сдвиг = много LUT/CARRY, и CE-путь
    // хуже D-пути). Решение как для rd_total: адрес следующего прохода считается
    // ЗАРАНЕЕ 2-стадийным конвейером, пока проход крутит ядро:
    //   стадия A: next_elems_q  = elems_done_q + chunk_n
    //             (n_left_q -> chunk_n -> add -> next_elems_q/D, полтакта);
    //   стадия B: next_addr_q    = cur_data_q + offset(next_elems_q)
    //             из зарегистрированного next_elems_q (множитель/делитель вне
    //             конуса от n_left_q, цепочка разорвана на 2 ступени).
    // В такт перехода: rd_addr <= next_addr_q (reg->reg), p6_skip_q <= next_skip_q.
    // Корректность: cur_data_q стабилен ВСЮ задачу, elems_done_q/n_left_q стабильны
    // в течение прохода (обновляются только в переходах), поэтому свободный
    // потактовый апдейт корректен и успевает стабилизироваться (проход длится >>2
    // тактов). Первый проход (job_start/CS_SCHED_KICK) использует data_start_reg/
    // job_data_addr_q напрямую — его адрес НЕ предвычисляется, поведение не меняется.
    // next_skip_q уже содержит (elems_done_q+chunk_n)*6%8 = p6_skip следующего
    // прохода (см. выше), поэтому переиспользуется единый регистр.
    logic [31:0]   next_elems_q;     // стадия A: elems_done_q + chunk_n (новый счётчик прохода)
    logic [AW-1:0] next_addr_q;      // стадия B: адрес следующего прохода (готовый reg->reg)
    // сигнатура CS_LOAD (zero-fill слотов >= chunk_n) — прежняя семантика
    logic [31:0] n_in_eff;
    assign n_in_eff = chunk_n;

    wire last_pass = (n_left_q <= NUM_MAC);   // текущий проход — последний

    logic [$clog2(2*NUM_MAC):0] load_idx;
    logic [$clog2(2*NUM_MAC):0] rd_idx;    // стадия 1 конвейера: слот, читаемый из BRAM сейчас
    logic load_active;
    // BUG-050: zero-fill-маска слота rd_idx, посчитанная в стадии 1 и зарегистрированная.
    // Стадия 2 пишет слот load_idx = rd_idx-1 (инвариант конвейера), поэтому маска
    // на такте записи идентична (load_idx < n_in_eff) / ((load_idx-NUM_MAC) < n_in_eff).
    // Срезает путь n_left_q -> chunk_n/n_in_eff -> сравнение -> D-пины банка core_*.
    logic wr_mask_q;

    // ---- fp32 (ELEM_FMT=1): подача в F2T и очередь ожидающих слотов ----
    // F2T выдаёт результаты в порядке подачи (1 вход/такт фикс. задержки),
    // поэтому кольцо индексов слотов сопоставляет каждый выход со своим слотом.
    // Длина кольца >= 2*NUM_MAC (все слоты одного прохода) с запасом.
    localparam int PF_DEPTH = 2*NUM_MAC + 16;    // >= 2*NUM_MAC (все слоты прохода)
    localparam int PF_W     = $clog2(PF_DEPTH);
    localparam int SLOT_W   = $clog2(2*NUM_MAC);   // бит индекса слота (0..2*NUM_MAC-1)
    logic [PF_W-1:0] pf_wr, pf_rd;
    logic [SLOT_W-1:0] pf_slot [0:PF_DEPTH-1];
    wire pf_full  = ((pf_wr - pf_rd) >= PF_DEPTH);
    wire pf_empty = (pf_wr == pf_rd);
    logic fp_feed_done;             // все 2*NUM_MAC элементов поданы в F2T
    // feed: подаём элемент слота (rd_idx-1) в F2T. Данные берём из fifo_q
    // (элемент, popped на предыдущем такте — BRAM-задержка 1 такт, учтена как
    // в легаси 2-стадийном конвейере: стадия 2 потребляет fifo_q слота rd_idx-1).
    // zero-fill слоты получают fp32 0.0 -> F2T -> tf48 0 (тождественно zero-fill).
    wire [SLOT_W-1:0] fp_feed_slot = rd_idx - 1;
    wire fp_slot_real = (fp_feed_slot < NUM_MAC) ?
                        (fp_feed_slot < n_in_eff) :
                        ((fp_feed_slot - NUM_MAC) < n_in_eff);
    wire fp_feeding  = FP32_MODE && (cstate == CS_LOAD) && load_active &&
                       (rd_idx >= 1) && (rd_idx <= 2*NUM_MAC) && !fp_feed_done;
    assign f2t_s_valid = fp_feeding;
    assign f2t_s_data  = FP32_MODE ? (fp_slot_real ? fifo_q[31:0] : 32'h0) : 32'h0;
    // push: когда элемент подан в F2T; pop: когда F2T выдал результат
    wire pf_push = fp_feeding;
    wire pf_pop  = FP32_MODE && (cstate == CS_LOAD) && load_active && f2t_m_valid &&
                   !pf_empty;
    logic [15:0] fp_written;    // сколько слотов уже записано (< 2*NUM_MAC)
    // REVIEW-FIX 2026-10-18 (BUG-2): сброс кольца pf_slot в начале КАЖДОГО
    // прохода (не только в job_start). pf_wr/pf_rd адресуют массив pf_slot
    // размером PF_DEPTH=2*NUM_MAC+16 (PF_W=clog2(...) бит, т.е. индекс 0..2^PF_W-1,
    // что > PF_DEPTH). Без сброса между проходами указатели растут из прохода
    // в проход; на 2+ проходе попадают в диапазон [PF_DEPTH, 2^PF_W-1] — вне
    // массива -> порча слота/зависание (long-dot n>NUM_MAC). Кольцо гарантированно
    // пусто на границе проходов (все 2*NUM_MAC записей поданы и выданы F2T,
    // pf_wr==pf_rd), поэтому сброс здесь безопасен. Точка сброса — переход
    // CS_RD_WEIGHTS->CS_LOAD (начало каждого прохода), fp_feeding в этот момент
    // неактивен (не CS_LOAD) — конфликта с pf_push/pf_pop нет. В легаси
    // (FP32_MODE=0) pf_reset всегда 0 — поведение не меняется.
    wire pf_reset = FP32_MODE && (cstate == CS_RD_WEIGHTS) && rd_done;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pf_wr <= 0; pf_rd <= 0; fp_written <= 0; fp_feed_done <= 0;
        end else if (fifo_clr) begin
            pf_wr <= 0; pf_rd <= 0; fp_written <= 0; fp_feed_done <= 0;
        end else if (pf_reset) begin
            pf_wr <= 0; pf_rd <= 0; fp_written <= 0; fp_feed_done <= 0;
        end else begin
            if (pf_push) begin
                pf_slot[pf_wr] <= fp_feed_slot;
                pf_wr <= pf_wr + 1;
            end
            if (pf_pop) begin
                pf_rd <= pf_rd + 1;
                fp_written <= fp_written + 1;
            end
            // завершение подачи: rd_idx прошёл 2*NUM_MAC (все слоты поданы)
            if (FP32_MODE && (cstate == CS_LOAD) && load_active &&
                (rd_idx >= 2*NUM_MAC) && !fp_feed_done)
                fp_feed_done <= 1'b1;
        end
    end

    // ---- fp32 read/fifo: rd_fp32_exp_en, расширитель, fifo_push/wdata/accept ----
    // (размещено здесь — после объявления RST_ACT/rstate/cstate/состояний)
    assign rd_fp32_exp_en = FP32_MODE &&
                            ((cstate == CS_RD_DATA) || (cstate == CS_RD_WEIGHTS));
    // расширитель (регистры): 1 beat (64 бит) -> 2 fp32 записи в fifo за 2 такта
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fp_exp_busy <= 1'b0;
            fp_beat_q   <= 64'h0;
        end else if (!rd_fp32_exp_en) begin
            fp_exp_busy <= 1'b0;
        end else if ((rstate == RST_ACT) && M_AXI_RVALID && r_ready_r && !fp_exp_busy) begin
            fp_beat_q   <= M_AXI_RDATA;      // защёлкиваем beat, hi выдадим на след. такте
            fp_exp_busy <= 1'b1;
        end else if ((rstate == RST_ACT) && fp_exp_busy) begin
            fp_exp_busy <= 1'b0;
        end
    end

    // ---- PACKED6 (ELEM_FMT=2) read/fifo: barrel 6->8 между AXI-RDATA и FIFO ----
    // Сигналы объявлены на уровне модуля (соединяются с баррелем в gen_fifo_p6).
    logic        p6_en;          // фаза чтения данных/весов (баррель активен)
    logic        p6_arm;         // перевооружить баррель на очередное чтение (импульс)
    logic [2:0]  p6_skip_q;      // байтовое смещение 1-го элемента в 1-м слове (0,2,4,6)
    logic        p6_wready;      // баррель заявляет слово (запрос слова из вх. буфера)
    logic [47:0] p6_elem;        // 48-бит элемент (например, в fifo)
    logic        p6_elem_valid;  // 1 элемент/такт -> fifo_push
    logic        p6_drained;     // все элементы текущего чтения выданы
    // REVIEW-FIX 2026-10-18 (timing): РЕГИСТРИРОВАННЫЙ RREADY для PACKED6 через
    // входной staging-буфер rbuf (4 слова) между AXI-slave и баррелем 6->8.
    // Проблема позади плоской регистрации p6_wready: после ПРИЁМА слова баррель
    // уходит в эмит элементов на след. такт (nbytes становится >=6), т.е. «обещание»
    // RREADY, сделанное на такт раньше, протухает ровно на такте после приёма ->
    // потеря beat. Решение: slave-рукопожатие идёт В rbuf (RREADY = r_ready_r &&
    // rbuf_room_q, оба регистры -> barrel->порт путь разомкнут), а баррель
    // потребляет слова из rbuf по своей живой p6_wready. rbuf даёт эластичность:
    // даже если slave пришлёт beat на такте, где баррель ещё эмитирует, beat
    // удерживается в rbuf без потери; backpressure на slave — через RREADY.
    // Глубина 4 (не 2): при малой глубине 50%-ный счётчик и 1-бит пойнтеры в
    // круговом буфере дают коллизию wptr==rptr на заполнении -> дубль-чтение
    // устаревшего слова (observed на прогоне n=15/16). rbuf_room_q (запас 1,
    // RREADY=1 пока cnt<=1 на прошлом такте) гарантирует, что cnt никогда не
    // превысит 2 < 4 — указатели не сталкиваются, порядок сохраняется.
    // rd_ready_gate = p6_rd_phase ? rbuf_room_q : 1 (вне rd-фаз desc-fetch по слову).
    logic [63:0] rbuf_mem [0:3];      // входной буфер: 4 слова (запас от pointer-коллизий)
    logic [1:0]  rbuf_wptr, rbuf_rptr; // индексы записи/чтения (mod 4)
    logic [2:0]  rbuf_cnt;                // 0..4 записи в буфере
    logic        rbuf_room_q;             // зарегистрированное «есть место» (для RREADY)
    wire         rbuf_not_empty = (rbuf_cnt != 3'd0);
    wire         rbuf_room      = (rbuf_cnt <= 3'd1);   // 1 слот запаса -> регистр смотрит вперёд
    wire [63:0]  rbuf_head      = rbuf_mem[rbuf_rptr]; // слово головы (комбинационно из регов)
    assign p6_en = PACKED6_MODE && ((cstate == CS_RD_DATA) || (cstate == CS_RD_WEIGHTS));

    // ---- PACKED6 write: 48-бит результат -> AXI-слово с WSTRB ----
    logic [63:0]   p6_wdata;
    logic [SW-1:0] p6_wstrb;

    generate
        if (PACKED6_MODE) begin : gen_fifo_p6
            // баррель 6->8: rd-фазы через barrel + входной буфер rbuf.
            // wvalid приходит из rbuf (наличие слова), wdata - головное слово rbuf.
            packed6_rd #(.BPE(BPE), .WORD_B(SW)) u_p6rd (
                .clk(clk), .rst_n(rst_n),
                .enable(p6_en),
                .wdata(rbuf_head), .wvalid(rbuf_not_empty), .wready(p6_wready),
                .n_elem(chunk_n[15:0]), .start_skip(p6_skip_q), .start(p6_arm),
                .elem(p6_elem), .elem_valid(p6_elem_valid), .drained(p6_drained)
            );
            wire p6_rd_phase = p6_en;
            assign fifo_push    = p6_rd_phase ? p6_elem_valid
                                              : ((rstate == RST_ACT) && M_AXI_RVALID && r_ready_r);
            assign fifo_wdata   = p6_rd_phase ? p6_elem : M_AXI_RDATA[47:0];
            assign rd_accept_ok = p6_rd_phase ? p6_wready : 1'b1;

            // ---- REVIEW-FIX 2026-10-18 (timing): входной буфер + зарегистрированный RREADY ----
            // slave-заполнение: на реальном рукопожатии M_AXI_RREADY защёлкиваем RDATA в rbuf.
            // (вне p6-фазы, напр. desc-fetch, баррель/buf не активны -> заполнения нет)
            wire rbuf_push = p6_rd_phase && M_AXI_RVALID && M_AXI_RREADY;
            // потребление баррелем: слово из rbuf отдаётся баррелю по его живой p6_wready
            wire rbuf_pop  = p6_rd_phase && rbuf_not_empty && p6_wready && !p6_arm;
            // RREADY-гейт (регистр): rbuf_room_q = «на прошлом такте было >=1 свободного
            // слота». С глубиной 4 и запасом 1 даже при движении вперёд на такт буфер
            // НЕ переполняется (макс cnt<=2 < 4), а протухание «обещания» не теряет бит —
            // beat, пришедший на такте эмита барреля, просто ждёт в rbuf.
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rbuf_room_q <= 1'b0;
                end else begin
                    rbuf_room_q <= rbuf_room;
                end
            end
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rbuf_wptr <= 2'd0; rbuf_rptr <= 2'd0; rbuf_cnt <= 3'd0;
                end else if (p6_arm) begin
                    // перевооружение на новое чтение: буфер гарантированно пуст
                    // (предыдущий проход ждал p6_drained) — сброс индексов на всякий случай
                    rbuf_wptr <= 2'd0; rbuf_rptr <= 2'd0; rbuf_cnt <= 3'd0;
                end else begin
                    if (rbuf_push) begin
                        rbuf_mem[rbuf_wptr] <= M_AXI_RDATA;
                        rbuf_wptr <= rbuf_wptr + 2'd1;
                    end
                    if (rbuf_pop) begin
                        rbuf_rptr <= rbuf_rptr + 2'd1;
                    end
                    // cnt: push(+1), pop(-1), оба(0)
                    if (rbuf_push && rbuf_pop)      rbuf_cnt <= rbuf_cnt;
                    else if (rbuf_push)             rbuf_cnt <= rbuf_cnt + 3'd1;
                    else if (rbuf_pop)              rbuf_cnt <= rbuf_cnt - 3'd1;
                end
            end
            assign rd_ready_gate = p6_rd_phase ? rbuf_room_q : 1'b1;
            // write: 6-байт результат по слову (word-выровненный result_addr)
            packed6_wr #(.SW(SW), .BPE(BPE)) u_p6wr (
                .res((cstate == CS_ACCUM_WAIT) ? add_res_w : core_result),
                .woff(3'd0), .wdata(p6_wdata), .wstrb(p6_wstrb)
            );
        end else if (FP32_MODE) begin : gen_fifo_fp32
            wire fp_push_data = (rstate == RST_ACT) &&
                                (fp_exp_busy ||
                                 (M_AXI_RVALID && r_ready_r && !fp_exp_busy));
            wire fp_push_desc = (rstate == RST_ACT) && M_AXI_RVALID && r_ready_r;
            assign fifo_push   = rd_fp32_exp_en ? fp_push_data : fp_push_desc;
            assign fifo_wdata  = rd_fp32_exp_en
                               ? (fp_exp_busy ? fp_beat_q[63:32] : {16'b0, M_AXI_RDATA[31:0]})
                               : M_AXI_RDATA[47:0];
            assign rd_accept_ok = rd_fp32_exp_en ? fp_exp_busy : 1'b1;
            assign p6_wready    = 1'b1;
            assign p6_drained   = 1'b1;
            // REVIEW-FIX 2026-10-18: fp32 RREADY-гейт = rd_accept_ok (= fp_exp_busy,
            // РЕГИСТР) — поведение fp32 РОВНО прежнее (M_AXI_RREADY = r_ready_r &&
            // fp_exp_busy), комбинационного barrel-пути нет.
            assign rd_ready_gate = rd_accept_ok;
        end else begin : gen_fifo_legacy
            assign fifo_push    = (rstate == RST_ACT) && M_AXI_RVALID && r_ready_r;
            assign fifo_wdata   = M_AXI_RDATA[47:0];
            assign rd_accept_ok = 1'b1;
            assign p6_wready    = 1'b1;
            assign p6_drained   = 1'b1;
            // REVIEW-FIX 2026-10-18: легаси RREADY-гейт = 1 (RREADY = r_ready_r) —
            // без изменений.
            assign rd_ready_gate = 1'b1;
        end
        // п6-баррель не инстанцирован в не-PACKED6 режимах, но write-мастер всегда
        // использует wr_strb_q: в не-PACKED6 это {SW{1'b1}} (см. PACKED6_MODE ? p6_wstrb ниже).
        if (!PACKED6_MODE) begin : gen_p6wr_off
            assign p6_wdata = 64'h0;
            assign p6_wstrb = {SW{1'b1}};
        end
    endgenerate
    // rd_done_q: липкая защёлка завершения чтения (rd_done — импульс на 1 такт
    // RST_DONE). Для PACKED6 баррель докачивает последний элемент ЧЕРЕЗ такт
    // после rd_done, поэтому переходы чтений gирируются на rd_done_q && drained.
    // Сбрасывается в КОНТРОЛЛЕРЕ синхронно с каждым read-стартом (иначе при
    // переходе CS_RD_DATA->CS_RD_WEIGHTS застale 1 от данных ложно бы вывело
    // CS_RD_WEIGHTS за 1 такт, без исполнения чтения весов).
    logic rd_done_q;
    // rd_phase_done: для PACKED6 требуем, чтобы баррель выдал все элементы
    // текущего чтения (rd_done_q опережает последний эмит на такт); для
    // легаси/fp32 p6_drained=1 всегда -> rd_done_q (без изменения поведения).
    wire rd_phase_done = rd_done_q && (PACKED6_MODE ? p6_drained : 1'b1);
    // WSTRB: для результата (CS_WAIT/CS_ACCUM_WAIT last-pass) PACKED6 пишет 6 байт
    // (0x3F); все прочие записи (вкл. completion планировщика, fp32/легаси) - все 8.
    // Зарегистрирован в контроллере НА ТАКТЕ запуска записи (wr_strb_q), т.к.
    // прежний комбинационный вариант ловил уже ушедший в CS_WR cstate (GAP-2-FIX).

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            go_q <= 0;
            cstate <= CS_IDLE;
            core_valid_in <= 0;
            rd_start <= 0; wr_start <= 0;
            rd_addr <= 0; rd_total <= 0;
            wr_addr <= 0; wr_data <= 0; wr_strb_q <= {SW{1'b1}};
            load_idx <= 0; rd_idx <= 0; load_active <= 0; wr_mask_q <= 0;
            p6_arm <= 0; p6_skip_q <= 0; rd_done_q <= 0;
            core_data <= 0; core_weights <= 0;
            res0_reg <= 0; res1_reg <= 0;
            t2f_s_valid <= 0; t2f_s_data <= 0;
            busy_q <= 0; done_q <= 0;
            acc_valid_q <= 0; acc_q <= 0; acc_start_q <= 0;
            use_sched_q <= 0;
            cur_data_q <= 0; cur_weights_q <= 0; cur_result_q <= 0;
            n_left_q <= 0; elems_done_q <= 0; passes_q <= 0;
            next_chunk_q <= 0; next_skip_q <= 0; next_words_q <= 0;
            next_elems_q <= 0; next_addr_q <= 0;   // PIPELINE-FIX 2026-10-19: prefetch адреса следующего прохода
            sat_q <= 0; align_q <= 0;
            sched_rptr_q <= 0; done_cnt_q <= 0; irq_pending_q <= 0;
            sched_busy_q <= 1'b0;   // REVIEW-FIX/REDUCED 2026-10-17: флаг занятости планировщика (SCHED_STATUS bit0) — сброс при reset
            fetch_active <= 0; fetch_cnt <= 0;
            for (int i = 0; i < 4; i++) desc_w[i] <= 64'h0;
            job_data_addr_q <= 0; job_weights_addr_q <= 0;
            job_result_addr_q <= 0; job_n_total_q <= 0; job_tag_q <= 0;
        end else begin
            go_q <= go_reg;
            core_valid_in <= 0;
            rd_start <= 0; wr_start <= 0; acc_start_q <= 0;
            wr_strb_q <= {SW{1'b1}};   // GAP-2-FIX: default WSTRB = все байты; переопределяется на 0x3F ниже
            p6_arm <= 0;   // PACKED6: перевооружение барреля (импульс на каждый read-старт)
            rd_done_q <= rd_done_q;   // держим защёлку завершения чтения по умолчанию
            if (rd_done) rd_done_q <= 1'b1;   // чтение завершилось (импульс RST_DONE)
            t2f_s_valid <= 0; t2f_s_data <= 0;   // T2F (fp32): импульс запуска по умолчанию снят
            // PIPELINE-FIX: свободный (потактовый) апдейт предвычисленных слов
            // следующего прохода. Стадия A фиксирует next_chunk_q/next_skip_q из
            // текущих (стабильных в проходе) n_left_q/elems_done_q, стадия B
            // считает words_skip_fn из регистров стадии A -> next_words_q. В переходе
            // CS_WAIT/CS_ACCUM_WAIT -> CS_RD_DATA берётся готовый регистр, а не
            // строится длинная комбинационная цепь.
            next_chunk_q <= next_chunk;
            next_skip_q  <= next_skip;
            next_words_q <= words_skip_fn(next_skip_q, next_chunk_q);
            // PIPELINE-FIX 2026-10-19: свободное потактовое предвычисление АДРЕСА
            // следующего прохода (стадии A next_elems_q -> B next_addr_q). Стадия B
            // гонит offset из зарегистрированного next_elems_q, разрывая длинную
            // цепь n_left_q->chunk_n->(умножитель/делитель)->+cur_data_q на 2 такта.
            next_elems_q <= elems_done_q + chunk_n;
            next_addr_q  <= cur_data_q[AW-1:0]
                            + (PACKED6_MODE
                               ? (next_elems_q * 6 / 8) * 8
                               : next_elems_q * BPE);
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
                sat_q         <= (n_in_reg > MAX_N_TOTAL);
                align_q       <= FP32_MODE ? ((data_start_reg[1:0] != 2'h0) ||
                                              (weights_start_reg[1:0] != 2'h0) ||
                                              (result_addr_reg[1:0] != 2'h0))
                                           : ((data_start_reg[2:0] != 3'h0) ||
                                              (weights_start_reg[2:0] != 3'h0) ||
                                              (result_addr_reg[2:0] != 3'h0));
                cstate <= CS_RD_DATA;
                rd_addr  <= data_start_reg[AW-1:0];
                rd_total <= first_words;
                rd_start <= 1;
p6_arm   <= PACKED6_MODE;
                p6_skip_q<= 3'b0;   // первое чтение: смещение первого элемента = 0
                rd_done_q<= 1'b0;
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
                        rd_done_q<= 1'b0;
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
                    sched_busy_q <= 1'b1;   // REVIEW-FIX/REDUCED 2026-10-17: движок взял задачу из очереди -> планировщик занят
                    cur_data_q    <= {16'h0, job_data_addr_q};
                    cur_weights_q <= {16'h0, job_weights_addr_q};
                    cur_result_q  <= {16'h0, job_result_addr_q};
                    n_left_q      <= n_total_sched;
    elems_done_q  <= 0;
    passes_q      <= 0;
    sat_q         <= (job_n_total_q > MAX_N_TOTAL[15:0]);
    align_q       <= FP32_MODE ? ((job_data_addr_q[1:0] != 2'h0) ||
                                  (job_weights_addr_q[1:0] != 2'h0) ||
                                  (job_result_addr_q[1:0] != 2'h0))
                               : ((job_data_addr_q[2:0] != 3'h0) ||
                                  (job_weights_addr_q[2:0] != 3'h0) ||
                                  (job_result_addr_q[2:0] != 3'h0));
    cstate <= CS_RD_DATA;
    rd_addr  <= job_data_addr_q[AW-1:0];
                    rd_total <= sched_first_words;
                    rd_start <= 1;
                    p6_arm   <= PACKED6_MODE;
                    p6_skip_q<= 3'b0;
                    rd_done_q<= 1'b0;
                end
                CS_RD_DATA: begin
                    if (align_q) begin
                        // адрес не кратен 8 (легаси) / 4 (fp32) / (PACKED6 - то же 8):
                        // burst-первый beat частичный -> данные смещены. Пропустить.
                        cstate <= CS_DONE;
                    end else if (rd_phase_done) begin
                        cstate <= CS_RD_WEIGHTS;
                        rd_addr  <= PACKED6_MODE
                                  ? (cur_weights_q[AW-1:0]
                                     + (elems_done_q * 6 / 8) * 8)   // floor(elems_done*6/8)*8
                                  : (cur_weights_q[AW-1:0] + elems_done_q * BPE);
                        rd_total <= chunk_words;
                        rd_start <= 1;
                        p6_arm   <= PACKED6_MODE;
                        p6_skip_q<= PACKED6_MODE
                                  ? (elems_done_q * 6) % 8          // байт-сдвиг элементов в слове
                                  : 3'b0;
                        rd_done_q<= 1'b0;
                    end
                end
                CS_RD_WEIGHTS: begin
                    if (rd_phase_done) begin
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
                        if (FP32_MODE) begin
                            // fp32: загрузка через F2T. Подача идёт из fp_feeding
                            // (слот rd_idx-1 из fifo_q); результат F2T (f2t_m_valid)
                            // пишем в слот pf_slot[pf_rd]. zero-fill -> fp32 0 -> tf48 0.
                            if (rd_idx < 2*NUM_MAC) begin
                                rd_idx <= rd_idx + 1;
                            end
                            // запись результата по мере выхода из F2T
                            if (f2t_m_valid && !pf_empty) begin
                                if (pf_slot[pf_rd] < NUM_MAC)
                                    core_data[48*pf_slot[pf_rd] +: 48] <= f2t_m_data;
                                else
                                    core_weights[48*(pf_slot[pf_rd]-NUM_MAC) +: 48] <= f2t_m_data;
                            end
                            if (fp_written == 2*NUM_MAC) begin
                                load_active <= 0;
                                cstate <= CS_RUN;
                            end
                        end else begin
                            // ---- легаси (двухстадийный конвейер BRAM) ----
                            // стадия 1: pop + выдача чтения слова для слота rd_idx;
                            if (rd_idx < 2*NUM_MAC) begin
                                wr_mask_q <= (rd_idx < NUM_MAC) ?
                                             (rd_idx < n_in_eff) :
                                             ((rd_idx - NUM_MAC) < n_in_eff);
                                rd_idx <= rd_idx + 1;
                            end
                            // стадия 2: потребление fifo_q в слот load_idx
                            if (rd_idx > load_idx) begin
                                if (load_idx < NUM_MAC)
                                    core_data[48*load_idx +: 48] <=
                                        wr_mask_q ? fifo_q : 48'h0;
                                else
                                    core_weights[48*(load_idx-NUM_MAC) +: 48] <=
                                        wr_mask_q ? fifo_q : 48'h0;
                                load_idx <= load_idx + 1;
                            end else if ((rd_idx == 2*NUM_MAC) && (load_idx == 2*NUM_MAC)) begin
                                load_active <= 0;
                                cstate <= CS_RUN;
                            end
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
                                // результат: легаси пишет tf48 напрямую; fp32 -> T2F
                                if (FP32_MODE) begin
                                    t2f_s_valid <= 1;
                                    t2f_s_data  <= core_result;
                                    cstate <= CS_T2F_WAIT;
                                end else begin
                                    res0_reg <= core_result[31:0];
                                    res1_reg <= {16'h0, core_result[47:32]};
                                    cstate <= CS_WR;
                                    wr_addr <= cur_result_q[AW-1:0];
                                    wr_data <= {16'h0, core_result};
                                    wr_strb_q <= PACKED6_MODE ? p6_wstrb : {SW{1'b1}};  // GAP-2-FIX: 0x3F для результата
                                    wr_start <= 1;
                                end
                            end else begin
                                // к следующему проходу
                                n_left_q     <= n_left_q - chunk_n;
                                elems_done_q <= elems_done_q + chunk_n;
                                cstate <= CS_RD_DATA;
                                rd_addr  <= next_addr_q[AW-1:0];   // PIPELINE-FIX 2026-10-19: prefetch (reg->reg)
                                rd_total <= next_words_q;
                                rd_start <= 1;
                                p6_arm   <= PACKED6_MODE;
                                p6_skip_q<= PACKED6_MODE ? next_skip_q[2:0] : 3'b0;   // prefetch (reg->reg)
                                rd_done_q<= 1'b0;
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
                            if (FP32_MODE) begin
                                t2f_s_valid <= 1;
                                t2f_s_data  <= add_res_w;
                                cstate <= CS_T2F_WAIT;
                            end else begin
                                res0_reg <= add_res_w[31:0];
                                res1_reg <= {16'h0, add_res_w[47:32]};
                                cstate <= CS_WR;
                                wr_addr <= cur_result_q[AW-1:0];
                                wr_data <= {16'h0, add_res_w};
                                wr_strb_q <= PACKED6_MODE ? p6_wstrb : {SW{1'b1}};  // GAP-2-FIX: 0x3F для результата
                                wr_start <= 1;
                            end
                        end else begin
                            n_left_q     <= n_left_q - chunk_n;
                            elems_done_q <= elems_done_q + chunk_n;
                            cstate <= CS_RD_DATA;
                            rd_addr  <= next_addr_q[AW-1:0];   // PIPELINE-FIX 2026-10-19: prefetch (reg->reg)
                            rd_total <= next_words_q;
                            rd_start <= 1;
                            p6_arm   <= PACKED6_MODE;
                            p6_skip_q<= PACKED6_MODE ? next_skip_q[2:0] : 3'b0;   // prefetch (reg->reg)
                            rd_done_q<= 1'b0;
                        end
                    end
                end
                CS_T2F_WAIT: begin
                    // ELEM_FMT=1: ждём выход tf48->fp32, затем пишем 4 байта
                    if (t2f_m_valid) begin
                        res0_reg <= t2f_m_data;
                        res1_reg <= 32'h0;                 // результат — 32-бит fp32
                        cstate <= CS_WR;
                        wr_addr <= cur_result_q[AW-1:0];
                        wr_data <= {32'h0, t2f_m_data};    // fp32 в младшем слове
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
                        wr_data  <= {48'h0, passes_q, 6'b0, align_q, sat_q};
                        wr_start <= 1;
                        cstate <= CS_CMP3;
                    end
                end
                CS_CMP3: begin
                    if (wr_done) begin
                        sched_rptr_q <= sched_rptr_q + 8'd1;
                        done_cnt_q   <= done_cnt_q + 16'd1;
                        // опустошение очереди -> IRQ (уровень, до irq_ack)
                        if (sched_rptr_q + 8'd1 == sched_wptr_q) begin
                            // очередь опустела: снимаем флаг занятости планировщика
                            sched_busy_q <= 1'b0;  // REVIEW-FIX/REDUCED 2026-10-17: sched_busy_q диагностика (SCHED_STATUS bit0)
                            if (sched_irq_en_q)
                                irq_pending_q <= 1'b1;
                        end
                        cstate <= CS_IDLE;
                    end
                end
                default: cstate <= CS_IDLE;
            endcase
        end
    end

    assign sched_irq = sched_irq_en_q && irq_pending_q;

// DIAG-статус: наблюдаем внешний GO + состояние движка (для diag sniffer).
assign diag_go   = go_reg;
assign diag_busy = busy_q;
assign diag_done = done_q;
assign diag_f2t_sv = FP32_MODE ? f2t_s_valid : 1'b0;
assign diag_f2t_mv = FP32_MODE ? f2t_m_valid : 1'b0;
assign diag_f2t_dv = FP32_MODE ? f2t_d_valid : 1'b0;


    // fifo_pop в фазе загрузки: pop ТОЛЬКО в такт выдачи BRAM-чтения
    // (стадия 1, слот rd_idx) и только когда слово реально есть в FIFO.
    // При n_in_eff < NUM_MAC слоты-заглушки заполняются нулём БЕЗ pop —
    // иначе fifo_rd уходит за пределы загруженных данных и weights
    // читаются со смещением (мусор). См. фикс CS_LOAD (commit a86ef65)
    // и модель check_tdot_load.py.
    // REVIEW-FIX 2026-10-18 (BUG-1): число FIFO-записей, вычитываемых на группу
    // (данные/веса) в CS_LOAD. fp32-расширитель кладёт по 2 записи на 64-бит beat,
    // группа = chunk_words*2 записей (chunk_words = ceil(n/2)). Для НЕЧЁТНОГО chunk
    // это n_in_eff+1 — лишняя pad-«половинка» слова: если её не вычитать, она
    // остаётся в FIFO, веса читаются со сдвигом (slot0=0, slot i=b[i-1],
    // последний вес теряется). Вычитываем именно chunk_words*2. В легаси
    // (FP32_MODE=0) chunk_words==n_in_eff, поэтому pop_lim==n_in_eff — поведение
    // тождественно старому.
    wire [31:0] pop_lim = FP32_MODE ? (chunk_words << 1) : n_in_eff;
    always_comb begin
        fifo_pop = 1'b0;
        if (cstate == CS_LOAD && load_active && (rd_idx < 2*NUM_MAC)) begin
            if (rd_idx < NUM_MAC)
                fifo_pop = (rd_idx < pop_lim);              // data-фаза
            else
                fifo_pop = ((rd_idx - NUM_MAC) < pop_lim);  // weights-фаза
        end
    end

    // ==================== OBS: 4KB-кламп read-burst (AXI4 A4.3.1) ============
    // Комбинационные величины очередного AR-burst (декл. выше, у read-мастера).
    always_comb begin
        ar_addr_w = rd_addr + (rd_issued * SW);
        bnd_bytes_w = 13'h1000 - {1'b0, ar_addr_w[11:0]};
        bnd_words_w = ((bnd_bytes_w >> AXI_SZ) == 11'd0) ? 11'd1
                      : (bnd_bytes_w >> AXI_SZ);
        len_full_w  = ((rd_total - rd_issued) >= BURST_RD_LEN) ?
                      (BURST_RD_LEN - 1) : (rd_total - rd_issued - 1);
        // min(len_full, bnd_words-1): burst заканчивается строго ДО 4KB-границы
        ar_len_w    = ({2'b0, len_full_w} >= (bnd_words_w - 11'd1)) ?
                      bnd_words_w[7:0] - 8'd1 : len_full_w;
        ar_hs_w   = ar_valid_r && M_AXI_ARREADY;
        ar_beat_w = (rstate == RST_ACT) && M_AXI_RVALID && r_ready_r;
    end

    // ==================== OBS: фазовые признаки и счётчики ====================
    // Семантика повторяет openTPU (docs/OBSERVABILITY.md): событие считается
    // в такт, когда оно произошло; CYCLES free-running и FREEZE не подчиняется.
    wire obs_mem_c      = (cstate == CS_RD_DATA)   || (cstate == CS_RD_WEIGHTS) ||
                          (cstate == CS_FETCH_DESC);
    wire obs_load_c     = (cstate == CS_LOAD);
    wire obs_compute_c  = (cstate == CS_RUN)       || (cstate == CS_WAIT) ||
                          (cstate == CS_ACCUM_WAIT);
    wire obs_ar_stall_c = ar_valid_r && !M_AXI_ARREADY;             // бэкпрешер AR
    wire obs_r_wait_c   = (rstate == RST_ACT) && (rd_recv < rd_total) &&
                          !ar_beat_w && !obs_ar_stall_c;            // латентность/дыры
    wire obs_wr_hs_c    = M_AXI_BVALID && b_ready_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_cycles <= 64'd0;
            cnt_busy <= 32'd0;      cnt_mem <= 32'd0;
            cnt_load <= 32'd0;      cnt_compute <= 32'd0;
            cnt_ar <= 32'd0;        cnt_beat <= 32'd0;
            cnt_ar_stall <= 32'd0;  cnt_r_wait <= 32'd0;
            cnt_wr <= 32'd0;        cnt_job <= 32'd0;
            cnt_fifo_full <= 32'd0;
        end else begin
            cnt_cycles <= cnt_cycles + 64'd1;    // free-running всегда
            if (obs_clear_q) begin
                cnt_busy <= 32'd0;      cnt_mem <= 32'd0;
                cnt_load <= 32'd0;      cnt_compute <= 32'd0;
                cnt_ar <= 32'd0;        cnt_beat <= 32'd0;
                cnt_ar_stall <= 32'd0;  cnt_r_wait <= 32'd0;
                cnt_wr <= 32'd0;        cnt_job <= 32'd0;
                cnt_fifo_full <= 32'd0;
            end else if (!obs_freeze_q) begin
                cnt_busy      <= cnt_busy      + {31'b0, busy_q};
                cnt_mem       <= cnt_mem       + {31'b0, obs_mem_c};
                cnt_load      <= cnt_load      + {31'b0, obs_load_c};
                cnt_compute   <= cnt_compute   + {31'b0, obs_compute_c};
                cnt_ar        <= cnt_ar        + {31'b0, ar_hs_w};
                cnt_beat      <= cnt_beat      + {31'b0, ar_beat_w};
                cnt_ar_stall  <= cnt_ar_stall  + {31'b0, obs_ar_stall_c};
                cnt_r_wait    <= cnt_r_wait    + {31'b0, obs_r_wait_c};
                cnt_wr        <= cnt_wr        + {31'b0, obs_wr_hs_c};
                cnt_job       <= cnt_job       + {31'b0, job_start || (cstate == CS_SCHED_KICK)};
                cnt_fifo_full <= cnt_fifo_full + {31'b0, fifo_full};
            end
        end
    end

    // SNAP: атомарный снимок всех счётчиков (импульс obs_snap из записи SNAP)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            snap_cycles <= 64'd0;
            snap_busy <= 32'd0;      snap_mem <= 32'd0;
            snap_load <= 32'd0;      snap_compute <= 32'd0;
            snap_ar <= 32'd0;        snap_beat <= 32'd0;
            snap_ar_stall <= 32'd0;  snap_r_wait <= 32'd0;
            snap_wr <= 32'd0;        snap_job <= 32'd0;
            snap_fifo_full <= 32'd0;
        end else if (obs_snap) begin
            snap_cycles <= cnt_cycles;
            snap_busy <= cnt_busy;           snap_mem <= cnt_mem;
            snap_load <= cnt_load;           snap_compute <= cnt_compute;
            snap_ar <= cnt_ar;               snap_beat <= cnt_beat;
            snap_ar_stall <= cnt_ar_stall;   snap_r_wait <= cnt_r_wait;
            snap_wr <= cnt_wr;               snap_job <= cnt_job;
            snap_fifo_full <= cnt_fifo_full;
        end
    end

endmodule
