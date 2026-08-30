// ============================================================================
// tbyte_mul.sv - умножение двух байтов (4 трита x 4 трита) -> 8 тритов
// ============================================================================
// Байт: 4 трита, трит i -> биты [2i+1:2i] (i=0 младший), +1->01,0->00,-1->10.
// Поразрядное умножение: prod[i][j] = a_i * b_j (значение -1,0,1);
//   coeff[k] = sum_{i+j=k} prod[i][j]  (k=0..7, до 4 членов);
//   balanced-сборка: трит[k] = (coeff[k]+перенос) mod 3, перенос наружу.
// Компактный конус (без большого умножителя/разложения).
// ============================================================================
module tbyte_mul (
    input  logic [7:0] a,
    input  logic [7:0] b,
    output logic [15:0] prod    // 8 тритов результата (младший первым)
);
    localparam logic [1:0] P1 = 2'b01;
    localparam logic [1:0] N1 = 2'b10;

    function automatic logic signed [1:0] trit_val(input logic [1:0] c);
        case (c)
            P1: trit_val = 2'sd1;
            N1: trit_val = -2'sd1;
            default: trit_val = 2'sd0;
        endcase
    endfunction

    function automatic logic [1:0] int2trit(input logic signed [2:0] v);
        case (v)
            3'sd1: int2trit = 2'b01;
            -3'sd1: int2trit = 2'b10;
            default: int2trit = 2'b00;
        endcase
    endfunction

    // триты операндов
    logic [1:0] at [0:3];
    logic [1:0] bt [0:3];
    always_comb begin
        at[0] = a[1:0]; at[1] = a[3:2]; at[2] = a[5:4]; at[3] = a[7:6];
        bt[0] = b[1:0]; bt[1] = b[3:2]; bt[2] = b[5:4]; bt[3] = b[7:6];
    end

    // произведения тритов (значение -1,0,1)
    logic signed [2:0] pt [0:3][0:3];
    always_comb begin
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++)
                pt[i][j] = trit_val(at[i]) * trit_val(bt[j]);
    end

    // coeff[k] = sum_{i+j=k} pt[i][j]
    logic signed [3:0] coeff [0:7];
    always_comb begin
        for (int k = 0; k < 8; k++) coeff[k] = 4'sd0;
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++)
                coeff[i+j] = coeff[i+j] + pt[i][j];
    end

    // balanced-сборка: трит[k] = (coeff[k]+carry[k]) mod 3, перенос может быть до 2
    logic signed [4:0] carry [0:8];
    logic signed [5:0] s_show [0:7];
    logic signed [5:0] q_show [0:7];
    logic signed [2:0] r_show [0:7];
    always_comb begin
        carry[0] = 5'sd0;
        for (int k = 0; k < 8; k++) begin
            logic signed [5:0] s;
            logic signed [5:0] q;
            logic signed [2:0] r;
            s = coeff[k] + carry[k];
            s_show[k] = s;
            q = s / 3;                  // к нулю
            r = s - 3 * q;              // остаток {-2,-1,0,1,2}
            q_show[k] = q;
            r_show[k] = r;
            if (r == 2) begin
                r = -1; q = q + 1;
            end else if (r == -2) begin
                r = 1; q = q - 1;
            end
            prod[2*k +: 2] = int2trit(r);
            carry[k+1] = q;
        end
    end

endmodule
