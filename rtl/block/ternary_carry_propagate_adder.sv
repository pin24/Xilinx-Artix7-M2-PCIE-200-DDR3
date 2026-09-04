// ============================================================================
// ternary_carry_propagate_adder.sv — финальный троичный adder
// ============================================================================
// Складывает 2 троичных вектора (sum + carry из Dadda tree) с propagate
// carry от младших разрядов к старшим. Используется как финальный шаг
// после Dadda reduction.
//
// Входы:
//   a_vec [2*W-1:0] — W тритов, упакованы по 2 бита на трит
//   b_vec [2*W-1:0] — W тритов
//
// Выход:
//   result [2*W+1:0] — W тритов + 1 трит overflow (W+1 тритов, 2*(W+1) бит)
// ============================================================================
module ternary_carry_propagate_adder #(
    parameter int W = 40   // ширина в тритах
)(
    input  logic [2*W-1:0]   a_vec,
    input  logic [2*W-1:0]   b_vec,
    output logic [2*(W+1)-1:0] result
);
    localparam logic [1:0] P1 = 2'b01;
    localparam logic [1:0] N1 = 2'b10;
    localparam logic [1:0] T0 = 2'b00;

    function automatic logic signed [1:0] tval(input logic [1:0] c);
        case (c)
            P1: tval = 2'sd1;
            N1: tval = -2'sd1;
            default: tval = 2'sd0;
        endcase
    endfunction

    function automatic logic [1:0] tcode(input logic signed [1:0] v);
        case (v)
            2'sd1:  tcode = P1;
            -2'sd1: tcode = N1;
            default: tcode = T0;
        endcase
    endfunction

    logic signed [1:0] carry [0:W];   // carry в каждый столбец
    logic [1:0] sum [0:W-1];

    always_comb begin
        carry[0] = 2'sd0;
        for (int j = 0; j < W; j++) begin
            logic signed [2:0] total;
            logic signed [2:0] q, r;
            total = tval(a_vec[2*j +: 2]) + tval(b_vec[2*j +: 2]) + carry[j];
            q = total / 3;
            r = total - 3 * q;
            if (r > 1) begin q = q + 1; r = r - 3; end
            else if (r < -1) begin q = q - 1; r = r + 3; end
            sum[j] = tcode(r[1:0]);
            carry[j+1] = q[1:0];
        end
        // Запись результата
        for (int j = 0; j < W; j++) begin
            result[2*j +: 2] = sum[j];
        end
        // Overflow трит (carry после последнего столбца)
        result[2*W +: 2] = tcode(carry[W]);
    end

endmodule
