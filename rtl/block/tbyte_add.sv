// ============================================================================
// tbyte_add.sv - сложение двух байтов (4 трита) + перенос (трит)
// ============================================================================
// Байт: 4 трита, трит i -> биты [2i+1:2i] (i=0 младший), +1->01,0->00,-1->10.
// Складывает поразрядно с переносом (balanced ternary).
// Результат: 4 трита + carry_out (трит).
// Маленький комбинационный конус.
// ============================================================================
module tbyte_add (
    input  logic [7:0] a,      // байт A
    input  logic [7:0] b,      // байт B
    input  logic [1:0] cin,    // перенос на вход (трит: 01/+1, 00/0, 10/-1)
    output logic [7:0] sum,    // 4 трита результата
    output logic [1:0] cout    // перенос наружу
);
    localparam logic [1:0] P1 = 2'b01;
    localparam logic [1:0] Z0 = 2'b00;
    localparam logic [1:0] N1 = 2'b10;

    // значения тритов операндов
    logic [1:0] at [0:3];
    logic [1:0] bt [0:3];
    always_comb begin
        at[0] = a[1:0]; at[1] = a[3:2]; at[2] = a[5:4]; at[3] = a[7:6];
        bt[0] = b[1:0]; bt[1] = b[3:2]; bt[2] = b[5:4]; bt[3] = b[7:6];
    end

    function automatic logic signed [3:0] trit2int(input logic [1:0] c);
        case (c)
            P1: trit2int = 4'sd1;
            N1: trit2int = -4'sd1;
            default: trit2int = 4'sd0;
        endcase
    endfunction

    function automatic logic [1:0] int2trit(input logic signed [3:0] v);
        case (v)
            4'sd1: int2trit = P1;
            -4'sd1: int2trit = N1;
            default: int2trit = Z0;
        endcase
    endfunction

    // сложение трита + трит + перенос -> (сумма, перенос)
    function automatic logic [1:0] add3(
        input logic [1:0] x, y, cinv,
        output logic [1:0] coutv
    );
        logic signed [3:0] s;
        s = trit2int(x) + trit2int(y) + trit2int(cinv);
        if (s > 1) begin coutv = P1; add3 = int2trit(s - 3); end
        else if (s < -1) begin coutv = N1; add3 = int2trit(s + 3); end
        else begin coutv = Z0; add3 = int2trit(s); end
    endfunction

    logic [1:0] carry [0:4];
    always_comb begin
        carry[0] = cin;
        for (int i = 0; i < 4; i++) begin
            sum[2*i +: 2] = add3(at[i], bt[i], carry[i], carry[i+1]);
        end
    end
    assign cout = carry[4];

endmodule
