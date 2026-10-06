// ============================================================================
// tbyte_mul.sv - умножение двух байтов (4 трита x 4 трита) -> 8 тритов
// ============================================================================
// Байт: 4 трита, трит i -> биты [2i+1:2i] (i=0 младший), +1->01,0->00,-1->10.
// Поразрядное умножение: prod[i][j] = a_i * b_j (значение -1,0,1);
//   coeff[k] = sum_{i+j=k} prod[i][j]  (k=0..7, до 4 членов);
//   balanced-сборка: трит[k] = (coeff[k]+перенос) mod 3, перенос наружу.
// Компактный конус (без большого умножителя/разложения).
//
// PIPE=0 (по умолчанию): чисто комбинаторный LUT-путь (поведение не изменилось;
//   клк/сброс/ен не используются). Инстансы без #(.PIPE(1)) работают как раньше.
// PIPE=1: двухкаскадный конвейер — каскад k=0..3 комбинаторно -> граничный
//   регистр (carry[4], coeff[4..7], prod_lo) -> каскад k=4..7 -> prod. Срезает
//   последовательную 8-этапную carry-цепь пополам (~19 -> ~9 уровней логики),
//   a,b->prod = 1 такт. Регистр обнуляется при en=0. Математика PIPE=0
//   (ptv/asm_tab/coeff) НЕ тронута — идентичен по результату с PIPE=1-путём.
// ============================================================================
module tbyte_mul #(
    parameter int PIPE = 0
)(
    input  logic [7:0] a,
    input  logic [7:0] b,
    input  logic        clk   = 1'b0,
    input  logic        rst_n = 1'b1,
    input  logic        en    = 1'b1,
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

    // ---- первый каскад: k=0..3 (общий для PIPE 0 и 1) ----
    // Глубина: 2 LUT (ptv->pt) + суммирование coeff + 4 asm_tab = ~9 уровней.
    logic signed [2:0] carry [0:4];
    logic [6:0] akey0;
    logic [4:0] ares0;
    logic [7:0] prod_lo;           // триты k=0..3 (до регистра границы)
    always_comb begin
        carry[0] = 3'sd0;
        for (int k = 0; k < 4; k++) begin
            akey0 = {coeff[k], carry[k]};
            ares0 = asm_tab(akey0);
            prod_lo[2*k +: 2] = ares0[4:3];
            carry[k+1] = $signed(ares0[2:0]);
        end
    end

    generate
        if (PIPE == 1) begin : g_pipe
            // ---- двухкаскадный конвейер (LUT): граничный регистр ----
            // Каскад k=0..3 (выше) комбинаторно даёт prod_lo/carry[4]/coeff[4..7],
            // которые фиксируются в граничный регистр; второй каскад k=4..7 читает
            // их из регистра => последовательная 8-этапная carry-цепь разрезана
            // пополам (~19 -> ~9 уровней). Регистр обнуляется при en=0.
            logic signed [2:0] carry4_q;
            logic [15:0] coeff_hi_q;   // coeff[4..7] по 4 бита (для второго каскада)
            logic [7:0] prod_lo_q;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin carry4_q <= 3'sd0; coeff_hi_q <= 16'h0; prod_lo_q <= 8'h0; end
                else if (en) begin
                    carry4_q   <= carry[4];
                    coeff_hi_q <= {coeff[7], coeff[6], coeff[5], coeff[4]};
                    prod_lo_q  <= prod_lo;
                end else begin
                    carry4_q   <= 3'sd0; coeff_hi_q <= 16'h0; prod_lo_q <= 8'h0;
                end
            end
            // второй каскад (k=4..7) от зарегистрированных значений
            logic signed [2:0] carry2 [4:8];
            logic [6:0] akey2;
            logic [4:0] ares2;
            logic [7:0] prod_hi;
            always_comb begin
                carry2[4] = carry4_q;
                for (int k = 4; k < 8; k++) begin
                    akey2 = {coeff_hi_q[4*(k-4) +: 4], carry2[k]};
                    ares2 = asm_tab(akey2);
                    prod_hi[2*(k-4) +: 2] = ares2[4:3];
                    carry2[k+1] = $signed(ares2[2:0]);
                end
            end
            assign prod = {prod_hi, prod_lo_q};
        end else begin : g_cmb
            // второй каскад (комбинаторный): k=4..7 от carry[4] (как завсегда)
            logic signed [2:0] carry2 [4:8];
            logic [6:0] akey2;
            logic [4:0] ares2;
            logic [7:0] prod_hi2;         // триты k=4..7
            always_comb begin
                carry2[4] = carry[4];
                for (int k = 4; k < 8; k++) begin
                    akey2 = {coeff[k], carry2[k]};
                    ares2 = asm_tab(akey2);
                    prod_hi2[2*(k-4) +: 2] = ares2[4:3];
                    carry2[k+1] = $signed(ares2[2:0]);
                end
            end
            assign prod = {prod_hi2, prod_lo};
        end
    endgenerate

endmodule