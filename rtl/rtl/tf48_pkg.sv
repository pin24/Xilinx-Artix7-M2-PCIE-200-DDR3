// ============================================================================
// tf48_pkg.sv - параметры формата TFloat48 (конвенция ядра [E:8][M:40])
// ============================================================================
// Формат (согласован с ternary_sw/block/tfloat48.py и fpga_backend._to_bits48):
//   value = M * 3^(e - 18)
//     M : целая мантисса, 20 тритов = 40 бит (норм. [3^18, 3^19))
//     e : экспонента,      4 трита =  8 бит (ПРЯМОЙ balanced-код e, БЕЗ bias)
//   e in [-40, +40].
// Кодирование трита: +1->01, 0->00, -1->10, 11->ERR.
//
// БИТОВЫЙ РАСКЛАД СЛОВА (ядро/файл/память, НЕ Python to_bits!):
//   [47:40] = экспонента e (4 трита, старший трит в [47:46])
//   [39:0]  = мантисса M (20 тритов, старший трит в [39:38])
//
// Это конвенция fpga_backend._to_bits48 = ((e_int&0xFF)<<40)|(m_int&(2^40-1)),
// и совпадает с декодированием в ядре (tfadd48.sv, compute_dot_par_raw).
// ============================================================================

package tf48_pkg;

    localparam int M_TRITS = 20;
    localparam int E_TRITS = 4;
    localparam int TOTAL_TRITS = M_TRITS + E_TRITS; // 24
    localparam int TOTAL_BITS = TOTAL_TRITS * 2;    // 48
    localparam int E_BIAS     = 40;

    localparam int M_BITS = M_TRITS * 2;            // 40
    localparam int E_BITS = E_TRITS * 2;            // 8

    // границы нормализованной мантиссы (в целочисленной метрике)
    localparam bit [63:0] M_NORM_MIN = 64'd387420489;   // 3^18
    localparam bit [63:0] M_NORM_MAX = 64'd1162261467;  // 3^19

    // --- кодирование трита (2 бита) ---
    localparam logic [1:0] TRIT_P1  = 2'b01;
    localparam logic [1:0] TRIT_0   = 2'b00;
    localparam logic [1:0] TRIT_N1  = 2'b10;
    localparam logic [1:0] TRIT_ERR = 2'b11;

    // --- функции ---
    function automatic logic [1:0] trit_code_of(input signed [1:0] t);
        case (t)
            2'sd1:  trit_code_of = TRIT_P1;
            -2'sd1: trit_code_of = TRIT_N1;
            default: trit_code_of = TRIT_0;
        endcase
    endfunction

    // значение трита из 2-битного кода (+1/0/-1; ERR-код даёт 0)
    function automatic signed [1:0] trit_val(input logic [1:0] code);
        case (code)
            TRIT_P1:  trit_val = 2'sd1;
            TRIT_N1:  trit_val = -2'sd1;
            default:  trit_val = 2'sd0;
        endcase
    endfunction

    // округление-round-half-up целочисленного деления N/D (D>0, беззнак.)
    function automatic bit [255:0] div_round_half_up(input bit [255:0] N,
                                                     input bit [255:0] D);
        bit [256:0] num, den;
        num = (N << 1) + D;
        den = (D << 1);
        div_round_half_up = num[255:0] / den[255:0];
    endfunction

endpackage