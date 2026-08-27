// ============================================================================
// compute_core_dot.sv - КОНВЕЙЕРНЫЙ троичный вычислитель dot-произведения N
// ============================================================================
// Ресурсо-оптимальный вариант, синтезируемый для N=64:
//   - ОДИН комбинационный конвертер F2T (через FSM, последовательно)
//   - Буферы a_tf[64]/b_tf[64] (регистры)
//   - ОДИН конвейерный умножитель tf40_mul_pipe (последовательная подача пар,
//     результаты - в буфер prod[64])
//   - Попарное дерево сложений через ОДИН комбинационный tf40_add
//     (порядок сложений совпадает с Python-эталоном dot_ref)
//   - ОДИН комбинационный конвертер T2F
//
// Порядок сложений в дереве (попарный, как Python dot_ref):
//   lvl0: 32 сложения  prod[2i]+prod[2i+1] -> lvl[0..31]
//   lvl1: 16 сложений  lvl[2i]+lvl[2i+1]   -> lvl[0..15]
//   ...
//   lvl5: 1 сложение   lvl[0]+lvl[1]       -> lvl[0]
//
// Протокол: valid_in=1 -> принимаем N f32 data + N f32 weights (шина одного),
// через ~300 тактов (N=64) valid_out=1 с результатом.
// ============================================================================

module compute_core_dot #(
    parameter int N = 64
)(
    input  logic               clk,
    input  logic               rst_n,
    input  logic [32*N-1:0]    data_in,
    input  logic [32*N-1:0]    weights,
    input  logic               valid_in,
    output logic [31:0]        result_out,
    output logic               valid_out,
    output logic               err_out
);
    import tfloat_pkg::*;

    // --- один F2T конвертер ---
    logic [31:0] f2t_in;
    logic [39:0] f2t_out;
    f32_to_tf40 u_f2t (.f32(f2t_in), .tf40(f2t_out));

    // --- буферы TFloat ---
    logic [39:0] a_tf [0:N-1];
    logic [39:0] b_tf [0:N-1];
    logic [39:0] prod [0:N-1];
    logic [39:0] pbuf [0:1][0:N-1];   // двойной буфер для дерева (src/dst)

    // --- один комбинационный mul (проверен, результат за 1 такт) ---
    logic        m_valid_in;
    logic [39:0] m_a, m_b, m_res;
    logic        m_err;
    tf40_mul u_mul (.a(m_a), .b(m_b), .result(m_res), .err_out(m_err));

    // --- FSM сигналы (объявляем до использования в mux) ---
    logic [2:0]  t_lvl;       // уровень дерева 0..NUM_LEVELS-1
    logic [6:0]  t_idx;       // текущее сложение на уровне

    // --- один комбинационный add ---
    logic [39:0] add_r;
    logic        add_er;
    logic        t_dst;       // в какой буфер пишем (0/1)
    logic [39:0] add_a, add_b;
    always_comb begin
        if (t_lvl == 0) begin
            add_a = prod[2*t_idx];
            add_b = prod[2*t_idx+1];
        end else begin
            // источник = буфер, в который НЕ пишем (противоположный t_dst)
            add_a = pbuf[1-t_dst][2*t_idx];
            add_b = pbuf[1-t_dst][2*t_idx+1];
        end
    end
    tf40_add u_add (.a(add_a), .b(add_b), .result(add_r), .err_out(add_er));

    // --- T2F ---
    logic [39:0] dot_res;
    logic [31:0] f32_res;
    tf40_to_f32 u_t2f (.tf40(dot_res), .f32(f32_res));

    // --- FSM ---
    localparam int PH_IDLE = 0;
    localparam int PH_CONV = 1;
    localparam int PH_MUL  = 2;
    localparam int PH_MUL_LAST = 3;
    localparam int PH_TREE = 4;
    localparam int PH_DONE = 5;
    localparam int NUM_LEVELS = $clog2(N);   // 6 для N=64

    logic [2:0]  phase;
    logic [6:0]  ci;          // счётчик конвертации 0..2N-1
    logic [6:0]  p_idx;       // счётчик подачи пар в mul 0..N-1
    logic [6:0]  prod_cnt;    // сколько продуктов получено 0..N
    logic [6:0]  t_cnt;       // число сложений на уровне
    logic        done_step;
    logic [31:0] result_q;
    logic        valid_q, err_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE;
            ci <= 0; p_idx <= 0; prod_cnt <= 0;
            t_lvl <= 0; t_idx <= 0; t_cnt <= 0; t_dst <= 0;
            done_step <= 0;
            m_valid_in <= 0; m_a <= 0; m_b <= 0;
            dot_res <= 0; result_q <= 0; valid_q <= 0; err_q <= 0;
            for (int x = 0; x < N; x++) begin
                a_tf[x] <= 0; b_tf[x] <= 0; prod[x] <= 0;
                pbuf[0][x] <= 0; pbuf[1][x] <= 0;
            end
        end else begin
            valid_q <= 0;
            case (phase)
                PH_IDLE: begin
                    if (valid_in) begin
                        f2t_in <= data_in[31:0];
                        phase <= PH_CONV;
                        ci <= 0;
                    end
                end
                PH_CONV: begin
                    // конвертация: 2N тактов (N data, затем N weights)
                    if (ci < N) begin
                        a_tf[ci] <= f2t_out;
                        f2t_in <= (ci+1 < N) ? data_in[32*(ci+1) +: 32]
                                             : weights[31:0];
                    end else begin
                        b_tf[ci-N] <= f2t_out;
                        f2t_in <= (ci+1 < 2*N) ? weights[32*(ci+1-N) +: 32]
                                               : 32'h0;
                    end
                    if (ci == 2*N-1) begin
                        phase <= PH_MUL;
                        p_idx <= 0; prod_cnt <= 0;
                        m_a <= a_tf[0]; m_b <= b_tf[0];
                    end else begin
                        ci <= ci + 1;
                    end
                end
                PH_MUL: begin
                    // подача пар в комбинационный mul: на такте p_idx ставим пару
                    // p_idx, на следующем захватываем результат пары p_idx-1.
                    // Результат пары p_idx-1 записывается в prod[p_idx-1].
                    // Последняя пара (N-1): её результат готов на доп. такте.
                    m_a <= a_tf[p_idx];
                    m_b <= b_tf[p_idx];
                    if (p_idx > 0)
                        prod[p_idx-1] <= m_res;
                    if (p_idx == N-1) begin
                        // пару N-1 подали; её результат захватим на следующем такте
                        phase <= PH_MUL_LAST;
                    end
                    p_idx <= p_idx + 1;
                end
                PH_MUL_LAST: begin
                    // m_res теперь = результат пары N-1
                    prod[N-1] <= m_res;
                    phase <= PH_TREE;
                    t_lvl <= 0; t_idx <= 0; t_cnt <= N/2; t_dst <= 0;
                end
                PH_TREE: begin
                    // попарное дерево с двойной буферизацией:
                    // источник: уровень0 = prod, уровень>0 = pbuf[1-t_dst]
                    // приёмник: pbuf[t_dst]
                    pbuf[t_dst][t_idx] <= add_r;
                    if (t_idx == t_cnt-1) begin
                        if (t_lvl == NUM_LEVELS-1) begin
                            // последний уровень: add_r - корень дерева
                            dot_res <= add_r;
                            phase <= PH_DONE;
                            done_step <= 0;
                        end else begin
                            t_dst <= 1 - t_dst;
                            t_lvl <= t_lvl + 1;
                            t_idx <= 0;
                            t_cnt <= t_cnt >> 1;
                        end
                    end else begin
                        t_idx <= t_idx + 1;
                    end
                end
                PH_DONE: begin
                    if (!done_step) begin
                        done_step <= 1;
                    end else begin
                        result_q <= f32_res;
                        err_q <= (dot_res[0 +: 2] == TRIT_ERR) ||
                                 (dot_res[2 +: 2] == TRIT_ERR);
                        valid_q <= 1;
                        phase <= PH_IDLE;
                    end
                end
            endcase
        end
    end

    assign result_out = result_q;
    assign valid_out  = valid_q;
    assign err_out    = err_q;

endmodule
