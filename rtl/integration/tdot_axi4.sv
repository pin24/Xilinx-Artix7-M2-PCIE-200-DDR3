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
//   [0x44] SCHED_WPTR   хостовый указатель записи (10 бит, кольцо mod 1024) // RING-1024 2026-10-20
//   [0x48] SCHED_RPTR   RO текущий указатель чтения (10 бит) // RING-1024 2026-10-20
//   [0x4C/0x50] DESC_BASE_LO/HI  база таблицы дескрипторов (полный AXI-адрес)
//   [0x54/0x58] COMP_BASE_LO/HI  база области завершений
//   [0x5C] SCHED_STATUS RO: бит0 sched_busy, бит1 irq_pending
//   [0x60] DONE_CNT     RO счётчик завершённых задач (16 бит, free-running)
//   [0x64] CORE_PARAMS  RO: [7:0]=NUM_MAC, [15:8]=ADDERS (параметры компиляции)
//   [0x68] MAGIC        RO: 0x54444F54 ('TDOT') — идентификация блока драйвером
// Кольцо: 1024 дескрипторов (таблица 32 КБ) / 1024 завершений (16 КБ), указатели
// 10-бит с естественным переполнением (mod 1024). // RING-1024 2026-10-20
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
    parameter logic [31:0] BUILD_ID = 32'h0, // git-коммит битстрима (OBS 0x70; 0 = не передан)
    // DEVPROG_EN: программы-интерпретатор (device_prog) поверх кольца tdot.
    // При 0 (по умолчанию) — модуль ПУСТ, поведение битстрима НЕ меняется: все
    // программно-режимные пути отключены, легаси/кольцо работают по-старому.
    parameter int DEVPROG_EN = 0,   // 0 = off (легаси), 1 = программный режим активен
    parameter int DP_FIFO_DEPTH = 64 // глубина FIFO задач device_prog->ядро (только DEVPROG_EN=1)
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
    output logic                                  diag_done   // done_q
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
    logic        obs_freeze_q;   // OBS_CTRL.bit1: пауза событийного счёта
    logic        obs_clear_q;    // OBS_CTRL.bit0: импульс обнуления
    logic        obs_snap;       // SNAP: импульс защёлкивания теней
    logic [63:0] cnt_cycles;
    logic [31:0] cnt_busy, cnt_mem, cnt_load, cnt_compute;
    logic [31:0] cnt_ar, cnt_beat, cnt_ar_stall, cnt_r_wait;
    logic [31:0] cnt_wr, cnt_job, cnt_fifo_full;
    // TIMEOUT 2026-10-21: AXI burst watchdogs + observability counters
    // (объявлены здесь, т.к. регистры 0x62/0x63 в декодере выше мастеров)
    localparam int RD_TIMEOUT_LIMIT = 1 << 19;
    localparam int WR_TIMEOUT_LIMIT = 1 << 19;
    logic [19:0] rd_to_cnt, wr_to_cnt;
    logic        rd_timeout_sticky, wr_timeout_sticky;
    logic [31:0] rd_timeout_events, wr_timeout_events;
    logic        rd_to_fire, wr_to_fire;   // 1-cycle pulse when a watchdog fires
    logic [63:0] snap_cycles;
    logic [31:0] snap_busy, snap_mem, snap_load, snap_compute;
    logic [31:0] snap_ar, snap_beat, snap_ar_stall, snap_r_wait;
    logic [31:0] snap_wr, snap_job, snap_fifo_full;

    // ---- регистры планировщика ----
    logic        sched_en_q;        // SCHED_CTRL.bit0
    logic        sched_irq_en_q;    // SCHED_CTRL.bit1
    logic        sched_flush_q;     // SCHED_CTRL.bit2 (действие, самоочистка)
    logic [9:0]  sched_wptr_q;      // хостовый указатель записи (кольцо mod 1024) // RING-1024 2026-10-20
    logic [9:0]  sched_rptr_q;      // указатель чтения (движет движок, mod 1024) // RING-1024 2026-10-20
    logic [63:0] desc_base_q;       // база таблицы дескрипторов (DDR3)
    logic [63:0] comp_base_q;       // база области завершений (DDR3)
logic        irq_pending_q;      // поднято при опустошении очереди, сброс irq_ack
    logic        sched_busy_q;      // движок исполняет задачу
    logic [15:0] done_cnt_q;        // счётчик завершённых задач

    // ==================== программный режим (device_prog, DEVPROG_EN=1) ============
    // Все сигналы программного пути существуют ВСЕГДА (иначе генерация правок в
    // общий контроллер была бы невозможна), но управляются и имеют эффект ТОЛЬКО
    // когда DEVPROG_EN=1. При DEVPROG_EN=0 они зафиксированы в 0/неактивны, и
    // легали/кольцо ведут себя точно как раньше (аудит DEVPROG_EN=0-run в отчёте).
    logic [15:0] dprog_n_units_q;   // число юнитов программы (DP_CTRL[31:16])
    logic        dprog_start_q;     // импульс запуска программы (DP_CTRL.bit0=1)
    logic [AW-1:0] dprog_data_base_q, dprog_table_base_q, dprog_mailbox_base_q;
    logic        dprog_active_q;    // программный режим «вооружён» (en для device_prog)
    logic        dprog_go_q;        // go-импульс device_prog
    logic        dprog_complete_q;  // защёлкнут done device_prog (программа раскодирована end-to-end)
    logic        use_dp_q;          // текущая задача от device_prog (ветвь контроллера)

    // FIFO задач device_prog -> ядро (программный режим; ширина 3*AW+32)
    logic [DP_FIFO_DEPTH-1:0][AW-1:0] dp_fifo_a, dp_fifo_w, dp_fifo_r;
    logic [DP_FIFO_DEPTH-1:0][15:0]   dp_fifo_n, dp_fifo_tag;
    logic [$clog2(DP_FIFO_DEPTH):0]   dp_wrptr, dp_rdptr;
    wire dp_fifo_empty  = (dp_wrptr == dp_rdptr);
    wire dp_fifo_full   = ((dp_wrptr - dp_rdptr) >= DP_FIFO_DEPTH);
    // backpressure на device_prog: принять задачу можно, пока FIFO не полон.
    // device_prog держит desc_task_valid, пока ready=0 (не теряет задачи).
    wire dp_fifo_ready  = !dp_fifo_full;
    // порты чтения головы FIFO
    logic [AW-1:0] dp_z_a, dp_z_w, dp_z_r;
    logic [15:0]   dp_z_n;
    assign dp_z_a = dp_fifo_a[dp_rdptr[$clog2(DP_FIFO_DEPTH)-1:0]];
    assign dp_z_w = dp_fifo_w[dp_rdptr[$clog2(DP_FIFO_DEPTH)-1:0]];
    assign dp_z_r = dp_fifo_r[dp_rdptr[$clog2(DP_FIFO_DEPTH)-1:0]];
    assign dp_z_n = dp_fifo_n[dp_rdptr[$clog2(DP_FIFO_DEPTH)-1:0]];

    // ---- диагностика программного режима: сигналы, доступные в раннем декодере ----
    logic        dp_wdog_active_q;   // сторожевой сброс сработал (sticky до нового старта)
    logic [15:0] dp_stall_code_q;    // код остановки (0xA5A5 = watchdog)
    wire [7:0]   dp_fifo_level = dp_wrptr - dp_rdptr;

    // ---- от device_prog (инстанс ниже) ----
    logic        dp_desc_task_valid;
    logic [AW-1:0] dp_desc_task_a, dp_desc_task_w, dp_desc_task_r;
    logic [15:0] dp_desc_task_n, dp_desc_task_tag;
    logic        dp_table_req;
    logic [AW-1:0] dp_table_addr;
    logic        dp_table_rvalid, dp_table_rvalid_q;
    logic [63:0] dp_table_rdata, dp_table_rdata_q;
    logic        dp_done;
    logic        dp_mailbox_wr_start;
    logic [AW-1:0] dp_mailbox_wr_addr;
    logic [63:0] dp_mailbox_wr_data;
    logic        dp_mbox0_valid, dp_mbox1_valid;   // защёлкнутые mailbox-слова
    logic [AW-1:0] dp_mbox0_addr, dp_mbox1_addr;
    logic [63:0] dp_mbox0_data, dp_mbox1_data;

// ---- сервис table-чтения device_prog через read-мастер ----
    logic        dp_rd_start;      // 1-такт импульс чтения одного 64-бит слова таблицы
    logic [AW-1:0] dp_rd_addr;
    logic [1:0]  dpt_state;
    localparam int DPT_IDLE = 0, DPT_REQ = 1, DPT_WAIT = 2;

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
            dprog_n_units_q <= 0;
            dprog_data_base_q <= 0; dprog_table_base_q <= 0; dprog_mailbox_base_q <= 0;
            dprog_start_q <= 0;
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
                    6'd17: sched_wptr_q <= wdata_q[9:0];      // RING-1024 2026-10-20
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
                    // ---- программный режим device_prog (DEVPROG_EN=1) ----
                    // 0xE4 DP_CTRL: [31:16]=n_units, [0]=go(старт батча)
                    // 0xE8 DP_DATA_BASE, 0xEC DP_TABLE_BASE, 0xF0 DP_MBOX_BASE
                    6'd57: begin
                        dprog_n_units_q <= wdata_q[31:16];
                        if (DEVPROG_EN && wdata_q[0]) dprog_start_q <= 1'b1;
                    end
                    6'd58: dprog_data_base_q    <= wdata_q;
                    6'd59: dprog_table_base_q   <= wdata_q;
                    6'd60: dprog_mailbox_base_q <= wdata_q;
                    default: ;
                endcase
            end else begin
                if (go_reg) go_reg <= 0;         // самосброс GO
                if (sched_flush_q) sched_flush_q <= 0; // самоочистка flush
                if (obs_clear_q) obs_clear_q <= 0;     // импульс CLEAR
                if (obs_snap) obs_snap <= 0;           // импульс SNAP
                if (dprog_start_q) dprog_start_q <= 0; // самосброс старта программы
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
            6'd17: rdata = {22'h0, sched_wptr_q};   // RING-1024 2026-10-20
            6'd18: rdata = {22'h0, sched_rptr_q};   // RING-1024 2026-10-20
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
            6'd29: rdata = {8'(OBS_REGMAP_V), 7'b0, 1'b1,
                            CAPS_L2BURST, CAPS_ADDERS, CAPS_NUMMAC}; // CAPS
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
            // ---- программный режим device_prog (DEVPROG_EN=1) ----
            6'd62: rdata = rd_timeout_events;
            6'd63: rdata = wr_timeout_events;
            6'd57: rdata = {dprog_n_units_q, 15'b0, dprog_active_q};
            6'd58: rdata = dprog_data_base_q;
            6'd59: rdata = dprog_table_base_q;
            6'd60: rdata = dprog_mailbox_base_q;
            6'd61: rdata = {4'd0, dp_fifo_level, dp_stall_code_q,
                            dp_wdog_active_q, dprog_complete_q, dprog_active_q};
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
    // инициация чтения от контроллера ядра (комбинационно мультиплексируется с
    // локальным table-чтением device_prog в rd_start/rd_addr/rd_total)
    logic        ctrl_rd_start;
    logic [AW-1:0] ctrl_rd_addr;
    logic [31:0]   ctrl_rd_total;
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
            rd_to_cnt <= 0; rd_timeout_sticky <= 0; rd_timeout_events <= 0;
        end else begin
            rd_to_fire <= 1'b0;
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
                    // приём данных
                    if (M_AXI_RVALID && r_ready_r) begin
                        rd_recv  <= rd_recv + 1;
                        if (rd_recv + 1 >= rd_total) begin
                            r_ready_r <= 0;
                            rstate <= RST_DONE;
                        end
                    end
                    // TIMEOUT 2026-10-21: no AR/R progress -> abort burst, free the bus
                    if ((ar_valid_r && M_AXI_ARREADY) || (M_AXI_RVALID && r_ready_r)) begin
                        rd_to_cnt <= 0;
                    end else if (rd_to_cnt >= RD_TIMEOUT_LIMIT[19:0]) begin
                        ar_valid_r        <= 1'b0;
                        r_ready_r         <= 1'b0;
                        rd_timeout_sticky <= 1'b1;
                        rd_timeout_events <= rd_timeout_events + 1;
                        rd_to_fire        <= 1'b1;
                        rd_to_cnt         <= 0;
                        rstate            <= RST_DONE;
                    end else begin
                        rd_to_cnt <= rd_to_cnt + 1;
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
            wr_to_cnt <= 0; wr_timeout_sticky <= 0; wr_timeout_events <= 0;
        end else begin
            wr_to_fire <= 1'b0;
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
                    // TIMEOUT 2026-10-21: no AW/W/B progress -> abort, free the bus
                    if ((aw_valid_r && M_AXI_AWREADY) || (w_valid_r && M_AXI_WREADY) ||
                        (M_AXI_BVALID && b_ready_r)) begin
                        wr_to_cnt <= 0;
                    end else if (wr_to_cnt >= WR_TIMEOUT_LIMIT[19:0]) begin
                        aw_valid_r        <= 1'b0;
                        w_valid_r         <= 1'b0;
                        w_last_r          <= 1'b0;
                        b_ready_r         <= 1'b0;
                        wr_timeout_sticky <= 1'b1;
                        wr_timeout_events <= wr_timeout_events + 1;
                        wr_to_fire        <= 1'b1;
                        wr_to_cnt         <= 0;
                        wstate            <= WST_DONE;
                    end else begin
                        wr_to_cnt <= wr_to_cnt + 1;
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
    localparam int CS_ABORT_WAIT  = 14;   // abort по align: ждём освобождения read-мастера
    // ---- программный режим (DEVPROG_EN=1) ----
    localparam int CS_DP_WAIT     = 15;   // ждём задачи от device_prog / его complete
    localparam int CS_DP_KICK     = 16;   // постановка задачи из FIFO device_prog в ядро
    localparam int CS_DP_MBOX1    = 17;   // mailbox-слово 0
    localparam int CS_DP_MBOX2    = 18;   // mailbox-слово 1
    localparam int CS_DP_DONE     = 19;   // программа исполнена

    logic [4:0] cstate;
    // table-чтение device_prog разрешено только вне «данных» задач (между задачами);
    // объявлено здесь, т.к. зависит от cstate (xvlog: объявление до использования).
    wire dp_table_permit = (cstate == CS_IDLE) || (cstate == CS_DP_WAIT);

    // ---- диагностика программного режима: cstate-зависимая часть (после декларации cstate) ----
    localparam int DP_WDOG_MAX = (1 << 22);   // ~4.2M тактов без прогресса = аварийный сброс
    logic [22:0] dp_wdog_cnt;             // FIX BUG-083: 1<<22 требует бит 22 (23 бита)
    localparam logic [15:0] DP_STALL_ABORT = 16'hAB01;  // код abort (отличный от watchdog A5A5)
    localparam logic [15:0] DP_STALL_BADADDR = 16'hBAD0; // задача с адресом вне окон (2026-10-23)

    // защита от переполнения DDR3: адреса задачи обязаны попадать в окно
    // DDR3 0x8000_0000..0x8FFF_FFFF или diag_bram 0x1000_0000..0x1000_1FFF.
    function automatic bit in_win(input [31:0] a);
        in_win = ((a >= 32'h1000_0000) && (a < 32'h1000_2000)) ||
                 ((a >= 32'h8000_0000) && (a <= 32'h8FFF_FFFF));
    endfunction
    wire         dp_progress = dp_desc_task_valid || dp_mailbox_wr_start || dp_done ||
                               (cstate == CS_DP_MBOX1) || (cstate == CS_DP_MBOX2);

    logic go_q;
    wire go_pulse  = go_reg && !go_q;
    // Внешний GO принимается только когда ядро свободно и планировщик выключен
    // (иначе внешний GO мог бы вклиниться в очередь задач).
    wire go_accept = go_pulse && !busy_q && !sched_en_q;
    wire job_start = go_accept;       // легаси-старт
    assign fifo_clr = job_start || (cstate == CS_SCHED_KICK) ||
                      (DEVPROG_EN && (cstate == CS_DP_KICK));

    // read-мастер: источник запроса — ядро (ctrl_rd_*) или таблица device_prog
    // (dp_rd_*). Одновременно не стартуют: dp_rd разрешён только в CS_DP_WAIT,
    // где ядро не читает данные (см. dp_table_permit), а ctrl_rd — только в
    // состояниях задач. При DEVPROG_EN=0 dp_rd_start всегда 0, mux нейтрален.
    // ВАЖНО: переопределение адреса/длины у read-мастера действует ТОЛЬКО в
    // DPT_WAIT (фактически идущее table-чтение). В DPT_REQ (запрос ждёт, пока
    // ядро не освободит шину) mux НЕ перехватывает чтение — иначе device_prog
    // полез бы забирать шину у исполняющейся задачи. Адрес для DPT_WAIT
    // защёлкнут в dp_rd_addr на входе в DPT_REQ.
    assign rd_start = ctrl_rd_start | dp_rd_start;
    assign rd_addr  = (dpt_state == DPT_WAIT) ? dp_rd_addr : ctrl_rd_addr;
    assign rd_total = (dpt_state == DPT_WAIT) ? 32'd1       : ctrl_rd_total;

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
    // BUG-050: zero-fill-маска слота rd_idx, посчитанная в стадии 1 и зарегистрированная.
    // Стадия 2 пишет слот load_idx = rd_idx-1 (инвариант конвейера), поэтому маска
    // на такте записи идентична (load_idx < n_in_eff) / ((load_idx-NUM_MAC) < n_in_eff).
    // Срезает путь n_left_q -> chunk_n/n_in_eff -> сравнение -> D-пины банка core_*.
    logic wr_mask_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            go_q <= 0;
            cstate <= CS_IDLE;
            core_valid_in <= 0;
            ctrl_rd_start <= 0; wr_start <= 0;
            ctrl_rd_addr <= 0; ctrl_rd_total <= 0;
            wr_addr <= 0; wr_data <= 0;
            load_idx <= 0; rd_idx <= 0; load_active <= 0; wr_mask_q <= 0;
            core_data <= 0; core_weights <= 0;
            res0_reg <= 0; res1_reg <= 0;
            busy_q <= 0; done_q <= 0;
            acc_valid_q <= 0; acc_q <= 0; acc_start_q <= 0;
            use_sched_q <= 0;
            cur_data_q <= 0; cur_weights_q <= 0; cur_result_q <= 0;
            n_left_q <= 0; elems_done_q <= 0; passes_q <= 0;
            sat_q <= 0; align_q <= 0;
            sched_rptr_q <= 0; done_cnt_q <= 0; irq_pending_q <= 0;
            fetch_active <= 0; fetch_cnt <= 0;
            for (int i = 0; i < 4; i++) desc_w[i] <= 64'h0;
            job_data_addr_q <= 0; job_weights_addr_q <= 0;
            job_result_addr_q <= 0; job_n_total_q <= 0; job_tag_q <= 0;
            dprog_go_q <= 0; dprog_active_q <= 0;
            dprog_complete_q <= 0; use_dp_q <= 0;
            dp_wrptr <= 0; dp_rdptr <= 0;
            dp_mbox0_valid <= 0; dp_mbox1_valid <= 0;
            dp_wdog_active_q <= 0; dp_stall_code_q <= 0; dp_wdog_cnt <= 0;
            // dp_rd_*/dpt_state/dp_table_* — инстанс и table-FSM device_prog (generate)
        end else begin
            go_q <= go_reg;
            core_valid_in <= 0;
            ctrl_rd_start <= 0; wr_start <= 0; acc_start_q <= 0;
            dprog_go_q <= 0;
            // ---- программный режим: приём задач device_prog в FIFO, mailbox, complete ----
            if (DEVPROG_EN) begin
                // push задачи от device_prog с backpressure: dp_fifo_ready = !dp_fifo_full.
                // device_prog держит desc_task_valid, пока ready=0, и НЕ продвигает
                // счётчик нейрона — длинные программы (n_out*pass >> глубины FIFO) не
                // теряют задачи при переполнении.
                if (dprog_active_q && dp_desc_task_valid && dp_fifo_ready) begin
                    dp_fifo_a[dp_wrptr[$clog2(DP_FIFO_DEPTH)-1:0]]   <= dp_desc_task_a;
                    dp_fifo_w[dp_wrptr[$clog2(DP_FIFO_DEPTH)-1:0]]   <= dp_desc_task_w;
                    dp_fifo_r[dp_wrptr[$clog2(DP_FIFO_DEPTH)-1:0]]   <= dp_desc_task_r;
                    dp_fifo_n[dp_wrptr[$clog2(DP_FIFO_DEPTH)-1:0]]   <= dp_desc_task_n;
                    dp_fifo_tag[dp_wrptr[$clog2(DP_FIFO_DEPTH)-1:0]] <= dp_desc_task_tag;
                    dp_wrptr <= dp_wrptr + 1;
                end
                // защёлка mailbox-слов device_prog (выдаются им в конце программы)
                if (dp_mailbox_wr_start) begin
                    if (dp_mailbox_wr_addr == dprog_mailbox_base_q)
                        {dp_mbox0_valid, dp_mbox0_addr, dp_mbox0_data} <=
                            {1'b1, dp_mailbox_wr_addr, dp_mailbox_wr_data};
                    else
                        {dp_mbox1_valid, dp_mbox1_addr, dp_mbox1_data} <=
                            {1'b1, dp_mailbox_wr_addr, dp_mailbox_wr_data};
                end
                // complete: device_prog закончил раскодку всей программы
                if (dp_done) dprog_complete_q <= 1'b1;
                if (dprog_start_q) begin
                    dprog_complete_q <= 1'b0;
                    dp_mbox0_valid <= 1'b0; dp_mbox1_valid <= 1'b0;
                    dp_wdog_active_q <= 1'b0; dp_stall_code_q <= 0; dp_wdog_cnt <= 0;
                end
                // ---- сторожевой таймер: интерпретатор не должен висеть вечно ----
                // При отсутствии прогресса снимает active и возвращает ядро в idle,
                // чтобы не заклинивать общую AXI-шинy на железе; host читает DP_STAT
                // и по коду 0xA5A5 понимает, что программа не завершилась.
                if (dprog_active_q) begin
                    if (dp_progress)
                        dp_wdog_cnt <= '0;
                    else if (dp_wdog_cnt >= DP_WDOG_MAX) begin
                        dp_wdog_active_q <= 1'b1;
                        dp_stall_code_q  <= 16'hA5A5;
                        dp_wdog_cnt      <= '0;
                    end else
                        dp_wdog_cnt <= dp_wdog_cnt + 1'b1;
                end
            end
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
                align_q       <= ((data_start_reg[2:0] != 3'h0) ||
                                  (weights_start_reg[2:0] != 3'h0) ||
                                  (result_addr_reg[2:0] != 3'h0));
                cstate <= CS_RD_DATA;
                ctrl_rd_addr  <= data_start_reg[AW-1:0];
                ctrl_rd_total <= (n_total_legacy > NUM_MAC) ? NUM_MAC : n_total_legacy;
                ctrl_rd_start <= 1;
            end
            if (rd_to_fire || wr_to_fire) begin
                // TIMEOUT: AXI master aborted; retire the task so the ring keeps
                // moving even if the bus is dead.
                busy_q <= 1'b0; done_q <= 1'b1;
                if (use_sched_q) begin
                    sched_rptr_q <= sched_rptr_q + 10'd1;
                    done_cnt_q   <= done_cnt_q + 16'd1;
                    if (sched_irq_en_q && (sched_rptr_q + 10'd1 == sched_wptr_q))
                        irq_pending_q <= 1'b1;
                end
                // FIX BUG-085: abort программного батча -> терминальный completion-mailbox
                // со status!=0 и сброс DP-FSM/FIFO; обход SUCCESS-фолбэка CS_DP_MBOX2.
                if (use_dp_q) begin
                    dp_mbox0_valid <= 1'b1; dp_mbox0_addr <= dprog_mailbox_base_q;
                    dp_mbox0_data  <= {48'h0, dprog_n_units_q};
                    dp_mbox1_valid <= 1'b1; dp_mbox1_addr <= dprog_mailbox_base_q + 32'h8;
                    dp_mbox1_data  <= {40'h0, dprog_n_units_q, 8'd1};   // status = ABORT
                    dprog_active_q <= 1'b0; use_dp_q <= 1'b0; dprog_go_q <= 1'b0;
                    dp_wrptr <= '0; dp_rdptr <= '0;
                    dp_wdog_active_q <= 1'b0; dp_wdog_cnt <= '0;
                    dprog_complete_q <= 1'b0;              // НЕ «успех» (аудит P2)
                    dp_stall_code_q  <= DP_STALL_ABORT;    // диагностика abort в DP_STAT
                    cstate           <= CS_DP_MBOX1;
                end else begin
                    cstate <= CS_IDLE;
                end
            end else case (cstate)
                CS_IDLE: begin
                    // программный режим (DEVPROG_EN=1): старт батча по dprog_start_q
                    if (DEVPROG_EN && dprog_start_q) begin
                        dprog_active_q   <= 1'b1;
                        dprog_complete_q <= 1'b0;
                        dprog_go_q       <= 1'b1;        // go-импульс device_prog
                        dp_wrptr         <= '0; dp_rdptr <= '0;
                        use_dp_q         <= 1'b1;
                        busy_q           <= 1'b1; done_q <= 1'b0;
                        acc_valid_q      <= 1'b0;
                        cstate           <= CS_DP_WAIT;
                    end else if (sched_flush_q) begin
                        sched_rptr_q <= 10'h0;            // flush очереди // RING-1024 2026-10-20
                    end else if (sched_pull) begin
                        // fetch дескриптора: 4 слова (32 Б) с DESC_BASE+rptr*32
                        fetch_active <= 1;
                        fetch_cnt <= 0;
                        ctrl_rd_addr  <= desc_base_q[AW-1:0] + {17'h0, sched_rptr_q, 5'b0};  // RING-1024 2026-10-20
                        ctrl_rd_total <= 32'd4;
                        ctrl_rd_start <= 1;
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
                    // entry действия задачи планировщика; страж окна.
                    // адреса/счётчик безусловно (короткий путь к ctrl_rd_*),
                    // in_win гейтит только ctrl_rd_start (AXI) и состояние (FATAL fix).
                    busy_q <= 1; done_q <= 0;
                    acc_valid_q <= 0;
                    use_sched_q <= 1'b1;
                    cur_data_q    <= {16'h0, job_data_addr_q};
                    cur_weights_q <= {16'h0, job_weights_addr_q};
                    cur_result_q  <= {16'h0, job_result_addr_q};
                    n_left_q      <= n_total_sched;
    elems_done_q  <= 0;
    passes_q      <= 0;
    sat_q         <= (job_n_total_q > MAX_N_TOTAL[15:0]);
    align_q       <= ((job_data_addr_q[2:0] != 3'h0) ||
                      (job_weights_addr_q[2:0] != 3'h0) ||
                      (job_result_addr_q[2:0] != 3'h0));
    ctrl_rd_addr  <= job_data_addr_q[AW-1:0];
                    ctrl_rd_total <= (n_total_sched > NUM_MAC) ? NUM_MAC
                                                              : n_total_sched;
                    if (in_win(job_data_addr_q) && in_win(job_weights_addr_q) && in_win(job_result_addr_q)) begin
                        ctrl_rd_start <= 1;
                        cstate <= CS_RD_DATA;
                    end else begin
                        // невалидный адрес: ретир задачи без AXI
                        ctrl_rd_start <= 0;
                        sched_rptr_q <= sched_rptr_q + 10'd1;
                        done_cnt_q   <= done_cnt_q + 16'd1;
                        dp_stall_code_q <= DP_STALL_BADADDR;
                        cstate <= CS_IDLE;
                    end
                end
                CS_RD_DATA: begin
                    if (align_q) begin
                        // адрес не кратен 8: burst-первый beat частичный -> данные
                        // смещены. Пропустить вычисление, завершить со статусом align.
                        // ВАЖНО: ctrl_rd_start уже выдан (job_start / CS_SCHED_KICK), поэтому
                        // read-мастер принял AR и продолжает наполнять FIFO. Прямой
                        // переход в CS_DONE снял бы busy_q, следующая задача сделала бы
                        // fifo_clr посреди активного burst и прочитала бы данные со
                        // смещением -> сначала дожидаемся освобождения мастера.
                        cstate <= CS_ABORT_WAIT;
                    end else if (rd_done) begin
                        cstate <= CS_RD_WEIGHTS;
                        ctrl_rd_addr  <= cur_weights_q[AW-1:0] + elems_done_q * SW;
                        ctrl_rd_total <= chunk_n;
                        ctrl_rd_start <= 1;
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
                        // стадия 1: pop + выдача чтения слова для слота rd_idx;
                        // предрасчёт zero-fill-маски слота rd_idx -> wr_mask_q
                        // (стадия 2 в этом же такте потребляет wr_mask_q для слота
                        // load_idx = rd_idx-1 — маска уже зарегистрирована)
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
                                ctrl_rd_addr  <= cur_data_q[AW-1:0]
                                            + (elems_done_q + chunk_n) * SW;
                                ctrl_rd_total <= (n_left_q - chunk_n > NUM_MAC) ?
                                            NUM_MAC : (n_left_q - chunk_n);
                                ctrl_rd_start <= 1;
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
                            ctrl_rd_addr  <= cur_data_q[AW-1:0]
                                        + (elems_done_q + chunk_n) * SW;
                            ctrl_rd_total <= (n_left_q - chunk_n > NUM_MAC) ?
                                        NUM_MAC : (n_left_q - chunk_n);
                            ctrl_rd_start <= 1;
                        end
                    end
                end
                CS_WR: begin
                    if (wr_done) begin
                        cstate <= CS_DONE;
                    end
                end
                // Abort по align: задача завершается, но только когда read-мастер
                // реально свободен — burst дочитан и автомат вернулся в RST_IDLE
                // (ar_valid_r погашен в RST_DONE). Только после этого уходим в
                // CS_DONE, т.е. busy_q снимается уже при отпущенной шине, и fifo_clr
                // следующей задачи не может попасть в середину burst. Данные abort-
                // burst не используются: указатели FIFO сбрасывает fifo_clr.
                CS_ABORT_WAIT: begin
                    if ((rstate == RST_IDLE) && !ar_valid_r) begin
                        cstate <= CS_DONE;
                    end
                end
                CS_DONE: begin
                    if (DEVPROG_EN && use_dp_q) begin
                        // программный режим: задача device_prog завершена; busy
                        // держим, пока не исполнена ВСЯ программа (и mailbox)
                        busy_q <= 1'b1; done_q <= 1'b0;
                        cstate <= CS_DP_WAIT;
                    end else begin
                        busy_q <= 0; done_q <= 1;
                        cstate <= use_sched_q ? CS_CMP1 : CS_IDLE;
                    end
                end
                // ---- completion записи задачи планировщика ----
                CS_CMP1: begin
                    // W0: {tag[15:0], result[47:0]}
                    wr_addr  <= comp_base_q[AW-1:0] + {18'h0, sched_rptr_q, 4'b0};  // RING-1024 2026-10-20
                    wr_data  <= {job_tag_q, res1_reg[15:0], res0_reg};
                    wr_start <= 1;
                    cstate <= CS_CMP2;
                end
                CS_CMP2: begin
                    if (wr_done) begin
                        // W1: {48'h0, passes[7:0], status[7:0]}
                        wr_addr  <= comp_base_q[AW-1:0]
                                    + {18'h0, sched_rptr_q, 4'b0} + SW;  // RING-1024 2026-10-20
                        wr_data  <= {48'h0, passes_q, 6'b0, align_q, sat_q};
                        wr_start <= 1;
                        cstate <= CS_CMP3;
                    end
                end
                CS_CMP3: begin
                    if (wr_done) begin
                        sched_rptr_q <= sched_rptr_q + 10'd1;   // RING-1024 2026-10-20
                        done_cnt_q   <= done_cnt_q + 16'd1;
                        // опустошение очереди -> IRQ (уровень, до irq_ack)
                        if (sched_irq_en_q &&
                            (sched_rptr_q + 10'd1 == sched_wptr_q))  // RING-1024 2026-10-20
                            irq_pending_q <= 1'b1;
                        cstate <= CS_IDLE;
                    end
                end
                // ---- программный режим (DEVPROG_EN=1): исполнение батча ----
                CS_DP_WAIT: begin
                    // ждём задачу от device_prog (dp_fifo) ИЛИ конца программы
                    if (DEVPROG_EN) begin
                        if (!dp_fifo_empty) begin
                            // НЕ ставим задачу, пока идёт table-чтение device_prog:
                            // иначе table-чтение перехватывает read-мастер (rd_total=1)
                            // и задача читает только 1 слово -> переполнение FIFO.
                            if (dpt_state != DPT_IDLE) begin
                                cstate <= CS_DP_WAIT;   // дожидаемся завершения чтения таблицы
                            end else begin
                                cstate <= CS_DP_KICK;
                            end
                        end else if (dprog_complete_q) begin
                            // программа раскодирована + все задачи исполнены -> mailbox
                            cstate <= CS_DP_MBOX1;
                        end else begin
                            cstate <= CS_DP_WAIT;   // держим: здесь разрешены table-чтения
                        end
                    end else begin
                        cstate <= CS_IDLE;
                    end
                end
                CS_DP_KICK: begin
                    // постановка задачи из FIFO device_prog в ядро; страж окна.
                    // адреса/счётчик назначаются БЕЗУСЛОВНО (короткий путь к ctrl_rd_*),
                    // in_win влияет только на ctrl_rd_start (импульс AXI) и следующее
                    // состояние — не на многоразрядный адресный путь (FATAL timing fix).
                    if (DEVPROG_EN) begin
                        busy_q <= 1; done_q <= 0;
                        acc_valid_q <= 0;
                        use_dp_q      <= 1'b1;
                        use_sched_q   <= 1'b0;
                        cur_data_q    <= {16'h0, dp_z_a};
                        cur_weights_q <= {16'h0, dp_z_w};
                        cur_result_q  <= {16'h0, dp_z_r};
                        n_left_q      <= {16'h0, dp_z_n};
                        elems_done_q  <= 0;
                        passes_q      <= 0;
                        sat_q         <= (dp_z_n > MAX_N_TOTAL[15:0]);
                        align_q       <= ((dp_z_a[2:0] != 3'h0) ||
                                          (dp_z_w[2:0] != 3'h0) ||
                                          (dp_z_r[2:0] != 3'h0));
                        dp_rdptr      <= dp_rdptr + 1;    // pop FIFO
                        cstate        <= (in_win(dp_z_a) && in_win(dp_z_w) && in_win(dp_z_r))
                                         ? CS_RD_DATA : CS_DP_KICK;
                        ctrl_rd_addr  <= dp_z_a[AW-1:0];
                        ctrl_rd_total <= ({16'h0, dp_z_n} > NUM_MAC) ? NUM_MAC
                                                                     : {16'h0, dp_z_n};
                        ctrl_rd_start <= (in_win(dp_z_a) && in_win(dp_z_w) && in_win(dp_z_r));
                        if (!(in_win(dp_z_a) && in_win(dp_z_w) && in_win(dp_z_r)))
                            dp_stall_code_q <= DP_STALL_BADADDR;
                    end else begin
                        cstate <= CS_IDLE;
                    end
                end
                CS_DP_MBOX1: begin
                    if (DEVPROG_EN) begin
                        // слово 0 mailbox (защёлкнуто у device_prog)
                        wr_addr  <= (dp_mbox0_valid) ? dp_mbox0_addr : dprog_mailbox_base_q;
                        wr_data  <= (dp_mbox0_valid) ? dp_mbox0_data
                                                     : {48'h0, 16'(dprog_n_units_q)};
                        wr_start <= 1;
                        cstate  <= CS_DP_MBOX2;
                    end else cstate <= CS_IDLE;
                end
                CS_DP_MBOX2: begin
                    if (DEVPROG_EN) begin
                        if (wr_done) begin
                            // слово 1 mailbox ({40'h0, units[15:0], status=0})
                            wr_addr  <= (dp_mbox1_valid) ? dp_mbox1_addr
                                                         : (dprog_mailbox_base_q + 32'h8);
                            wr_data  <= (dp_mbox1_valid) ? dp_mbox1_data
                                                         : {40'h0, dprog_n_units_q, 8'd0};
                            wr_start <= 1;
                            cstate  <= CS_DP_DONE;
                        end
                    end else cstate <= CS_IDLE;
                end
                CS_DP_DONE: begin
                    if (DEVPROG_EN) begin
                        if (wr_done) begin
                            busy_q  <= 0; done_q <= 1;
                            use_dp_q <= 1'b0;
                            dprog_active_q <= 1'b0;   // снять en у device_prog
                            cstate  <= CS_IDLE;
                        end else begin
                            cstate  <= CS_DP_DONE;
                        end
                    end else cstate <= CS_IDLE;
                end
                default: cstate <= CS_IDLE;
            endcase
            // сторожевой сброс применяется ПОСЛЕ case (переопределяет его),
            // чтобы гарантированно вернуть ядро в idle и снять active.
            if (dprog_active_q && dp_wdog_active_q) begin
                dprog_active_q <= 1'b0; use_dp_q <= 1'b0;
                cstate <= CS_IDLE; busy_q <= 0; done_q <= 1;
            end
        end
    end

    assign sched_irq = sched_irq_en_q && irq_pending_q;

// DIAG-статус: наблюдаем внешний GO + состояние движка (для diag sniffer).
assign diag_go   = go_reg;
assign diag_busy = busy_q;
assign diag_done = done_q;


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
    // CS_ABORT_WAIT — тоже мемориальная фаза: read-burst физически ещё в шине,
    // эти такты иначе выпадали бы из учёта cnt_mem.
    wire obs_mem_c      = (cstate == CS_RD_DATA)   || (cstate == CS_RD_WEIGHTS) ||
                          (cstate == CS_FETCH_DESC) || (cstate == CS_ABORT_WAIT);
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

    // ==================== устройственный интерпретатор (device_prog, DEVPROG_EN=1) ====
    // Таблица юнитов читается из «DDR» через читающий радио/read-мастер (одно
    // 64-бит слово за раз), чтобы table_rvalid/rdata подавались device_prog.
    // При DEVPROG_EN=0 программный путь заземлён и не влияет на поведение
    // (легали и кольцо работают по-старому).
    generate
    if (DEVPROG_EN) begin : gen_devprog_on
        device_prog #(
            .DEVPROG_EN   (1'b1),
            .NUM_MAC      (NUM_MAC),
            .ADDR_WIDTH   (AW),
            .UNIT_BYTES   (32),
            .ELEM_BYTES   (8)
        ) u_devprog (
            .clk             (clk),
            .rst_n           (rst_n),
            .en              (dprog_active_q),
            .go              (dprog_go_q),
            .data_base       (dprog_data_base_q),
            .table_base      (dprog_table_base_q),
            .mailbox_base    (dprog_mailbox_base_q),
            .n_units         (dprog_n_units_q),
            .desc_task_valid (dp_desc_task_valid),
            .desc_task_a     (dp_desc_task_a),
            .desc_task_w     (dp_desc_task_w),
            .desc_task_r     (dp_desc_task_r),
            .desc_task_n     (dp_desc_task_n),
            .desc_task_tag   (dp_desc_task_tag),
            .table_req       (dp_table_req),
            .table_addr      (dp_table_addr),
            .table_rvalid    (dp_table_rvalid),
            .table_rdata     (dp_table_rdata),
            .desc_task_ready (dp_fifo_ready),    // FIFO не полон — можно принимать задачу
            .done            (dp_done),
            .mailbox_wr_start(dp_mailbox_wr_start),
            .mailbox_wr_addr (dp_mailbox_wr_addr),
            .mailbox_wr_data (dp_mailbox_wr_data)
        );

        // ---- table-чтение через read-мастер (1 слово/запрос) ----
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                dpt_state       <= DPT_IDLE;
                dp_rd_start     <= 1'b0;
                dp_rd_addr      <= '0;
                dp_table_rvalid_q <= 1'b0;
                dp_table_rdata_q  <= 64'h0;
            end else begin
                dp_rd_start <= 1'b0;
                dp_table_rvalid_q <= 1'b0;
                case (dpt_state)
                    DPT_IDLE: begin
                        if (dp_table_req) begin
                            dp_rd_addr  <= dp_table_addr;   // защёлка адреса на всё чтение
                            dpt_state   <= DPT_REQ;
                        end
                    end
                    DPT_REQ: begin
                        // разрешено читать таблицу только когда ядро не читает
                        // данные (между задачами) и read-мастер свободен
                        if (dp_table_permit && (rstate == RST_IDLE)) begin
                            dp_rd_start <= 1'b1;
                            dpt_state   <= DPT_WAIT;
                        end
                    end
                    DPT_WAIT: begin
                        // вернулось единственное слово таблицы
                        if (fifo_push) begin
                            dp_table_rdata_q  <= M_AXI_RDATA;
                            dp_table_rvalid_q <= 1'b1;
                            dpt_state <= DPT_IDLE;
                        end
                    end
                    default: dpt_state <= DPT_IDLE;
                endcase
            end
        end
        assign dp_table_rvalid = dp_table_rvalid_q;
        assign dp_table_rdata  = dp_table_rdata_q;
    end else begin : gen_devprog_off
        // 0-ветвь: программный путь заземлён (device_prog отсутствует).
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                dpt_state         <= DPT_IDLE;
                dp_rd_start       <= 1'b0;
                dp_rd_addr        <= '0;
                dp_table_rvalid_q <= 1'b0;
                dp_table_rdata_q  <= 64'h0;
            end else begin
                dp_rd_start       <= 1'b0;
                dp_table_rvalid_q <= 1'b0;
                dpt_state         <= DPT_IDLE;
            end
        end
        assign dp_table_rvalid = 1'b0;
        assign dp_table_rdata  = 64'h0;
        always_comb begin
            dp_desc_task_valid = 1'b0;
            dp_desc_task_a     = '0;
            dp_desc_task_w     = '0;
            dp_desc_task_r     = '0;
            dp_desc_task_n     = '0;
            dp_desc_task_tag   = '0;
            dp_table_req       = 1'b0;
            dp_table_addr      = '0;
            dp_done            = 1'b0;
            dp_mailbox_wr_start= 1'b0;
            dp_mailbox_wr_addr = '0;
            dp_mailbox_wr_data = '0;
        end
    end
    endgenerate

endmodule
