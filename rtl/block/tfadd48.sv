// ============================================================================
// tfadd48.sv - сумматор двух НОРМАЛИЗОВАННЫХ TFloat48 (обёртка над tfadd_raw)
// ============================================================================
// tfadd_raw складывает НЕНОРМАЛИЗОВАННЫЕ продукты (prod[79:0], e[7:0], neg) —
// формат выходов tfmul_raw внутри дерева compute_dot_par_raw. Для аккумулятора
// long-dot (tdot_axi4) нужно складывать уже нормализованные 48-битные
// TFloat48 — частичные суммы дерева. Здесь выполняется распаковка
// TFloat48 -> (prod, e, neg) (та же конвенция, что в compute_dot_par_raw):
//   prod = {40'h0, m[39:0]}          (мантисса как беззнаковая величина)
//   e    = base-3 декодирование 4 тритов e-поля ([47:40], триты [47:40])
//   neg  = знак старшего НЕнулевого трита мантиссы
// после чего tfadd_raw нормализует сумму обратно в TFloat48.
//
// Латентность = латентность tfadd_raw (несколько тактов); valid_in — импульс,
// входы должны оставаться стабильными до valid_out.
// ============================================================================
module tfadd48 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [47:0] a,        // [47:40]=e (4 трита), [39:0]=m (20 тритов)
    input  logic [47:0] b,
    output logic        valid_out,
    output logic [47:0] result
);

    function automatic logic signed [2:0] trit_val2(input logic [1:0] c);
        case (c)
            2'b01:    trit_val2 = 3'sd1;
            2'b10:    trit_val2 = -3'sd1;
            default:  trit_val2 = 3'sd0;
        endcase
    endfunction

    function automatic logic signed [7:0] unpack_e(input logic [47:0] v);
        logic signed [7:0] tmp;
        tmp = 8'sd0;
        for (int i = 3; i >= 0; i--)
            tmp = tmp * 3 + trit_val2(v[40 + 2*i +: 2]);
        return tmp;
    endfunction

    function automatic logic unpack_neg(input logic [47:0] v);
        unpack_neg = 1'b0;
        for (int t = 19; t >= 0; t--)
            if (v[2*t +: 2] != 2'b00) begin
                unpack_neg = (v[2*t +: 2] == 2'b10);
                break;
            end
    endfunction

    logic [79:0]        a_prod, b_prod;
    logic signed [7:0]  a_e, b_e;
    logic               a_neg, b_neg;

    always_comb begin
        a_prod = {40'h0, a[39:0]};
        b_prod = {40'h0, b[39:0]};
        a_e    = unpack_e(a);
        b_e    = unpack_e(b);
        a_neg  = unpack_neg(a);
        b_neg  = unpack_neg(b);
    end

    tfadd_raw u_add (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .a_prod    (a_prod),
        .a_e       (a_e),
        .a_neg     (a_neg),
        .b_prod    (b_prod),
        .b_e       (b_e),
        .b_neg     (b_neg),
        .valid_out (valid_out),
        .result    (result)
    );

endmodule
