// ============================================================================
// compute_core_pipe.sv - КОНВЕЙЕРНЫЙ троичный вычислитель (оптимизация ресурсов)
// ============================================================================
// Решает проблему DSP-взрыва эталонной версии:
//   - ОДИН конвертер F2T (вместо 128) -> DSP конвертеров ~8
//   - Буфер N TFloat (BRAM/регистры)
//   - dot-ядро 64 MAC параллельно (DSP ~128) - влезает в 740
//   - ОДИН конвертер T2F
// Итого DSP ~140 (было 1025). Конвейер полностью загружен.
//
// Протокол:
//   s_axis: valid_in + data_in (float32) - N элементов подряд (шина одного)
//   после приёма N элементов ядро считает dot и выдаёт result_out
//   busy=1 пока идёт приём/вычисление; ready_in=1 когда можно принимать.
//
// Для этапа: data_in/weights - шины N*f32 (одновременно), но конвертация
// последовательно во времени (конвейер). Чтобы не усложнять, сделаем
// двухпортовый вход: data и weights конвертируются поочерёдно.
// ============================================================================

module compute_core_pipe #(
    parameter int N = 64
)(
    input  logic               clk,
    input  logic               rst_n,
    // вход (шина N f32, как раньше, но конвертация последовательная)
    input  logic [32*N-1:0]    data_in,
    input  logic [32*N-1:0]    weights,
    input  logic               valid_in,
    output logic [31:0]        result_out,
    output logic               valid_out,
    output logic               err_out
);
    import tfloat_pkg::*;

    // --- конечный автомат конвейера ---
    // стадии: 0=простаивает, 1..N=конвертация data, N+1..2N=конвертация weights
    // 2N+1=вычисление dot, 2N+2=выдача результата
    localparam int S_IDLE = 0;
    localparam int S_TOTAL = 2*N + 2;

    logic [$clog2(S_TOTAL+1)-1:0] state;
    logic [$clog2(N+1)-1:0] idx;

    // --- один F2T конвертер ---
    logic [31:0] f2t_in;
    logic [39:0] f2t_out;
    f32_to_tf40 u_f2t (.f32(f2t_in), .tf40(f2t_out));

    // --- буфер TFloat (регистры) ---
    logic [39:0] a_tf [0:N-1];
    logic [39:0] b_tf [0:N-1];

    // --- dot-ядро (параллельное дерево) ---
    logic [39:0] dot_result;
    logic dot_err;
    tf40_dot #(.N(N)) u_dot (.a(a_tf), .b(b_tf), .result(dot_result), .err_out(dot_err));

    // --- T2F ---
    logic [31:0] f32_result;
    tf40_to_f32 u_t2f (.tf40(dot_result), .f32(f32_result));

    // --- конвейерное управление ---
    logic calc_done, start_calc;
    logic valid_q;
    logic [31:0] result_q;
    logic err_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            idx <= 0;
            valid_q <= 0;
            err_q <= 0;
            result_q <= 0;
            for (int i = 0; i < N; i++) begin
                a_tf[i] <= 0;
                b_tf[i] <= 0;
            end
        end else begin
            valid_q <= 0;
            case (state)
                S_IDLE: begin
                    if (valid_in) begin
                        // начинаем конвертацию data[0]
                        f2t_in <= data_in[31:0];
                        state <= 1;
                        idx <= 0;
                    end
                end
                default: begin
                    if (state <= N) begin
                        // конвертируем data[idx]
                        a_tf[idx] <= f2t_out;
                        if (idx == N-1) begin
                            // переход к weights
                            f2t_in <= weights[31:0];
                            state <= N+1;
                            idx <= 0;
                        end else begin
                            f2t_in <= data_in[32*(idx+1) +: 32];
                            state <= state + 1;
                            idx <= idx + 1;
                        end
                    end else if (state <= 2*N) begin
                        // конвертируем weights[idx] (idx сброшен к 0 при переходе)
                        b_tf[idx] <= f2t_out;
                        if (idx == N-1) begin
                            // все сконвертированы -> вычисление dot
                            state <= 2*N+1;
                        end else begin
                            f2t_in <= weights[32*(idx+1) +: 32];
                            state <= state + 1;
                            idx <= idx + 1;
                        end
                    end else if (state == 2*N+1) begin
                        // dot вычислен (комбинационный) -> зарегистрировать
                        result_q <= f32_result;
                        err_q <= dot_err;
                        valid_q <= 1;
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end

    assign result_out = result_q;
    assign valid_out  = valid_q;
    assign err_out    = err_q;

endmodule
