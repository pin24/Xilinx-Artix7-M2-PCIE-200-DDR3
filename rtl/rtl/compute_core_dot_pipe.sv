// ============================================================================
// compute_core_dot_pipe.sv - конвейерный троичный dot-произведение N (N=16)
// ============================================================================
// Ресурсо-оптимальный вариант с ПАЙПЛАЙН-модулями (малые LUT-конусы):
//   - ОДИН конвейерный F2T (f32_to_tf40_pipe2), последовательная подача 2N
//   - ОДИН конвейерный умножитель (tf40_mul_pipe)
//   - ОДИН конвейерный сумматор (tf40_add_pipe), попарное дерево сложений
//     (порядок совпадает с Python dot_ref)
//   - ОДИН комбинационный T2F
//
// Подача в конвейеры - с ПАУЗОЙ: valid=1 ровно на 1 такт, затем 1 такт
// valid=0. Каждый пакет изолирован в конвейере, что исключает дубликат
// последнего пакета / сдвиг (проблему непрерывной неблокирующей подачи).
// Приём результатов - по m_axis_tvalid.
//
// Протокол: valid_in=1 -> принимаем N f32 data + N f32 weights, через ~1-2k
// тактов valid_out=1 с результатом.
// ============================================================================

module compute_core_dot_pipe #(
    parameter int N = 16
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

    // --- конвейерный F2T ---
    logic        f2t_valid_in;
    logic [31:0] f2t_data_in;
    logic        f2t_valid_out;
    logic [39:0] f2t_data_out;
    f32_to_tf40_pipe2 u_f2t (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(f2t_valid_in), .s_axis_tdata(f2t_data_in),
        .m_axis_tvalid(f2t_valid_out), .m_axis_tdata(f2t_data_out)
    );

    // --- конвейерный mul ---
    logic        mul_valid_in;
    logic [39:0] mul_a, mul_b;
    logic        mul_valid_out;
    logic [39:0] mul_out;
    tf40_mul_pipe u_mul (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(mul_valid_in),
        .s_axis_a(mul_a), .s_axis_b(mul_b),
        .m_axis_tvalid(mul_valid_out), .m_axis_tdata(mul_out)
    );

    // --- конвейерный add ---
    logic        add_valid_in;
    logic [39:0] add_a, add_b;
    logic        add_valid_out;
    logic [39:0] add_out;
    tf40_add_pipe u_add (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(add_valid_in),
        .s_axis_a(add_a), .s_axis_b(add_b),
        .m_axis_tvalid(add_valid_out), .m_axis_tdata(add_out)
    );

    // --- буферы ---
    logic [39:0] a_tf [0:N-1];
    logic [39:0] b_tf [0:N-1];
    logic [39:0] prod [0:N-1];
    logic [39:0] tbuf [0:1][0:N-1];

    // --- T2F ---
    logic [39:0] dot_res;
    logic [31:0] f32_res;
    tf40_to_f32 u_t2f (.tf40(dot_res), .f32(f32_res));

    // --- FSM сигналы ---
    localparam int PH_IDLE = 0;
    localparam int PH_CONV = 1;
    localparam int PH_MUL  = 2;
    localparam int PH_TREE = 3;
    localparam int PH_DONE = 4;
    localparam int NUM_LEVELS = $clog2(N);   // 4 для N=16

    logic [2:0]  phase;
    logic [7:0]  cv_i;        // подано в F2T
    logic [7:0]  cr_i;        // получено из F2T
    logic [7:0]  cm_i;        // подано в mul
    logic [7:0]  pr_i;        // получено из mul
    logic [7:0]  ca_i;        // подано пар в add (уровень)
    logic [7:0]  ar_i;        // получено рез. из add (уровень)
    logic [2:0]  t_lvl;       // уровень дерева
    logic [7:0]  t_cnt;       // число пар на уровне
    logic        t_dst;       // в какой буфер пишем
    logic        done_step;
    logic        f2t_pause, mul_pause, add_pause;
    logic [31:0] result_q;
    logic        valid_q, err_q;

    // комбинационные источники для подачи (защита от X при выходе за границы)
    logic [31:0] f2t_sel;
    logic [39:0] mul_a_sel, mul_b_sel;
    logic [39:0] add_a_sel, add_b_sel;

    always_comb begin
        f2t_sel = 32'h0;
        if (cv_i < N)
            f2t_sel = data_in[32*cv_i +: 32];
        else if (cv_i < 2*N)
            f2t_sel = weights[32*(cv_i-N) +: 32];
    end

    always_comb begin
        mul_a_sel = 40'h0;
        mul_b_sel = 40'h0;
        if (cm_i < N) begin
            mul_a_sel = a_tf[cm_i[6:0]];
            mul_b_sel = b_tf[cm_i[6:0]];
        end
    end

    always_comb begin
        add_a_sel = 0;
        add_b_sel = 0;
        if (phase == PH_TREE && ca_i < t_cnt) begin
            if (t_lvl == 0) begin
                add_a_sel = prod[2*ca_i];
                add_b_sel = prod[2*ca_i+1];
            end else begin
                add_a_sel = tbuf[1-t_dst][2*ca_i];
                add_b_sel = tbuf[1-t_dst][2*ca_i+1];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE;
            cv_i <= 0; cr_i <= 0; cm_i <= 0; pr_i <= 0;
            ca_i <= 0; ar_i <= 0; t_lvl <= 0; t_cnt <= 0; t_dst <= 0;
            done_step <= 0;
            f2t_pause <= 0; mul_pause <= 0; add_pause <= 0;
            f2t_valid_in <= 0; f2t_data_in <= 0;
            mul_valid_in <= 0; mul_a <= 0; mul_b <= 0;
            add_valid_in <= 0; add_a <= 0; add_b <= 0;
            dot_res <= 0; result_q <= 0; valid_q <= 0; err_q <= 0;
            for (int x = 0; x < N; x++) begin
                a_tf[x] <= 0; b_tf[x] <= 0; prod[x] <= 0;
                tbuf[0][x] <= 0; tbuf[1][x] <= 0;
            end
        end else begin
            valid_q <= 0;
            f2t_valid_in <= 0;
            mul_valid_in <= 0;
            add_valid_in <= 0;
            case (phase)
                PH_IDLE: begin
                    if (valid_in) begin
                        phase <= PH_CONV;
                        cv_i <= 1; cr_i <= 0;
                        // data[0] подаём сразу, затем пауза
                        f2t_valid_in <= 1;
                        f2t_data_in <= data_in[31:0];
                        f2t_pause <= 1;
                    end
                end
                PH_CONV: begin
                    // подача в F2T с паузой
                    if (f2t_pause) begin
                        f2t_pause <= 0;
                    end else if (cv_i < 2*N) begin
                        f2t_valid_in <= 1;
                        f2t_data_in <= f2t_sel;
                        cv_i <= cv_i + 1;
                        f2t_pause <= 1;
                    end
                    // приём из F2T
                    if (f2t_valid_out) begin
                        if (cr_i < N) a_tf[cr_i] <= f2t_data_out;
                        else          b_tf[cr_i - N] <= f2t_data_out;
                        cr_i <= cr_i + 1;
                    end
                    if (cr_i == 2*N) begin
                        phase <= PH_MUL;
                        cm_i <= 0; pr_i <= 0;
                        mul_pause <= 0;
                    end
                end
                PH_MUL: begin
                    if (mul_pause) begin
                        mul_pause <= 0;
                    end else if (cm_i < N) begin
                        mul_valid_in <= 1;
                        mul_a <= mul_a_sel;
                        mul_b <= mul_b_sel;
                        cm_i <= cm_i + 1;
                        mul_pause <= 1;
                    end
                    if (mul_valid_out) begin
                        prod[pr_i] <= mul_out;
                        pr_i <= pr_i + 1;
                    end
                    if (pr_i == N) begin
                        phase <= PH_TREE;
                        t_lvl <= 0; ca_i <= 0; ar_i <= 0;
                        t_cnt <= N/2; t_dst <= 0;
                        add_pause <= 0;
                    end
                end
                PH_TREE: begin
                    if (add_pause) begin
                        add_pause <= 0;
                    end else if (ca_i < t_cnt) begin
                        add_valid_in <= 1;
                        add_a <= add_a_sel;
                        add_b <= add_b_sel;
                        ca_i <= ca_i + 1;
                        add_pause <= 1;
                    end
                    if (add_valid_out) begin
                        if (t_lvl == NUM_LEVELS-1) begin
                            dot_res <= add_out;
                        end else begin
                            tbuf[t_dst][ar_i] <= add_out;
                        end
                        ar_i <= ar_i + 1;
                    end
                    if (ar_i == t_cnt) begin
                        if (t_lvl == NUM_LEVELS-1) begin
                            phase <= PH_DONE;
                            done_step <= 0;
                        end else begin
                            t_lvl <= t_lvl + 1;
                            t_dst <= 1 - t_dst;
                            ca_i <= 0;
                            ar_i <= 0;
                            t_cnt <= t_cnt >> 1;
                            add_pause <= 0;
                        end
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
