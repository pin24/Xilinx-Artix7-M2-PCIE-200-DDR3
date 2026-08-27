// ============================================================================
// compute_core.sv - троичный вычислительный блок (эталон интеграции)
// ============================================================================
// Принимает 64 float32-значения (входной вектор) и 64 float32-веса,
// конвертирует в TFloat40, считает dot-произведение 64 MAC, результат
// конвертирует обратно в float32.
//
// Интерфейс: комбинационный конвейер (для синтеза - зарегистрировать).
// В реальной системе входы будут из AXI-Stream / DDR3, здесь - прямой
// вектор для проверки интеграции.
//
// Структура:
//   [64x f32] --F2T--> [64x TFloat] --dot--> [TFloat] --T2F--> [f32 out]
// ============================================================================

module compute_core #(
    parameter int N = 64
)(
    input  logic               clk,
    input  logic               rst_n,
    // входной вектор (N x f32)
    input  logic [32*N-1:0]    data_in,    // N float32 подряд (lsb первый)
    input  logic [32*N-1:0]    weights,    // N float32 весов
    input  logic               valid_in,
    output logic [31:0]        result_out, // скалярное произведение (float32)
    output logic               valid_out,
    output logic               err_out
);
    import tfloat_pkg::*;

    // --- конвертация f32 -> TFloat40 ---
    logic [39:0] a_tf [0:N-1];
    logic [39:0] b_tf [0:N-1];

    genvar g;
    generate
        for (g = 0; g < N; g++) begin : gen_f2t
            f32_to_tf40 u_f2t_a (
                .f32(data_in[32*g +: 32]),
                .tf40(a_tf[g])
            );
            f32_to_tf40 u_f2t_b (
                .f32(weights[32*g +: 32]),
                .tf40(b_tf[g])
            );
        end
    endgenerate

    // --- dot-ядро ---
    logic [39:0] dot_result;
    logic dot_err;

    tf40_dot #(.N(N)) u_dot (
        .a(a_tf), .b(b_tf),
        .result(dot_result), .err_out(dot_err)
    );

    // --- T2F ---
    logic [31:0] f32_result;
    tf40_to_f32 u_t2f (.tf40(dot_result), .f32(f32_result));

    // --- выходные регистры ---
    logic valid_q, err_q;
    logic [31:0] result_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_q <= 1'b0;
            err_q   <= 1'b0;
            result_q <= 32'h0;
        end else begin
            if (valid_in) begin
                valid_q <= 1'b1;
                err_q   <= dot_err;
                result_q <= f32_result;
            end else begin
                valid_q <= 1'b0;
            end
        end
    end

    assign result_out = result_q;
    assign valid_out  = valid_q;
    assign err_out    = err_q;

endmodule
