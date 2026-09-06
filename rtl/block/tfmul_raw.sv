// ============================================================================
// tfmul_raw.sv — параллельный умножитель TFloat48 (carry-save pipeline)
// ============================================================================
// Аккумуляция partial product через carry-save: per-column parallel,
// carry_next[t] идёт в carry_r[t] на следующем такте (1 такт, не цепочка).
// Pure-LUT (BUG-037 CARRY4 fix): колонка = 1 LUT6/бит (таблица csr3), 0 CARRY4.
// cnt/5,%5,+ → cnt_dec; окно shift → pa=partial<<8s; exp_val → таблица 256.
// Доказано бит-в-бит: scripts/tfmul_purelut_gen.py (P1–P8).
// Финальная сборка: sum_r + carry_r, 2 трита/такт, 20 тактов.
// ============================================================================
module tfmul_raw (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [47:0] a,
    input  logic [47:0] b,
    output logic        valid_out,
    output logic [79:0] prod,
    output logic [7:0]  e,
    output logic        neg
);
    localparam logic [1:0] P1 = 2'b01, N1 = 2'b10;

    function logic [3:0] csr3(input logic [5:0] key);
        // Pure-LUT (BUG-037 CARRY4 fix): ключ {a,b,c} — кодировки тритов (2'b11 → tv=0),
        // значение {q_enc, r_enc}: s=a+b+c ∈ [-3,3], q=trunc(s/3) — перенос, r — цифра.
        // 64/64 ключа исчерпывающе == исходной формуле (P1, scripts/tfmul_purelut_gen.py).
        case (key)
            6'h00: return 4'h0;
            6'h01: return 4'h1;
            6'h02: return 4'h2;
            6'h03: return 4'h0;
            6'h04: return 4'h1;
            6'h05: return 4'h6;
            6'h06: return 4'h0;
            6'h07: return 4'h1;
            6'h08: return 4'h2;
            6'h09: return 4'h0;
            6'h0A: return 4'h9;
            6'h0B: return 4'h2;
            6'h0C: return 4'h0;
            6'h0D: return 4'h1;
            6'h0E: return 4'h2;
            6'h0F: return 4'h0;
            6'h10: return 4'h1;
            6'h11: return 4'h6;
            6'h12: return 4'h0;
            6'h13: return 4'h1;
            6'h14: return 4'h6;
            6'h15: return 4'h4;
            6'h16: return 4'h1;
            6'h17: return 4'h6;
            6'h18: return 4'h0;
            6'h19: return 4'h1;
            6'h1A: return 4'h2;
            6'h1B: return 4'h0;
            6'h1C: return 4'h1;
            6'h1D: return 4'h6;
            6'h1E: return 4'h0;
            6'h1F: return 4'h1;
            6'h20: return 4'h2;
            6'h21: return 4'h0;
            6'h22: return 4'h9;
            6'h23: return 4'h2;
            6'h24: return 4'h0;
            6'h25: return 4'h1;
            6'h26: return 4'h2;
            6'h27: return 4'h0;
            6'h28: return 4'h9;
            6'h29: return 4'h2;
            6'h2A: return 4'h8;
            6'h2B: return 4'h9;
            6'h2C: return 4'h2;
            6'h2D: return 4'h0;
            6'h2E: return 4'h9;
            6'h2F: return 4'h2;
            6'h30: return 4'h0;
            6'h31: return 4'h1;
            6'h32: return 4'h2;
            6'h33: return 4'h0;
            6'h34: return 4'h1;
            6'h35: return 4'h6;
            6'h36: return 4'h0;
            6'h37: return 4'h1;
            6'h38: return 4'h2;
            6'h39: return 4'h0;
            6'h3A: return 4'h9;
            6'h3B: return 4'h2;
            6'h3C: return 4'h0;
            6'h3D: return 4'h1;
            6'h3E: return 4'h2;
            6'h3F: return 4'h0;
            default: return 4'h0;
        endcase
    endfunction
    // значение {-1,0,1} ↔ кодировка трита (pure case, 0 CARRY4)
    function logic [1:0] v2t(input logic signed [2:0] v);
        case (v) -3'sd1: return 2'b10; 3'sd1: return 2'b01; default: return 2'b00; endcase
    endfunction
    function logic signed [2:0] t2v(input logic [1:0] c);
        case (c) 2'b01: return 3'sd1; 2'b10: return -3'sd1; default: return 3'sd0; endcase
    endfunction
    // Pure-LUT: exp(x) = Σ tv(pair_i)·3^i; ВСЕ 256 ключей (2'b11 → tv=0, как tv()).
    function logic signed [7:0] exp_val(input logic [7:0] x);
        case (x)
            8'h00: return 8'sd0;
            8'h01: return 8'sd1;
            8'h02: return -8'sd1;
            8'h03: return 8'sd0;
            8'h04: return 8'sd3;
            8'h05: return 8'sd4;
            8'h06: return 8'sd2;
            8'h07: return 8'sd3;
            8'h08: return -8'sd3;
            8'h09: return -8'sd2;
            8'h0A: return -8'sd4;
            8'h0B: return -8'sd3;
            8'h0C: return 8'sd0;
            8'h0D: return 8'sd1;
            8'h0E: return -8'sd1;
            8'h0F: return 8'sd0;
            8'h10: return 8'sd9;
            8'h11: return 8'sd10;
            8'h12: return 8'sd8;
            8'h13: return 8'sd9;
            8'h14: return 8'sd12;
            8'h15: return 8'sd13;
            8'h16: return 8'sd11;
            8'h17: return 8'sd12;
            8'h18: return 8'sd6;
            8'h19: return 8'sd7;
            8'h1A: return 8'sd5;
            8'h1B: return 8'sd6;
            8'h1C: return 8'sd9;
            8'h1D: return 8'sd10;
            8'h1E: return 8'sd8;
            8'h1F: return 8'sd9;
            8'h20: return -8'sd9;
            8'h21: return -8'sd8;
            8'h22: return -8'sd10;
            8'h23: return -8'sd9;
            8'h24: return -8'sd6;
            8'h25: return -8'sd5;
            8'h26: return -8'sd7;
            8'h27: return -8'sd6;
            8'h28: return -8'sd12;
            8'h29: return -8'sd11;
            8'h2A: return -8'sd13;
            8'h2B: return -8'sd12;
            8'h2C: return -8'sd9;
            8'h2D: return -8'sd8;
            8'h2E: return -8'sd10;
            8'h2F: return -8'sd9;
            8'h30: return 8'sd0;
            8'h31: return 8'sd1;
            8'h32: return -8'sd1;
            8'h33: return 8'sd0;
            8'h34: return 8'sd3;
            8'h35: return 8'sd4;
            8'h36: return 8'sd2;
            8'h37: return 8'sd3;
            8'h38: return -8'sd3;
            8'h39: return -8'sd2;
            8'h3A: return -8'sd4;
            8'h3B: return -8'sd3;
            8'h3C: return 8'sd0;
            8'h3D: return 8'sd1;
            8'h3E: return -8'sd1;
            8'h3F: return 8'sd0;
            8'h40: return 8'sd27;
            8'h41: return 8'sd28;
            8'h42: return 8'sd26;
            8'h43: return 8'sd27;
            8'h44: return 8'sd30;
            8'h45: return 8'sd31;
            8'h46: return 8'sd29;
            8'h47: return 8'sd30;
            8'h48: return 8'sd24;
            8'h49: return 8'sd25;
            8'h4A: return 8'sd23;
            8'h4B: return 8'sd24;
            8'h4C: return 8'sd27;
            8'h4D: return 8'sd28;
            8'h4E: return 8'sd26;
            8'h4F: return 8'sd27;
            8'h50: return 8'sd36;
            8'h51: return 8'sd37;
            8'h52: return 8'sd35;
            8'h53: return 8'sd36;
            8'h54: return 8'sd39;
            8'h55: return 8'sd40;
            8'h56: return 8'sd38;
            8'h57: return 8'sd39;
            8'h58: return 8'sd33;
            8'h59: return 8'sd34;
            8'h5A: return 8'sd32;
            8'h5B: return 8'sd33;
            8'h5C: return 8'sd36;
            8'h5D: return 8'sd37;
            8'h5E: return 8'sd35;
            8'h5F: return 8'sd36;
            8'h60: return 8'sd18;
            8'h61: return 8'sd19;
            8'h62: return 8'sd17;
            8'h63: return 8'sd18;
            8'h64: return 8'sd21;
            8'h65: return 8'sd22;
            8'h66: return 8'sd20;
            8'h67: return 8'sd21;
            8'h68: return 8'sd15;
            8'h69: return 8'sd16;
            8'h6A: return 8'sd14;
            8'h6B: return 8'sd15;
            8'h6C: return 8'sd18;
            8'h6D: return 8'sd19;
            8'h6E: return 8'sd17;
            8'h6F: return 8'sd18;
            8'h70: return 8'sd27;
            8'h71: return 8'sd28;
            8'h72: return 8'sd26;
            8'h73: return 8'sd27;
            8'h74: return 8'sd30;
            8'h75: return 8'sd31;
            8'h76: return 8'sd29;
            8'h77: return 8'sd30;
            8'h78: return 8'sd24;
            8'h79: return 8'sd25;
            8'h7A: return 8'sd23;
            8'h7B: return 8'sd24;
            8'h7C: return 8'sd27;
            8'h7D: return 8'sd28;
            8'h7E: return 8'sd26;
            8'h7F: return 8'sd27;
            8'h80: return -8'sd27;
            8'h81: return -8'sd26;
            8'h82: return -8'sd28;
            8'h83: return -8'sd27;
            8'h84: return -8'sd24;
            8'h85: return -8'sd23;
            8'h86: return -8'sd25;
            8'h87: return -8'sd24;
            8'h88: return -8'sd30;
            8'h89: return -8'sd29;
            8'h8A: return -8'sd31;
            8'h8B: return -8'sd30;
            8'h8C: return -8'sd27;
            8'h8D: return -8'sd26;
            8'h8E: return -8'sd28;
            8'h8F: return -8'sd27;
            8'h90: return -8'sd18;
            8'h91: return -8'sd17;
            8'h92: return -8'sd19;
            8'h93: return -8'sd18;
            8'h94: return -8'sd15;
            8'h95: return -8'sd14;
            8'h96: return -8'sd16;
            8'h97: return -8'sd15;
            8'h98: return -8'sd21;
            8'h99: return -8'sd20;
            8'h9A: return -8'sd22;
            8'h9B: return -8'sd21;
            8'h9C: return -8'sd18;
            8'h9D: return -8'sd17;
            8'h9E: return -8'sd19;
            8'h9F: return -8'sd18;
            8'hA0: return -8'sd36;
            8'hA1: return -8'sd35;
            8'hA2: return -8'sd37;
            8'hA3: return -8'sd36;
            8'hA4: return -8'sd33;
            8'hA5: return -8'sd32;
            8'hA6: return -8'sd34;
            8'hA7: return -8'sd33;
            8'hA8: return -8'sd39;
            8'hA9: return -8'sd38;
            8'hAA: return -8'sd40;
            8'hAB: return -8'sd39;
            8'hAC: return -8'sd36;
            8'hAD: return -8'sd35;
            8'hAE: return -8'sd37;
            8'hAF: return -8'sd36;
            8'hB0: return -8'sd27;
            8'hB1: return -8'sd26;
            8'hB2: return -8'sd28;
            8'hB3: return -8'sd27;
            8'hB4: return -8'sd24;
            8'hB5: return -8'sd23;
            8'hB6: return -8'sd25;
            8'hB7: return -8'sd24;
            8'hB8: return -8'sd30;
            8'hB9: return -8'sd29;
            8'hBA: return -8'sd31;
            8'hBB: return -8'sd30;
            8'hBC: return -8'sd27;
            8'hBD: return -8'sd26;
            8'hBE: return -8'sd28;
            8'hBF: return -8'sd27;
            8'hC0: return 8'sd0;
            8'hC1: return 8'sd1;
            8'hC2: return -8'sd1;
            8'hC3: return 8'sd0;
            8'hC4: return 8'sd3;
            8'hC5: return 8'sd4;
            8'hC6: return 8'sd2;
            8'hC7: return 8'sd3;
            8'hC8: return -8'sd3;
            8'hC9: return -8'sd2;
            8'hCA: return -8'sd4;
            8'hCB: return -8'sd3;
            8'hCC: return 8'sd0;
            8'hCD: return 8'sd1;
            8'hCE: return -8'sd1;
            8'hCF: return 8'sd0;
            8'hD0: return 8'sd9;
            8'hD1: return 8'sd10;
            8'hD2: return 8'sd8;
            8'hD3: return 8'sd9;
            8'hD4: return 8'sd12;
            8'hD5: return 8'sd13;
            8'hD6: return 8'sd11;
            8'hD7: return 8'sd12;
            8'hD8: return 8'sd6;
            8'hD9: return 8'sd7;
            8'hDA: return 8'sd5;
            8'hDB: return 8'sd6;
            8'hDC: return 8'sd9;
            8'hDD: return 8'sd10;
            8'hDE: return 8'sd8;
            8'hDF: return 8'sd9;
            8'hE0: return -8'sd9;
            8'hE1: return -8'sd8;
            8'hE2: return -8'sd10;
            8'hE3: return -8'sd9;
            8'hE4: return -8'sd6;
            8'hE5: return -8'sd5;
            8'hE6: return -8'sd7;
            8'hE7: return -8'sd6;
            8'hE8: return -8'sd12;
            8'hE9: return -8'sd11;
            8'hEA: return -8'sd13;
            8'hEB: return -8'sd12;
            8'hEC: return -8'sd9;
            8'hED: return -8'sd8;
            8'hEE: return -8'sd10;
            8'hEF: return -8'sd9;
            8'hF0: return 8'sd0;
            8'hF1: return 8'sd1;
            8'hF2: return -8'sd1;
            8'hF3: return 8'sd0;
            8'hF4: return 8'sd3;
            8'hF5: return 8'sd4;
            8'hF6: return 8'sd2;
            8'hF7: return 8'sd3;
            8'hF8: return -8'sd3;
            8'hF9: return -8'sd2;
            8'hFA: return -8'sd4;
            8'hFB: return -8'sd3;
            8'hFC: return 8'sd0;
            8'hFD: return 8'sd1;
            8'hFE: return -8'sd1;
            8'hFF: return 8'sd0;
        endcase
    endfunction

    localparam int PH_IDLE = 0, PH_INIT = 1, PH_MUL = 2, PH_FIN = 3, PH_DONE = 4;
    logic [2:0] phase;
    logic [5:0] cnt, fcnt;
    logic [79:0] sum_r, carry_r, fin_r;
    logic signed [2:0] fin_carry;
    logic [1:0] last_trit;
    logic signed [7:0] e_r;
    logic [39:0] a_mr, b_mr;
    logic [7:0] a_er, b_er;
    logic [15:0] partial_q;
    logic [3:0] s_q;               // сдвиг partial в единицах 4 трита (бывш. shift_q[6:0])

    logic [7:0] am_b[0:4], bm_b[0:4];
    always_comb begin
        for (int i = 0; i < 5; i++) begin am_b[i] = a_mr[8*i+:8]; bm_b[i] = b_mr[8*i+:8]; end
    end
    // Pure-LUT: cnt(0..25) → {mul_s[3:0], mul_i[2:0], mul_j[2:0]} — убирает /5, %5 и +.
    function logic [9:0] cnt_dec(input logic [5:0] cnt);
        case (cnt)
            6'd0: return 10'h000;
            6'd1: return 10'h041;
            6'd2: return 10'h082;
            6'd3: return 10'h0C3;
            6'd4: return 10'h104;
            6'd5: return 10'h048;
            6'd6: return 10'h089;
            6'd7: return 10'h0CA;
            6'd8: return 10'h10B;
            6'd9: return 10'h14C;
            6'd10: return 10'h090;
            6'd11: return 10'h0D1;
            6'd12: return 10'h112;
            6'd13: return 10'h153;
            6'd14: return 10'h194;
            6'd15: return 10'h0D8;
            6'd16: return 10'h119;
            6'd17: return 10'h15A;
            6'd18: return 10'h19B;
            6'd19: return 10'h1DC;
            6'd20: return 10'h120;
            6'd21: return 10'h161;
            6'd22: return 10'h1A2;
            6'd23: return 10'h1E3;
            6'd24: return 10'h224;
            6'd25: return 10'h168;
            default: return 10'h000;
        endcase
    endfunction
    logic [2:0] mul_i, mul_j;
    logic [3:0] mul_s;
    logic [15:0] partial;
    tbyte_mul u_mul(.a(am_b[mul_i]), .b(bm_b[mul_j]), .prod(partial));
    logic [9:0] cnt_d;
    assign cnt_d = cnt_dec(cnt);
    assign {mul_s, mul_i, mul_j} = cnt_d;

    // Pure-LUT выравнивание partial_q: pa[8*s +: 16] = partial_q (сдвиг 4*s тритов).
    // Заменяет 40× (t>=shift_q && t<shift_q+8 && t-shift_q) — сравнения/вычитания.
    logic [79:0] pa;
    always_comb begin
        case (s_q)
            4'd0: pa = {64'b0, partial_q};
            4'd1: pa = {56'b0, partial_q, 8'b0};
            4'd2: pa = {48'b0, partial_q, 16'b0};
            4'd3: pa = {40'b0, partial_q, 24'b0};
            4'd4: pa = {32'b0, partial_q, 32'b0};
            4'd5: pa = {24'b0, partial_q, 40'b0};
            4'd6: pa = {16'b0, partial_q, 48'b0};
            4'd7: pa = {8'b0, partial_q, 56'b0};
            4'd8: pa = {partial_q, 64'b0};
            default: pa = 80'b0;
        endcase
    end

    // ---- carry-save: per-column, Pure-LUT — 0 CARRY4 (BUG-037 fix) ----
    // Колонка = функция 3 тритов: sum_r[t]+carry_r[t]+pa[t] ∈ [-3,3];
    // r → sum_n[t], q → carry_n[t+1]. Одна LUT6 на выходной бит, глубина 1.
    logic [79:0] sum_n, carry_n;
    logic [3:0] cdec;
    always_comb begin
        for (int t = 0; t < 40; t++) begin
            cdec = csr3({sum_r[2*t+:2], carry_r[2*t+:2], pa[2*t+:2]});
            sum_n[2*t+:2] = cdec[1:0];
            if (t < 39)
                carry_n[2*(t+1)+:2] = cdec[3:2];
        end
        carry_n[1:0] = 2'b00;  // перенос в столбец 0 нет
    end

    // ---- финальная сборка: 2 трита/такт, тот же csr3 (0 CARRY4) ----
    logic [79:0] fin_n;
    logic signed [2:0] fin_carry_n;
    logic [1:0] last_n;
    logic [3:0] fdec;
    always_comb begin
        fin_n = fin_r;
        fin_carry_n = fin_carry;
        last_n = last_trit;
        for (int k = 0; k < 2; k++) begin
            int t = 2*fcnt + k;
            if (t < 40) begin
                fdec = csr3({v2t(fin_carry_n), sum_r[2*t+:2], carry_r[2*t+:2]});
                fin_n[2*t+:2] = fdec[1:0];
                fin_carry_n = t2v(fdec[3:2]);
                if (fdec[1:0] != 2'b00) last_n = fdec[1:0];
            end
        end
    end

    logic valid_q, neg_q;
    logic [79:0] prod_q;
    logic [7:0] e_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE; cnt <= 0; fcnt <= 0;
            sum_r <= 0; carry_r <= 0; fin_r <= 0;
            fin_carry <= 0; last_trit <= 0;
            partial_q <= 0; e_r <= 0;
            a_mr <= 0; b_mr <= 0; a_er <= 0; b_er <= 0;
            valid_q <= 0; prod_q <= 0; e_q <= 0; neg_q <= 0; s_q <= 0;
        end else begin
            valid_q <= 0;
            case (phase)
                PH_IDLE: if (valid_in) begin
                    a_mr <= a[39:0]; b_mr <= b[39:0];
                    a_er <= a[47:40]; b_er <= b[47:40];
                    phase <= PH_INIT;
                end
                PH_INIT: begin
                    cnt <= 0; fcnt <= 0; sum_r <= 0; carry_r <= 0; fin_r <= 0;
                    fin_carry <= 0; last_trit <= 0;
                    e_r <= exp_val(a_er) + exp_val(b_er) - 8'sd18;
                    phase <= PH_MUL;
                end
                PH_MUL: begin
                    sum_r <= sum_n; carry_r <= carry_n;
                    partial_q <= partial; s_q <= mul_s;
                    if (cnt == 25) begin
                        phase <= PH_FIN;
                        fcnt <= 0; fin_carry <= 0; last_trit <= 0;
                    end else cnt <= cnt + 1;
                end
                PH_FIN: begin
                    fin_r <= fin_n; fin_carry <= fin_carry_n; last_trit <= last_n;
                    if (fcnt == 19) phase <= PH_DONE;
                    else fcnt <= fcnt + 1;
                end
                PH_DONE: begin
                    neg_q <= (last_trit == N1); prod_q <= fin_r;
                    e_q <= e_r; valid_q <= 1; phase <= PH_IDLE;
                end
            endcase
        end
    end

    assign prod = prod_q; assign e = e_q; assign neg = neg_q; assign valid_out = valid_q;
endmodule