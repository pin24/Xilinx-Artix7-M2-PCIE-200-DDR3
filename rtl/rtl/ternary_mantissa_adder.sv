// ============================================================================
// ternary_mantissa_adder.sv - поразрядный сумматор мантисс в balanced ternary
// ============================================================================
// Складывает две целые мантиссы (по N тритов) поразрядно с переносом.
// Каждый трит: +1->01, 0->00, -1->10. Перенос: 0=00, +1=01, -1=10.
// Симметрия: вычитание = сложение с инвертированными тритами B (b_neg=1).
// ============================================================================

module ternary_mantissa_adder #(
    parameter int N = 15   // число тритов мантиссы
)(
    input  logic [N*2-1:0] a,       // операнд A (2 бита на трит, старший первым)
    input  logic [N*2-1:0] b,       // операнд B
    input  logic           b_neg,   // 1 = вычесть (инвертировать B)
    output logic [N*2-1:0] sum,     // результат
    output logic [1:0]     carry_out // перенос наружу
);

    // локальные коды тритов
    localparam logic [1:0] P1  = 2'b01;
    localparam logic [1:0] Z0  = 2'b00;
    localparam logic [1:0] N1  = 2'b10;

    logic [1:0] carry;      // внутренний перенос (текущий)
    logic [1:0] a_t, b_t;   // триты операндов
    logic [1:0] b_inv;      // инвертированный трит B

    // перенос наружу
    assign carry_out = carry;

    always_comb begin
        carry = Z0;
        for (int i = N-1; i >= 0; i--) begin
            a_t = a[i*2 +: 2];
            b_t = b[i*2 +: 2];
            // инверсия знака B: P1<->N1, Z0->Z0
            case (b_t)
                P1: b_inv = N1;
                N1: b_inv = P1;
                default: b_inv = Z0;
            endcase
            if (b_neg) b_t = b_inv;
            sum[i*2 +: 2] = ternary_add3(a_t, b_t, carry, carry);
        end
    end

    // функция: сложение трёх тритов -> (сумма, перенос)
    function automatic logic [1:0] ternary_add3(
        input logic [1:0] x, y, cin,
        output logic [1:0] cout
    );
        // числовое значение суммы
        int s;
        s = trit2int(x) + trit2int(y) + trit2int(cin);
        if (s > 1) begin
            cout = P1;
            ternary_add3 = int2trit(s - 3);
        end else if (s < -1) begin
            cout = N1;
            ternary_add3 = int2trit(s + 3);
        end else begin
            cout = Z0;
            ternary_add3 = int2trit(s);
        end
    endfunction

    function automatic int trit2int(input logic [1:0] t);
        case (t)
            P1: trit2int = 1;
            N1: trit2int = -1;
            default: trit2int = 0;
        endcase
    endfunction

    function automatic logic [1:0] int2trit(input int v);
        case (v)
            1: int2trit = P1;
            -1: int2trit = N1;
            default: int2trit = Z0;
        endcase
    endfunction

endmodule
