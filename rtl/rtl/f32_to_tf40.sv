// ============================================================================
// f32_to_tf40.sv - конвертер IEEE float32 -> TFloat40 (F2T)
// ============================================================================
// value = M * 3^(E-60-13), M - 15 тритов (целая, норм. [3^13,3^14)),
// E - 5 тритов (bias 60).
//
// Надёжный детерминированный алгоритм (совпадает с Python-эмулятором):
//   value = m24 * 2^(e2-150)  (m24 = {1,mant}, 24 бита)
//   e3 = floor(log3(value))   - ищется итеративно сравнением
//   M  = round(value * 3^13 / 3^e3)
//   нормализация M к [3^13, 3^14)
//
// Точный логарифм не аппроксимируем: используем целочисленное сравнение
// "value * 3^13 >= 3^e3" через широкую фиксированную точку.
// ============================================================================

module f32_to_tf40 (
    input  logic [31:0] f32,
    output logic [39:0] tf40
);
    import tfloat_pkg::*;

    // --- разбор ---
    logic        sign;
    logic [7:0]  e2;
    logic [22:0] mant;
    logic [23:0] m24;
    logic        is_zero, is_inf, is_nan;

    assign sign = f32[31];
    assign e2   = f32[30:23];
    assign mant = f32[22:0];
    assign m24  = {1'b1, mant};
    assign is_zero = (e2 == 8'h00) && (mant == 23'h0);
    assign is_inf  = (e2 == 8'hFF) && (mant == 23'h0);
    assign is_nan  = (e2 == 8'hFF) && (mant != 23'h0);

    // --- рабочие сигналы ---
    localparam int W = 128;              // широкая фиксированная точка
    localparam int Q = 64;               // дробных бит
    // value = m24 * 2^(e2-150). Масштабируем: value_q = m24 * 2^(e2-150+Q)
    logic signed [15:0] shift;
    logic [W-1:0] val_q;                // value * 2^Q (беззнак., m24 > 0)
    logic signed [31:0] e3;             // троичная экспонента
    logic [W-1:0] val3;                 // value * 3^13 / 3^e3 (M-кандидат)

    assign shift = $signed({8'b0, e2}) - 150 + Q;

    // m24 расширенный до W бит (значение мантиссы)
    logic [W-1:0] m24w;
    assign m24w = {{(W-24){1'b0}}, m24};

    logic [6:0] shamt;
    always_comb begin
        if (shift >= 0) begin
            if (shift >= W) val_q = {W{1'b0}};
            else begin
                shamt = shift[6:0];
                val_q = m24w << shamt;
            end
        end else begin
            if (-shift >= W) val_q = {W{1'b0}};
            else begin
                shamt = 0 - shift[6:0];
                val_q = m24w >> shamt;
            end
        end
    end

    // --- поиск e3: e3 такое, что 3^e3 <= value*2^Q < 3^(e3+1) ---
    // Используем бинарный/последовательный поиск по таблице степеней 3
    // в фиксированной точке. Диапазон e3: [-60, 61].
    // Проще: e3 = floor( value_q * 3^13 / 3^e3 )... нет.
    // Найдём e3 так, чтобы M = value_q * 3^13 / 3^e3  попал в [3^13*2^Q, 3^14*2^Q)
    // Экспонента e3 лежит в [-150*0.63.. ~+10]. Перебор от -60 до 61.
    // Масштаб: 3^13*2^Q огромно (1594323*2^64 ~ 2^84) - влезает в 128 бит.
    // Для каждого кандидата e: pow3 = 3^(e) * 2^Q; сравниваем с value_q*3^13.

    logic [W-1:0] value_p3;   // value_q * 3^13
    logic [W-1:0] pow3_e;     // 3^e3 * 2^Q
    logic [W-1:0] pow3_e1;    // 3^(e3+1) * 2^Q

    always_comb value_p3 = val_q * 128'd1594323;

    // вычислим pow3_for_e[g] = 3^(g-60) * 2^Q, g = e+60 in [0,121]
    // т.е. индекс 60 соответствует e3=0 (3^0). Центр - 2^Q.
    logic [W-1:0] pow3_for_e[0:121];
    logic [W-1:0] pbase;
    assign pbase = ({{(W-1){1'b0}}, 1'b1} << Q); // 2^Q

    genvar g;
    generate
        assign pow3_for_e[60] = pbase;                       // 3^0 * 2^Q
        for (g = 0; g < 60; g++) begin : gen_pow_down
            // 3^(g-60) = 3^((g+1)-60) / 3
            assign pow3_for_e[g] = pow3_for_e[g+1] / 3;
        end
        for (g = 61; g <= 121; g++) begin : gen_pow_up
            assign pow3_for_e[g] = pow3_for_e[g-1] * 3;
        end
    endgenerate

    // e3_off: value_q in [pow3_for_e[e3_off], pow3_for_e[e3_off+1])
    logic [6:0] e3_off;  // e3 + 60
    always_comb begin
        e3_off = 7'd0;
        for (int i = 0; i <= 120; i++) begin
            if (val_q >= pow3_for_e[i] && val_q < pow3_for_e[i+1])
                e3_off = i;
        end
        // edge: value_p3 >= pow3_for_e[121] -> e3_off = 121 (overflow)
        if (value_p3 >= pow3_for_e[121]) e3_off = 7'd121;
    end
    assign e3 = $signed({25'b0, e3_off}) - 60;

    // --- M = value_p3 / 3^e3 ---
    // M = value_p3 / pow3_for_e[e3_off]  (оба 128-бит)
    logic [W-1:0] M_raw, M;
    logic [6:0]   e3n_off;
    logic [15:0]  e3n;

    always_comb begin
        // округление к ближайшему: (value_p3 + pow3/2) / pow3
        M_raw = (value_p3 + (pow3_for_e[e3_off] >> 1)) / pow3_for_e[e3_off];
        M = M_raw;
        e3n_off = e3_off;
        // нормализация: пока M >= 3^14: M/=3, e3n++
        for (int i = 0; i < 8; i++)
            if (M >= 96'd4782969) begin M = M / 3; e3n_off = e3n_off + 1; end
        // пока M < 3^13 и e3n > 0: M*=3, e3n--
        for (int i = 0; i < 8; i++)
            if (M < 96'd1594323 && e3n_off > 0) begin M = M * 3; e3n_off = e3n_off - 1; end
        // округление: M = round(M) (M уже целое; добавим половину перед делением не нужно)
        if (sign) M = 0 - M;
        e3n = $signed({10'b0, e3n_off}) - 60;
    end

    // --- упаковка ---
    logic [M_TRITS*2-1:0] m_trits;
    logic [E_TRITS*2-1:0] e_trits;
    logic [39:0] tf_norm;

    int_to_trits #(.N(M_TRITS), .W(W)) u_m (.value($signed(M)), .trits(m_trits));
    int_to_trits #(.N(E_TRITS), .W(32)) u_e (.value($signed(e3n) + E_BIAS), .trits(e_trits));

    assign tf_norm = {m_trits, e_trits};

    always_comb begin
        if (is_zero)               tf40 = {TOTAL_TRITS{2'b00}};
        else if (is_nan || is_inf) tf40 = {TOTAL_TRITS{2'b11}};
        else                       tf40 = tf_norm;
    end

endmodule
