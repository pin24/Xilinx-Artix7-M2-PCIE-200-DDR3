// ============================================================================
// tfloat_pkg.sv - параметры формата TFloat40
// ============================================================================
// Формат: value = M * 3^(E - 60 - 13)
//   M : целая мантисса, M_TRITS тритов (норм. [3^13, 3^14))
//   E : экспонента, E_TRITS тритов (bias 60, balanced ternary)
// Кодирование трита: +1->01, 0->00, -1->10, 11->ERR
// ============================================================================

package tfloat_pkg;

    // --- параметры формата ---
    localparam int M_TRITS = 15;
    localparam int E_TRITS = 5;
    localparam int TOTAL_TRITS = M_TRITS + E_TRITS; // 20
    localparam int TOTAL_BITS = TOTAL_TRITS * 2;    // 40
    localparam int E_BIAS     = 60;

    // --- кодирование трита (2 бита) ---
    localparam logic [1:0] TRIT_P1  = 2'b01;
    localparam logic [1:0] TRIT_0   = 2'b00;
    localparam logic [1:0] TRIT_N1  = 2'b10;
    localparam logic [1:0] TRIT_ERR = 2'b11;

    // --- позиции полей в 40-битном слове ---
    localparam int M_BITS = M_TRITS * 2;   // 30
    localparam int E_BITS = E_TRITS * 2;   // 10
    localparam int E_LSB  = 0;
    localparam int M_LSB  = E_BITS;        // 10

    // --- функции ---
    // трит из 2-битного кода: 0->0, 1->1, 2->-1, 3->0(ERR как 0)
    function automatic signed [1:0] trit_val(input logic [1:0] code);
        case (code)
            TRIT_P1:  trit_val = 2'sd1;
            TRIT_N1:  trit_val = -2'sd1;
            default:  trit_val = 2'sd0;
        endcase
    endfunction

    // признак ошибочного трита
    function automatic logic is_err(input logic [1:0] code);
        is_err = (code == TRIT_ERR);
    endfunction

    // код из трита (-1,0,1)
    function automatic logic [1:0] trit_code(input signed [1:0] t);
        case (t)
            2'sd1:   trit_code = TRIT_P1;
            -2'sd1:  trit_code = TRIT_N1;
            default: trit_code = TRIT_0;
        endcase
    endfunction

endpackage
