// ============================================================================
// compute_dot_par_raw.sv - ПАРАЛЛЕЛЬНЫЙ dot: NUM_MAC tfmul_raw + ДЕРЕВО barrel
// tfadd_raw (Шаг 2 пайплайнинга)
// ============================================================================
// Умножители БЕЗ нормализации (дешёвые, ~2k LUT), нормализация только на
// дереве сложений.
// Вход: NUM_MAC пар TFloat48 (data + weights).
// Выход: TFloat48 (нормализованный), валиден.
//
// ШАГ 2 (разрешено пользователем, 2026-09-06): ADDERS параллельных barrel
// tfadd_raw (Шаг 1: фиксированные 6 тактов) вместо одного time-mux аддера.
//   * Уровень L дерева (t_cnt = NUM_MAC/2 -> 1) обрабатывается раундами по
//     ADDERS сложений. Операции распределены СТРИДОМ: аддер k берёт операции
//     n = k + r*ADDERS (r — номер раунда). Чтение операндов — узкое окно с
//     КОНСТАНТНЫМИ индексами (k + r*ADDERS) по раундам (ceil(t_cnt/ADDERS))-в-1
//     мультиплексор, НЕ 32-в-1: при NUM_MAC=32/ADDERS=8 уровень 0 — 2-в-1,
//     уровни 1..4 — прямые соединения. Запись результата — в слот n = k +
//     r*ADDERS (r_q[k] хранит раунд с момента выдачи).
//   * ПАРЫ И ПОРЯДОК ОПЕРАЦИЙ идентичны последовательной версии: n нумерует
//     пары (2n, 2n+1) слева направо => результаты бит-в-бит равны при ЛЮБОМ
//     ADDERS (доказательство: rtl/block/proof_tree_par.py, секции T1/T2;
//     xsim A/B за стендом: tb_compute_dot_par_raw с ADDERS=1 vs ADDERS=8).
//   * Раунды back-to-back: новая операция выдаётся аддеру В ТАКТ valid_out
//     предыдущей (аддер в DONE уходит в IDLE и сэмплирует valid_in на
//     следующем такте; tfadd_raw сэмплирует valid_in только в PH_IDLE) =>
//     период 6 тактов на аддер. Уровень = ceil(t_cnt/ADDERS)*6 + 1 тактов.
//   * ЛОКСТЕП: все аддеры имеют одинаковую фиксированную латентность; выдача
//     разрешена только когда ВСЕ аддеры свободны или завершаются в этом такте
//     (tree_can_issue) — рассинхрон невозможен, при гипотетическом зависании
//     дерево просто ждёт (deadlock исключён: собранные операции считают
//     collected, уровень завершается по collected == t_cnt).
//   * Латентность (модель proof_tree_par.py T4, PH_MUL ~49):
//     NUM_MAC=32: ADDERS=1 -> tree ~192, dot ~243 | ADDERS=4 -> tree ~56,
//     dot ~107 | ADDERS=8 -> tree ~41, dot ~92.
//   * ADDERS=1 вырождается в последовательное поведение (A/B-базлайн);
//     рекомендовано ADDERS <= NUM_MAC/2 (лишние аддеры простаивают).
//   * Потребители (tdot_axi4 u_core, tfadd48/long-dot) — только по
//     valid_out/результату, латентно-агностичны: интерфейс не менялся.
//   * Нулевые операнды корректны начиная с BUG-041-фикса tfadd_raw
//     (тернарные веса {-1,0,+1}: нулевые продукты больше не «съедают» пары).
// ============================================================================
module compute_dot_par_raw #(
    parameter int NUM_MAC = 32,
    parameter int ADDERS  = 8      // barrel-аддеров в дереве (1 = последовательный режим)
)(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic [48*NUM_MAC-1:0]      data_in,
    input  logic [48*NUM_MAC-1:0]      weights,
    input  logic                       valid_in,
    output logic [47:0]                result_out,
    output logic                       valid_out
);

    // --- NUM_MAC параллельных умножителей (без норм) ---
    logic [NUM_MAC-1:0]  m_valid_in;
    logic [NUM_MAC-1:0]  m_valid_out;
    logic [79:0]         m_prod [0:NUM_MAC-1];
    logic [7:0]          m_e    [0:NUM_MAC-1];
    logic                m_neg  [0:NUM_MAC-1];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_MAC; gi++) begin : gen_mac
            tfmul_raw u_mul (
                .clk(clk), .rst_n(rst_n),
                .valid_in(m_valid_in[gi]),
                .a(data_in[48*gi +: 48]), .b(weights[48*gi +: 48]),
                .valid_out(m_valid_out[gi]),
                .prod(m_prod[gi]), .e(m_e[gi]), .neg(m_neg[gi])
            );
        end
    endgenerate

    // --- ADDERS параллельных barrel-аддеров (Шаг 2) ---
    logic [ADDERS-1:0]        ad_valid_in, ad_valid_out;
    logic [79:0]              ad_a   [0:ADDERS-1];
    logic [79:0]              ad_b   [0:ADDERS-1];
    logic [7:0]               ad_ea  [0:ADDERS-1];
    logic [7:0]               ad_eb  [0:ADDERS-1];
    logic                     ad_na  [0:ADDERS-1];
    logic                     ad_nb  [0:ADDERS-1];
    logic [47:0]              ad_res [0:ADDERS-1];

    genvar gk;
    generate
        for (gk = 0; gk < ADDERS; gk++) begin : gen_ad
            tfadd_raw u_add (
                .clk(clk), .rst_n(rst_n),
                .valid_in(ad_valid_in[gk]),
                .a_prod(ad_a[gk]), .a_e(ad_ea[gk]), .a_neg(ad_na[gk]),
                .b_prod(ad_b[gk]), .b_e(ad_eb[gk]), .b_neg(ad_nb[gk]),
                .valid_out(ad_valid_out[gk]), .result(ad_res[gk])
            );
        end
    endgenerate

    // буферы продуктов (ненормализованные) и результатов дерева (TFloat48)
    logic [79:0] prod [0:NUM_MAC-1];
    logic [7:0]  pe   [0:NUM_MAC-1];
    logic        pneg [0:NUM_MAC-1];
    logic [47:0] tbuf [0:1][0:NUM_MAC-1];
    logic        t_dst;

    function automatic logic signed [2:0] trit_val_ab(input logic [1:0] c);
        case (c)
            2'b01: trit_val_ab = 3'sd1;
            2'b10: trit_val_ab = -3'sd1;
            default: trit_val_ab = 3'sd0;
        endcase
    endfunction

    // распаковка TFloat48 -> (prod, e, neg) для уровней > 0 (была always_comb
    // на один ca_i, теперь функции — по экземпляру на аддер, константные окна)
    function automatic logic signed [7:0] unp_e_f(input logic [47:0] v);
        logic signed [7:0] tmp;
        tmp = 8'sd0;
        for (int i = 3; i >= 0; i--)
            tmp = tmp * 3 + trit_val_ab(v[40 + 2*i +: 2]);
        return tmp;
    endfunction

    function automatic logic unp_neg_f(input logic [47:0] v);
        unp_neg_f = 1'b0;
        for (int t = 19; t >= 0; t--)
            if (v[2*t +: 2] != 2'b00) begin
                unp_neg_f = (v[2*t +: 2] == 2'b10);
                return unp_neg_f;
            end
        return 1'b0;
    endfunction

    localparam int PH_IDLE = 0;
    localparam int PH_MUL  = 1;
    localparam int PH_TREE = 2;
    localparam int PH_DONE = 3;
    localparam int NUM_LEVELS = $clog2(NUM_MAC);
    // раундов на самый широкий уровень (ceil((NUM_MAC/2)/ADDERS))
    localparam int RMAX = (NUM_MAC/2 + ADDERS - 1) / ADDERS;

    logic [1:0]  phase;
    logic [7:0]  mul_done;
    logic [7:0]  t_lvl, t_cnt;
    logic        t_dst;
    logic [7:0]  rnd_issue;               // следующий раунд выдачи внутри уровня
    logic [7:0]  collected;               // собрано результатов на уровне
    logic [ADDERS-1:0] ad_busy_q;         // аддер занят (от выдачи до valid_out)
    logic [7:0]  r_q [0:ADDERS-1];        // раунд операции, сидящей в аддере
    logic        tree_can_issue;
    logic [47:0] dot_res, result_out_reg;
    logic        valid_q;

    // lockstep-гейт: все аддеры свободны ИЛИ завершаются в этом такте
    always_comb begin
        tree_can_issue = 1'b1;
        for (int k = 0; k < ADDERS; k++)
            if (ad_busy_q[k] && !ad_valid_out[k]) tree_can_issue = 1'b0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE;
            mul_done <= 0;
            t_lvl <= 0; t_cnt <= 0; t_dst <= 0;
            rnd_issue <= 0; collected <= 0;
            ad_busy_q <= '0;
            r_q <= '{default:'0};
            ad_valid_in <= '0;
            dot_res <= 0; result_out_reg <= 0; valid_q <= 0;
            for (int x = 0; x < NUM_MAC; x++) begin
                m_valid_in[x] <= 0;
                prod[x] <= 0; pe[x] <= 0; pneg[x] <= 0;
                tbuf[0][x] <= 0; tbuf[1][x] <= 0;
            end
            for (int k = 0; k < ADDERS; k++) begin
                ad_a[k] <= 0; ad_b[k] <= 0; ad_ea[k] <= 0; ad_eb[k] <= 0;
                ad_na[k] <= 0; ad_nb[k] <= 0;
            end
        end else begin
            valid_q <= 0;
            for (int k = 0; k < ADDERS; k++) ad_valid_in[k] <= 0;
            for (int x = 0; x < NUM_MAC; x++) m_valid_in[x] <= 0;
            case (phase)
                PH_IDLE: begin
                    if (valid_in) begin
                        phase <= PH_MUL;
                        mul_done <= 0;
                        for (int x = 0; x < NUM_MAC; x++)
                            m_valid_in[x] <= 1;
                    end
                end
                PH_MUL: begin
                    for (int x = 0; x < NUM_MAC; x++) begin
                        if (m_valid_out[x]) begin
                            prod[x] <= m_prod[x];
                            pe[x] <= m_e[x];
                            pneg[x] <= m_neg[x];
                        end
                    end
                    begin
                        logic [7:0] done_cnt;
                        done_cnt = 0;
                        for (int x = 0; x < NUM_MAC; x++)
                            if (m_valid_out[x]) done_cnt = done_cnt + 1;
                        if (done_cnt != 0)
                            mul_done <= mul_done + done_cnt;
                        if (mul_done + done_cnt >= NUM_MAC) begin
                            phase <= PH_TREE;
                            t_lvl <= 0; t_dst <= 0;
                            t_cnt <= NUM_MAC/2;
                            rnd_issue <= 0; collected <= 0;
                            ad_busy_q <= '0;
                        end
                    end
                end
                PH_TREE: begin
                    logic [7:0] cdone;
                    logic [7:0] r_iss;
                    logic [47:0] va, vb;
                    // --- 1) сбор результатов (запись в слот n = k + r*ADDERS) ---
                    cdone = 8'd0;
                    for (int k = 0; k < ADDERS; k++) begin
                        if (ad_valid_out[k]) begin
                            ad_busy_q[k] <= 1'b0;
                            cdone = cdone + 8'd1;
                            if (t_lvl == NUM_LEVELS-1) begin
                                if (k == 0 && r_q[0] == 8'd0)
                                    dot_res <= ad_res[0];
                            end else begin
                                for (int r = 0; r < RMAX; r++)
                                    if (r_q[k] == 8'(r))
                                        tbuf[t_dst][k + r*ADDERS] <= ad_res[k];
                            end
                        end
                    end
                    // --- 2) выдача следующего раунда (back-to-back, lockstep) ---
                    r_iss = rnd_issue;
                    if (tree_can_issue && (r_iss * ADDERS) < t_cnt) begin
                        for (int k = 0; k < ADDERS; k++) begin
                            if (k + r_iss*ADDERS < t_cnt) begin
                                ad_valid_in[k] <= 1'b1;
                                ad_busy_q[k]   <= 1'b1;
                                r_q[k]         <= r_iss;
                                for (int r = 0; r < RMAX; r++) begin
                                    if (r_iss == 8'(r)) begin
                                        if (t_lvl == 0) begin
                                            ad_a[k]  <= prod[2*(k + r*ADDERS)];
                                            ad_ea[k] <= pe[2*(k + r*ADDERS)];
                                            ad_na[k] <= pneg[2*(k + r*ADDERS)];
                                            ad_b[k]  <= prod[2*(k + r*ADDERS)+1];
                                            ad_eb[k] <= pe[2*(k + r*ADDERS)+1];
                                            ad_nb[k] <= pneg[2*(k + r*ADDERS)+1];
                                        end else begin
                                            va = tbuf[1-t_dst][2*(k + r*ADDERS)];
                                            vb = tbuf[1-t_dst][2*(k + r*ADDERS)+1];
                                            ad_a[k]  <= {40'h0, va[39:0]};
                                            ad_ea[k] <= unp_e_f(va);
                                            ad_na[k] <= unp_neg_f(va);
                                            ad_b[k]  <= {40'h0, vb[39:0]};
                                            ad_eb[k] <= unp_e_f(vb);
                                            ad_nb[k] <= unp_neg_f(vb);
                                        end
                                    end
                                end
                            end
                        end
                        rnd_issue <= rnd_issue + 8'd1;
                    end
                    // --- 3) завершение уровня (после выдачи: перекрытие приоритетов) ---
                    if (collected + cdone >= t_cnt) begin
                        if (t_lvl == NUM_LEVELS-1) begin
                            phase <= PH_DONE;
                        end else begin
                            t_lvl    <= t_lvl + 8'd1;
                            t_dst    <= ~t_dst;
                            t_cnt    <= t_cnt >> 1;
                            rnd_issue <= 8'd0;
                            collected <= 8'd0;
                        end
                    end else begin
                        collected <= collected + cdone;
                    end
                end
                PH_DONE: begin
                    result_out_reg <= dot_res;
                    valid_q <= 1;
                    phase <= PH_IDLE;
                end
                default: phase <= PH_IDLE;
            endcase
        end
    end

    assign result_out = result_out_reg;
    assign valid_out = valid_q;

endmodule
