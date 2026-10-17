// ============================================================================
// f32_to_tf48.sv - конвертер IEEE float32 -> TFloat48 (конвенция ядра [E:8][M:40])
// ============================================================================
// value = M * 3^(e-18), M - 20 тритов (норм. [3^18,3^19)), e - 4 трита
// (ПРЯМОЙ balanced-код, БЕЗ bias, e in [-40,40]). Битовый расклад слова:
//   [47:40] = e, [39:0] = M.
//
// Точный integer-алгоритм (БИТ-В-БИТ = scripts/f2t48_proto.py, f2t_fixed):
//   value = m24 * 2^(real_e), real_e = e2-150, m24 = {1,mant}
//   e3 = floor(log3(value))  - точным сравнением value >= 3^k, k in [41..-40]
//   M  = round-half-up( value * 3^18 / 3^e3 )  = (2*num+den)//(2*den)
//   норм.: M -> [3^18,3^19)  (M/3,e++; M*3,e-- пока e>-40)
//   спец.: e2==0xFF -> 0 (inf/nan); ±0 -> 0; субнормал -> 0;
//          e<-40 -> 0 (uflow); e>40 -> ERR (все единицы).
// ============================================================================

module f32_to_tf48 (
    input  logic [31:0] f32,
    output logic [47:0] tf48
);
    import tf48_pkg::*;

    localparam int W = 260;          // ширина сравнений (хватает на все кросс-умножения)

    logic        sign;
    logic [7:0]  e2;
    logic [22:0] mant;
    logic [23:0] m24;
    logic        is_zero, is_infnan, is_sub;
    logic signed [8:0] real_e;
    logic signed [8:0] se_plus, se_minus;   // |real_e| по знаку
    logic [W-1:0] m24w;

    assign sign      = f32[31];
    assign e2        = f32[30:23];
    assign mant      = f32[22:0];
    assign m24       = {1'b1, mant};
    assign is_zero   = (e2 == 8'h00) && (mant == 23'h0);
    assign is_infnan = (e2 == 8'hFF);
    assign is_sub    = (e2 == 8'h00) && (mant != 23'h0);
    assign real_e    = $signed({1'b0, e2}) - 150;
    assign se_plus   = (real_e >= 0) ? real_e : 9'sd0;
    assign se_minus  = (real_e <  0) ? -real_e : 9'sd0;
    assign m24w      = {{(W-24){1'b0}}, m24};

    // --- таблицы степеней 3 ---
    logic [W-1:0] P3  [0:41];   // 3^k, k=0..41
    logic [W-1:0] P3m [1:40];   // 3^j (j=-k), для знаменателей кросс-сравнения
    logic [W-1:0] K3p [0:58];   // 3^p, p=0..58 (18-e3)
    logic [W-1:0] pbase;
    assign pbase = {{(W-1){1'b0}}, 1'b1};

    genvar g;
    generate
        assign P3[0] = pbase;
        for (g = 1; g <= 41; g++) assign P3[g] = P3[g-1] * 3;
        for (g = 1; g <= 40; g++) assign P3m[g] = P3[g];
        assign K3p[0] = pbase;
        for (g = 1; g <= 58; g++) assign K3p[g] = K3p[g-1] * 3;
    endgenerate

    // --- value >= 3^k (точное крос-умножение) ---
    function automatic logic value_ge(input int kk);
        logic [W-1:0] lhs, rhs;
        if (se_plus != 0 || real_e >= 0) begin
            // real_e >= 0: value = m24<<real_e (целое >= 2^23)
            if (kk < 0)
                value_ge = 1'b1;                // 2^23 > 3^kk для kk<0
            else begin
                lhs = m24w << se_plus[8:0];
                rhs = P3[kk];
                value_ge = (lhs >= rhs);
            end
        end else begin
            // real_e < 0: value = m24 / 2^sh
            if (kk >= 0) begin
                rhs = P3[kk] << se_minus[8:0];   // 3^kk * 2^sh
                value_ge = (m24w >= rhs);
            end else begin
                rhs = pbase << se_minus[8:0];    // 2^sh
                rhs = rhs + P3m[-kk] - 1;
                rhs = rhs / P3m[-kk];            // ceil(2^sh/3^-kk)
                value_ge = (m24w >= rhs);
            end
        end
    endfunction

    // --- поиск e3 = floor(log3(value)) ---
    logic signed [31:0] e3;
    always_comb begin
        e3 = -32'sd127;                 // sentinel "не найдено" (вне [-41,41])
        for (int k = 41; k >= -40; k--) begin
            if (value_ge(k)) begin
                e3 = k;
                break;
            end
        end
        if (e3 == -32'sd127) e3 = -41;  // value < 3^-40 -> uflow sentinel
    end

    logic uflow, oflo;
    assign uflow = (e3 < -40);
    assign oflo  = (e3 > 40);

    // --- M = round-half-up( value*3^18/3^e3 ) = (2*num+den)//(2*den) ---
    localparam int WN = 192;
    logic [7:0] kexp_down, kexp_up;
    logic [WN-1:0] num, den, Mraw;
    logic [WN:0]   Mnum2, Mden2;

    always_comb begin
        kexp_down = 8'd0;
        kexp_up   = 8'd0;
        if (e3 <= 18) begin
            kexp_down = (e3 >= 0) ? (18 - e3[7:0]) : (18 + (-e3[7:0]));
            if (kexp_down > 58) kexp_down = 58;    // clamp (uflow sentinel)
        end else begin
            kexp_up = e3[7:0] - 18;                // e3 in 19..41 (max 23)
        end
    end

    always_comb begin
        num = {WN{1'b0}};
        den = {WN{1'b0}};
        if (e3 <= 18) begin
            num = m24w[WN-1:0] * K3p[kexp_down];   // m24 * 3^(18-e3)
            den = 1;
            if (se_plus != 0 || real_e >= 0)
                num = num << se_plus[8:0];
            else
                den = den << se_minus[8:0];
        end else begin
            num = m24w[WN-1:0];
            if (se_plus != 0 || real_e >= 0)
                num = num << se_plus[8:0];
            else
                num = num >> se_minus[8:0];
            den = K3p[kexp_up];                   // 3^(e3-18)
        end
    end

    always_comb begin
        Mnum2 = ({num, 1'b0}) + {1'b0, den};    // 2*num + den (193 бит)
        Mden2 = {den, 1'b0};                    // 2*den (193 бит)
        Mraw  = Mnum2[WN:0] / Mden2[WN:0];      // 193/193 = 192+ бит (M ~3^18)
    end

    // --- нормализация M к [3^18,3^19) ---
    logic [WN-1:0] Mn;
    logic signed [31:0] en;
    always_comb begin
        Mn = Mraw;
        en = e3;
        for (int i = 0; i < 4; i++) begin
            if (Mn >= M_NORM_MAX) begin
                Mn = Mn / 3;
                en = en + 1;
            end else if (Mn < M_NORM_MIN && en > -40) begin
                Mn = Mn + (Mn << 1);               // *3
                en = en - 1;
            end
        end
    end

    // --- кодирование ---
    logic [M_TRITS*2-1:0] m_trits;
    logic [E_TRITS*2-1:0] e_trits;
    logic [M_TRITS*2-1:0] m_sign;
    logic [63:0] Mabs64;
    assign Mabs64 = Mn[63:0];

    int_to_trits #(.N(M_TRITS), .W(64)) u_m (.value($signed(Mabs64)), .trits(m_trits));
    int_to_trits #(.N(E_TRITS), .W(32)) u_e (.value(en[31:0]), .trits(e_trits));

    genvar j;
    generate
        for (j = 0; j < M_TRITS; j++) begin : gen_pack_m
            assign m_sign[j*2 +: 2] = (sign) ?
                (m_trits[j*2 +: 2] == TRIT_P1 ? TRIT_N1 :
                 (m_trits[j*2 +: 2] == TRIT_N1 ? TRIT_P1 : TRIT_0))
                : m_trits[j*2 +: 2];
        end
    endgenerate

    logic [47:0] out_norm;
    assign out_norm = {e_trits, m_sign};   // [47:40]=E, [39:0]=M

    always_comb begin
        if (is_zero || is_infnan || is_sub)  tf48 = 48'h0;
        else if (uflow)                      tf48 = 48'h0;
        else if (oflo)                       tf48 = 48'hFFFFFFFFFFFF;
        else                                 tf48 = out_norm;
    end

endmodule