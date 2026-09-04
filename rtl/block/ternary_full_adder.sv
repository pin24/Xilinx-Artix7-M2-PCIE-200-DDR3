// ============================================================================
// ternary_full_adder.sv — троичный полный сумматор (Ternary Full Adder, TFA)
// ============================================================================
// Складывает 3 трита a, b, c_in ∈ {-1, 0, +1}, выдаёт sum ∈ {-1, 0, +1}
// и carry ∈ {-1, 0, +1}. В троичной симметричной системе:
//   sum = (a + b + c) mod 3   (balanced: -1, 0, +1)
//   carry = (a + b + c - sum) / 3   ∈ {-1, 0, +1}
//
// Диапазон входов: a+b+c ∈ [-3, +3]
//   -3 → sum = 0,  carry = -1
//   -2 → sum = +1, carry = -1
//   -1 → sum = -1, carry = 0
//    0 → sum = 0,  carry = 0
//   +1 → sum = +1, carry = 0
//   +2 → sum = -1, carry = +1
//   +3 → sum = 0,  carry = +1
//
// Кодирование тритов: +1→01, 0→00, -1→10 (2 бита на трит)
// ============================================================================
module ternary_full_adder (
    input  logic [1:0] a,        // трит {-1, 0, +1} как 2'b10, 2'b00, 2'b01
    input  logic [1:0] b,
    input  logic [1:0] c_in,
    output logic [1:0] sum,      // трит результата
    output logic [1:0] carry      // трит переноса
);
    localparam logic [1:0] P1 = 2'b01;
    localparam logic [1:0] N1 = 2'b10;
    localparam logic [1:0] T0 = 2'b00;

    // Декодер: трит → signed value
    function automatic logic signed [1:0] tval(input logic [1:0] c);
        case (c)
            P1: tval = 2'sd1;
            N1: tval = -2'sd1;
            default: tval = 2'sd0;
        endcase
    endfunction

    // Кодер: signed value → трит
    function automatic logic [1:0] tcode(input logic signed [1:0] v);
        case (v)
            2'sd1:  tcode = P1;
            -2'sd1: tcode = N1;
            default: tcode = T0;
        endcase
    endfunction

    logic signed [2:0] s;  // a + b + c_in, диапазон [-3, +3]
    logic signed [2:0] q;  // quotient = s / 3 (rounding to zero)
    logic signed [2:0] r;  // remainder = s - 3*q

    always_comb begin
        s = tval(a) + tval(b) + tval(c_in);

        // Деление на 3 с округлением к нулю (balanced ternary)
        // Стандартное: q = s / 3 (в SystemVerilog — к нулю для signed)
        q = s / 3;
        r = s - 3 * q;

        // Balanced ternary требует остаток ∈ {-1, 0, +1}
        // В SV s/3 для -2/-1 возвращает 0 (rounding to zero), но нам нужно:
        //   -2 = -1*3 + 1 → sum=+1, carry=-1   (а не sum=-2, carry=0)
        //   +2 = +1*3 - 1 → sum=-1, carry=+1
        // Это уже реализовано через q=s/3 + r=s-3q, но для -2/+2:
        //   -2/3 = 0, r=-2 → нужно скорректировать: q=-1, r=+1
        //   +2/3 = 0, r=+2 → q=+1, r=-1
        if (r > 1) begin
            q = q + 1;
            r = r - 3;
        end else if (r < -1) begin
            q = q - 1;
            r = r + 3;
        end

        sum   = tcode(r[1:0]);
        carry = tcode(q[1:0]);
    end

endmodule
