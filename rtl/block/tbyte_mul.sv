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

    // Pure-LUT: трит-произведение; 16 ключей (2'b11 → 0, как trit_val).
    function automatic logic signed [1:0] ptv(input logic [1:0] x, input logic [1:0] y);
        case ({x, y})
            4'h0: return 2'sd0;
            4'h1: return 2'sd0;
            4'h2: return 2'sd0;
            4'h3: return 2'sd0;
            4'h4: return 2'sd0;
            4'h5: return 2'sd1;
            4'h6: return -2'sd1;
            4'h7: return 2'sd0;
            4'h8: return 2'sd0;
            4'h9: return -2'sd1;
            4'hA: return 2'sd1;
            4'hB: return 2'sd0;
            4'hC: return 2'sd0;
            4'hD: return 2'sd0;
            4'hE: return 2'sd0;
            4'hF: return 2'sd0;
            default: return 2'sd0;
        endcase
    endfunction
    // Pure-LUT balanced-сборка: s=coeff+carry ∈ [-6,6]; ключ {coeff[3:0], carry[2:0]}
    // → {r_enc[1:0], q[2:0]} (q — перенос). 45/45 валидных ключей == формуле (P5).
    function automatic logic [4:0] asm_tab(input logic [6:0] key);
        case (key)
            7'h00: return 5'h00;
            7'h01: return 5'h08;
            7'h02: return 5'h11;
            7'h06: return 5'h0F;
            7'h07: return 5'h10;
            7'h08: return 5'h08;
            7'h09: return 5'h11;
            7'h0A: return 5'h01;
            7'h0E: return 5'h10;
            7'h0F: return 5'h00;
            7'h10: return 5'h11;
            7'h11: return 5'h01;
            7'h12: return 5'h09;
            7'h16: return 5'h00;
            7'h17: return 5'h08;
            7'h18: return 5'h01;
            7'h19: return 5'h09;
            7'h1A: return 5'h12;
            7'h1E: return 5'h08;
            7'h1F: return 5'h11;
            7'h20: return 5'h09;
            7'h21: return 5'h12;
            7'h22: return 5'h02;
            7'h26: return 5'h11;
            7'h27: return 5'h01;
            7'h60: return 5'h17;
            7'h61: return 5'h07;
            7'h62: return 5'h0F;
            7'h66: return 5'h06;
            7'h67: return 5'h0E;
            7'h68: return 5'h07;
            7'h69: return 5'h0F;
            7'h6A: return 5'h10;
            7'h6E: return 5'h0E;
            7'h6F: return 5'h17;
            7'h70: return 5'h0F;
            7'h71: return 5'h10;
            7'h72: return 5'h00;
            7'h76: return 5'h17;
            7'h77: return 5'h07;
            7'h78: return 5'h10;
            7'h79: return 5'h00;
            7'h7A: return 5'h08;
            7'h7E: return 5'h07;
            7'h7F: return 5'h0F;
            default: return 5'h00;
        endcase
    endfunction

    // триты операндов
    logic [1:0] at [0:3];
    logic [1:0] bt [0:3];
    always_comb begin
        at[0] = a[1:0]; at[1] = a[3:2]; at[2] = a[5:4]; at[3] = a[7:6];
        bt[0] = b[1:0]; bt[1] = b[3:2]; bt[2] = b[5:4]; bt[3] = b[7:6];
    end

    // произведения тритов (значение -1,0,1) — таблица ptv (0 CARRY4)
    logic signed [1:0] pt [0:3][0:3];
    always_comb begin
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++)
                pt[i][j] = ptv(at[i], bt[j]);
    end

    // coeff[k] = sum_{i+j=k} pt[i][j]
    logic signed [3:0] coeff [0:7];
    always_comb begin
        for (int k = 0; k < 8; k++) coeff[k] = 4'sd0;
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++)
                coeff[i+j] = coeff[i+j] + pt[i][j];
    end

    // balanced-сборка: Pure-LUT asm_tab (0 CARRY4); перенос цепочкой case-таблиц
    logic signed [2:0] carry [0:8];
    logic [6:0] akey;
    logic [4:0] ares;
    always_comb begin
        carry[0] = 3'sd0;
        for (int k = 0; k < 8; k++) begin
            akey = {coeff[k], carry[k]};
            ares = asm_tab(akey);
            prod[2*k +: 2] = ares[4:3];
            carry[k+1] = $signed(ares[2:0]);
        end
    end

endmodule
