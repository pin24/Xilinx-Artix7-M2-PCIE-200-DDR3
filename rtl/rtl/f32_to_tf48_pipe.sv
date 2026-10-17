// ============================================================================
// f32_to_tf48_pipe.sv - КОНВЕЙЕРНЫЙ конвертер float32 -> TFloat48 (ядро [E:8][M:40])
// ============================================================================
// Бит-в-бит эквивалентен комбинационному f32_to_tf48.sv, НО широкая
// 193-битная делительная цепь (Mraw = (2*num+den)/(2*den)) вынесена в
// таймингово-безопасный byte-serial конвейер tf48_div_pipe (BPB=8,
// NS=ceil(193/8)=25 стадий). Это то же, что делается в f32_to_tf40_pipe2,
// но с делителем, сериализованным по байтам.
//
// ВАЖНО (грабли xsim): всё входное комбинационное ядро (знак, e3=floor(log3),
// num/den, Mnum2/Mden2, флаги) вычисляется в ОДНОМ always_comb - отдельные
// always_comb-блоки не сходятся в одном delta и пре-стадия ловит X на первом
// нормальном значении. Один монолитный always_comb устраняет это.
//
// Латентность: 1 (пре-стадия) + 25 (делитель) + 1 (выходной каскад) ~ 27 тактов.
// Throughput: 1 элемент/такт.
//
// Конвенция выхода (ядро): [47:40]=e (прямой balanced), [39:0]=M.
// Спецслучаи (как host fpga_backend): inf/nan->0, ±0->0, субнормал->0,
// подъём=>0, переполнение (e>40)->ERR (все единицы).
// ============================================================================

module f32_to_tf48_pipe (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        s_axis_tvalid,
    input  logic [31:0] s_axis_tdata,
    output logic        m_axis_tvalid,
    output logic [47:0] m_axis_tdata,
    output logic        diag_d_valid   // = out_v (для отладки вклейки)
);
    import tf48_pkg::*;

    localparam int W  = 260;   // ширина сравнений (как в comb f32_to_tf48)
    localparam int WN = 192;

    // ============ ОДИН монолитный always_comb: всё входное комбинационное ядро ====
    logic        c_sign, c_is_zero, c_is_infnan, c_is_sub;
    logic signed [31:0] c_e3;
    logic [WN:0] c_Mnum2, c_Mden2;

    always_comb begin
        // --- локальные объявления (до исполняемых операторов) ---
        logic [7:0]  e2;
        logic [22:0] mant;
        logic [23:0] m24;
        logic        is_z, is_inf, is_s;
        logic signed [8:0] real_e;
        logic [8:0]  se_plus, se_minus;
        logic [W-1:0] m24w;
        logic [W-1:0] P3  [0:41];
        logic [W-1:0] P3m [1:40];
        logic [W-1:0] K3p [0:58];
        logic [7:0]  kexp_down, kexp_up;
        logic [WN-1:0] num, den;
        logic found;

        // --- декод ---
        c_sign    = s_axis_tdata[31];
        e2        = s_axis_tdata[30:23];
        mant      = s_axis_tdata[22:0];
        m24       = {1'b1, mant};
        is_z      = (e2 == 8'h00) && (mant == 23'h0);
        is_inf    = (e2 == 8'hFF);
        is_s      = (e2 == 8'h00) && (mant != 23'h0);
        real_e    = $signed({1'b0, e2}) - 150;
        se_plus   = (real_e >= 0) ? real_e : 9'sd0;
        se_minus  = (real_e <  0) ? -real_e : 9'sd0;
        m24w      = {{(W-24){1'b0}}, m24};

        // таблицы 3^k, 3^p, 3^q (константы, считаются комбинационно)
        P3[0] = {{(W-1){1'b0}}, 1'b1};
        for (int g = 1; g <= 41; g++) P3[g] = P3[g-1] * 3;
        for (int g = 1; g <= 40; g++) P3m[g] = P3[g];
        K3p[0] = {{(W-1){1'b0}}, 1'b1};
        for (int g = 1; g <= 58; g++) K3p[g] = K3p[g-1] * 3;

        // --- e3 = floor(log3(value)) ---
        c_e3  = -32'sd127;
        found = 1'b0;
        for (int k = 41; k >= -40; k--) begin
            logic [W-1:0] lhs, rhs;
            logic ge;
            ge = 1'b0;
            if (real_e >= 0) begin
                if (k < 0)
                    ge = 1'b1;
                else begin
                    lhs = m24w << se_plus[8:0];
                    rhs = P3[k];
                    ge = (lhs >= rhs);
                end
            end else begin
                if (k >= 0) begin
                    rhs = P3[k] << se_minus[8:0];
                    ge = (m24w >= rhs);
                end else begin
                    rhs = {{(W-1){1'b0}}, 1'b1} << se_minus[8:0];
                    rhs = rhs + P3m[-k] - 1;
                    rhs = rhs / P3m[-k];
                    ge = (m24w >= rhs);
                end
            end
            if (ge && !found) begin
                c_e3 = k;
                found = 1'b1;
            end
        end
        if (!found) c_e3 = -41;

        // --- num/den и Mnum2/Mden2 ---
        kexp_down = 8'd0; kexp_up = 8'd0;
        if (c_e3 <= 18) begin
            kexp_down = (c_e3 >= 0) ? (18 - c_e3[7:0]) : (18 + (-c_e3[7:0]));
            if (kexp_down > 58) kexp_down = 58;
        end else begin
            kexp_up = c_e3[7:0] - 18;
        end
        num = {WN{1'b0}};
        den = {WN{1'b0}};
        if (c_e3 <= 18) begin
            num = m24w[WN-1:0] * K3p[kexp_down];
            den = 1;
            if (real_e >= 0)
                num = num << se_plus[8:0];
            else
                den = den << se_minus[8:0];
        end else begin
            num = m24w[WN-1:0];
            if (real_e >= 0)
                num = num << se_plus[8:0];
            else
                num = num >> se_minus[8:0];
            den = K3p[kexp_up];
        end
        c_Mnum2 = ({num, 1'b0}) + {1'b0, den};
        c_Mden2 = {den, 1'b0};
        c_is_zero = is_z;
        c_is_infnan = is_inf;
        c_is_sub  = is_s;
    end

    // ============ пре-стадия: захват входа делителя + служебных флагов ============
    logic        p_valid;
    logic [WN:0] p_Mnum2, p_Mden2;
    logic        p_sign, p_zero, p_infnan, p_sub;
    logic signed [31:0] p_e3;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_valid <= 1'b0;
            p_Mnum2 <= '0; p_Mden2 <= '0;
            p_sign <= 1'b0; p_zero <= 1'b0; p_infnan <= 1'b0; p_sub <= 1'b0;
            p_e3 <= -32'sd127;
        end else begin
            p_valid  <= s_axis_tvalid;
            p_Mnum2  <= c_Mnum2;
            p_Mden2  <= c_Mden2;
            p_sign   <= c_sign;
            p_zero   <= c_is_zero;
            p_infnan <= c_is_infnan;
            p_sub    <= c_is_sub;
            p_e3     <= c_e3;
        end
    end

    // ============ byte-serial делитель 193/193 ============
    localparam int NS  = (193 + 8 - 1) / 8;   // 25 стадий деления
    logic        dv_valid;
    logic [192:0] dv_q;
    logic [192:0] dv_rem;
    tf48_div_pipe #(.N(193), .M(193), .QW(193), .BPB(8)) u_div (
        .clk(clk), .rst_n(rst_n),
        .i_valid(p_valid),
        .i_num(p_Mnum2), .i_den(p_Mden2),
        .o_valid(dv_valid), .o_q(dv_q), .o_rem(dv_rem)
    );

    // ============ линия задержки служебных сигналов до выхода делителя ============
    // Делитель: пред-стадия (1 такт) + NS стадий. Выход o_valid через NS+1 тактов
    // после p_valid; d_valid[NS] через 1+NS после s_axis_tvalid -> выравнивание.
    localparam int DL = NS;
    logic        d_valid [0:DL];
    logic        d_zero  [0:DL];
    logic        d_infnan[0:DL];
    logic        d_sub   [0:DL];
    logic        d_sign  [0:DL];
    logic signed [31:0] d_e3 [0:DL];
    genvar dd;
    generate
        for (dd = 0; dd <= DL; dd++) begin : gen_dly
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    d_valid[dd]   <= 1'b0;
                    d_zero[dd]    <= 1'b0; d_infnan[dd] <= 1'b0; d_sub[dd] <= 1'b0;
                    d_sign[dd]    <= 1'b0;
                    d_e3[dd]      <= -32'sd127;
                end else begin
                    if (dd == 0) begin
                        d_valid[0]   <= p_valid;
                        d_zero[0]    <= p_zero; d_infnan[0] <= p_infnan; d_sub[0] <= p_sub;
                        d_sign[0]    <= p_sign;
                        d_e3[0]      <= p_e3;
                    end else begin
                        d_valid[dd]   <= d_valid[dd-1];
                        d_zero[dd]    <= d_zero[dd-1];
                        d_infnan[dd]  <= d_infnan[dd-1];
                        d_sub[dd]     <= d_sub[dd-1];
                        d_sign[dd]    <= d_sign[dd-1];
                        d_e3[dd]      <= d_e3[dd-1];
                    end
                end
            end
        end
    endgenerate

    // ============ выходной комбинационный каскад: нормализация + упаковка ============
    logic [191:0] Mn;
    logic signed [31:0] en;
    always_comb begin
        Mn = dv_q[191:0];
        en = d_e3[DL];
        for (int i = 0; i < 4; i++) begin
            if (Mn >= M_NORM_MAX) begin
                Mn = Mn / 3;
                en = en + 1;
            end else if (Mn < M_NORM_MIN && en > -40) begin
                Mn = Mn + (Mn << 1);
                en = en - 1;
            end
        end
    end

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
            assign m_sign[j*2 +: 2] = (d_sign[DL]) ?
                (m_trits[j*2 +: 2] == TRIT_P1 ? TRIT_N1 :
                 (m_trits[j*2 +: 2] == TRIT_N1 ? TRIT_P1 : TRIT_0))
                : m_trits[j*2 +: 2];
        end
    endgenerate

    logic [47:0] out_norm;
    assign out_norm = {e_trits, m_sign};   // [47:40]=E, [39:0]=M

    logic [47:0] out_data;
    always_comb begin
        if (d_zero[DL] || d_infnan[DL] || d_sub[DL])  out_data = 48'h0;
        else if (d_e3[DL] < -40)                      out_data = 48'h0;
        else if (d_e3[DL] > 40)                       out_data = 48'hFFFFFFFFFFFF;
        else                                          out_data = out_norm;
    end

    // ============ выходной регистровый каскад ============
    logic        out_v;
    logic [47:0] out_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_v <= 1'b0;
            out_q <= '0;
        end else begin
            out_q <= out_data;
            out_v <= d_valid[DL];
        end
    end
    assign m_axis_tvalid = out_v;
    assign m_axis_tdata  = out_q;
    assign diag_d_valid  = d_valid[DL];

endmodule