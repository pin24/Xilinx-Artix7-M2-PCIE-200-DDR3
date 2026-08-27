// ============================================================================
// tf40_to_f32.sv - конвертер TFloat40 -> IEEE float32 (T2F)
// ============================================================================
// value = M * 3^(E-60-13), M - 15 тритов (целая), E - 5 тритов (bias 60).
// Результат - float32, округлённый к ближайшему (round-half-up, как RTL F2T).
//
// Алгоритм:
//   1. M (знаковое целое из тритов), e = E - 60.
//   2. e2 = floor(e * log2(3))  - двоичная экспонента.
//   3. M2 = round( M * 3^(e-13) * 2^(23-e2) )  -> 24-битная мантисса.
//      Упрощение: M * 3^(e-13) = value. Считаем через широкую фикс. точку:
//      val3 = M * 3^e (или /3^-e), затем /3^13, затем *2^(23-e2).
//   4. Нормализация к [2^23, 2^24), сборка float32.
// ============================================================================

module tf40_to_f32 (
    input  logic [39:0] tf40,
    output logic [31:0] f32
);
    import tfloat_pkg::*;

    logic [M_TRITS*2-1:0] m_trits;
    logic [E_TRITS*2-1:0] e_trits;
    assign m_trits = tf40[TOTAL_BITS-1 : E_BITS];   // старшие 30 бит (15 тритов)
    assign e_trits = tf40[E_BITS-1 : 0];            // младшие 10 бит (5 тритов)

    // --- M (знаковое целое из тритов, старший первым) ---
    logic signed [47:0] M;
    logic signed [47:0] Mabs;
    always_comb begin
        M = 48'sd0;
        for (int i = M_TRITS-1; i >= 0; i--) begin
            M = M * 3 + $signed(trit_val(m_trits[i*2 +: 2]));
        end
    end
    assign Mabs = (M < 0) ? -M : M;

    // знак = знак всей мантиссы M (не только старшего трита)
    logic sign;
    always_comb sign = (M < 0);

    // --- e = E - 60 (balanced ternary, старший первым) ---
    logic signed [15:0] e;
    always_comb begin
        e = 16'sd0;
        for (int i = E_TRITS-1; i >= 0; i--) begin
            e = e * 3 + $signed(trit_val(e_trits[i*2 +: 2]));
        end
        e = e - E_BIAS;
    end

    // e2 = floor(e * log2(3)), log2(3) ~ 1.5849625
    logic signed [31:0] e2;
    localparam signed [31:0] LOG2_3_X = 32'sd103_845; // 1.5849625 * 2^16
    always_comb begin
        e2 = (e * LOG2_3_X) >> 16;
    end

    // --- m24 = round( M * 3^(e-13) * 2^(23-e2) ) ---
    // value = M*3^(e-13); m24 = value*2^(23-e2)  (норм. ~ [2^23,2^24))
    // num = M*3^(e-13), den = 1          (если e >= 13)
    // num = M,          den = 3^(13-e)   (если e < 13)
    localparam int W = 128;
    logic [W-1:0] num, den, num2, m2;
    logic signed [15:0] sh2;
    logic [6:0] sh2_abs;
    assign sh2 = 23 - e2[15:0];
    assign sh2_abs = (sh2 < 0) ? 0 - sh2[6:0] : 7'd0;

    always_comb begin
        num = {W{1'b0}};
        den = {W{1'b0}};
        if (e >= 13) begin
            num = {{(W-48){1'b0}}, Mabs};
            for (int i = 0; i < 48; i++)
                if (i < (e - 13)) num = num * 3;
            den = 1;
        end else begin
            num = {{(W-48){1'b0}}, Mabs};
            den = 1;
            for (int i = 0; i < 74; i++)
                if (i < (13 - e)) den = den * 3;
        end
        // num * 2^(23-e2)
        if (sh2 >= 0)
            num2 = (sh2 >= W) ? {W{1'b0}} : (num << sh2[6:0]);
        else
            num2 = (-sh2 >= W) ? {W{1'b0}} : (num >> sh2_abs);
        // m24 = round(num2 / den)
        m2 = (num2 + (den >> 1)) / (den == 0 ? 1 : den);
    end

    // --- нормализация m2 к [2^23, 2^24) + округление ---
    logic [W-1:0] mn;
    logic signed [15:0] e2n;
    always_comb begin
        mn = m2;
        e2n = e2[15:0];
        // пока mn >= 2^24: mn>>=1, e2n++
        for (int i = 0; i < 8; i++)
            if (mn >= 96'h1000000) begin mn = mn >> 1; e2n = e2n + 1; end
        // пока mn < 2^23 и e2n > -126: mn<<=1, e2n--
        for (int i = 0; i < 8; i++)
            if (mn < 96'h800000 && e2n > -126) begin mn = mn << 1; e2n = e2n - 1; end
        // округление к 24-битной мантиссе: смотрим лишние биты
        // (mn в [2^23, 2^24) -> старшие 24 бита точные, младшие отбрасываем)
    end

    // --- сборка float32 ---
    logic [23:0] mant24;
    logic [7:0]  e2out;
    logic [31:0] out_norm;

    always_comb begin
        if (mn == {W{1'b0}}) begin
            out_norm = 32'h0000_0000;
        end else begin
            mant24 = mn[23:0];   // mn нормализован к [2^23, 2^24)
            e2out  = e2n[7:0] + 127;
            out_norm = {sign, e2out, mant24[22:0]};
        end
    end

    always_comb begin
        // спецслучаи: ошибка -> NaN; ноль -> +-0
        if (M == 0)
            f32 = sign ? 32'h8000_0000 : 32'h0000_0000;
        else if (tf40[0 +: 2] == TRIT_ERR || tf40[2 +: 2] == TRIT_ERR)
            f32 = 32'h7FC0_0000;
        else
            f32 = out_norm;
    end

endmodule
