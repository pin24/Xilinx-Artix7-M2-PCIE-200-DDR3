// ============================================================================
// tfadd_raw.sv — сумматор НЕНОРМАЛИЗОВАННЫХ продуктов TFloat48, BARREL-версия
// ============================================================================
// Шаг 1 плана пайплайнинга дерева (разрешено пользователем, 2026-09-06).
// ЛАТЕНТНОСТЬ: ФИКСИРОВАННАЯ 6 тактов (было 6..50+, data-dependent):
//   IDLE -> INIT -> ALGN(баррель) -> ADD -> NORM(баррель) -> DONE.
//
// Семантика НЕ изменилась (бит-в-бит). Доказательство: proof_tfadd_barrel.py
// (ALL PROOFS PASSED, 280k+ векторов) + A/B на xsim: tb_tfadd_equiv.sv.
//   * ALGN: rhu_next serial (+1/-1 танцы, round-to-nearest по модулю) ==
//     чистый сбалансированный сдвиг на 1 (A1); k сдвигов == сдвиг на k (A3)
//     -> однотактный баррель k = min(|de|, 22), БЕЗ цепей переноса.
//   * NORM: fd3 == sign*floor(|x|/3) (A2) -> floor/3^k одним сдвигом с
//     коррекцией -1 (если старший ненулевой отброшенный трит == N1);
//     x3^k — чистый сдвиг. Диапазон — по КАНОНИЧЕСКОЙ позиции
//     P = floor(log3|sum|), НЕ по позиции старшего сбалансированного трита
//     (контрпример: 3^19-1: p=19, но P=18 — уже в диапазоне). HW-правило:
//     P = p - [старший ненулевой трит ниже p == N1] (A4b, 50k векторов).
//   * Порядок проверок NORM как в serial: zero -> e_sum>40 (SAT) ->
//     P>=19: floor/3^(P-18) c клампом e_sum+k<=40 -> P<=17: x3^min(18-P,
//     e_sum+40) -> P=18: готово. DONE: zero|e_sum<-40 -> 0; SAT -> FF.
//
// BUG-040 (исправлен здесь, найден при подготовке барреля): в serial
//   cnt[5:0] обрезал |Δe| по mod 64; продукты tfmul_raw дают
//   e = ea+eb-18 ∈ [-98, 62] => Δe до 160, при |Δe| >= 64 выравнивание
//   шло по мусорному сдвигу (напр. Δe=64 -> cnt=0 -> малый продукт
//   добавлялся в масштабе большого). Теперь de — 9 бит,
//   k = min(|de|, 22) — проектное намерение (A6: barrel == intent на всём
//   de 0..160; serial с багом расходится в 2880/30000 случайных de>=64).
//
// BUG-041 (исправлен здесь, 2026-09-06, найден при подготовке Шага 2 дерева):
//   нулевые операнды. Выбор big/small шёл по ЭКСПОНЕНТЕ, а нулевой продукт /
//   частичная сумма несёт МУСОРНУЮ экспоненту (tfmul_raw: prod=0,
//   e=ea+eb-18 ∈ [-98,62]; нулевой TFloat48 = m=0, e=0). Если нулевой операнд
//   оказывался «большим» (напр. нулевой вес при данных с e<0), ненулевой
//   операнд уходил в m_small и сдвигался на min(|Δe|,22) тритов: при |Δe|>22 —
//   ТЕРЯЛСЯ ПОЛНОСТЬЮ (x+0 == 0), при |Δe|<=22 — огрызался. Реальный кейс —
//   тернарные веса {-1,0,+1}: много нулевых продуктов на уровне 0 дерева и
//   нулевые частичные суммы (48'h0, e=0) на уровнях >=1. Теперь: za/zb —
//   нулевой операнд выбрасывается, ненулевой идёт как big с k=0:
//   x+0 == norm(x), 0+0 == 0 (семантика golden _raw_add из
//   verify_compute_dot_par_raw.py). Доказательство: proof_tree_par.py (Z1/Z2).
// ============================================================================
module tfadd_raw (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [79:0] a_prod,
    input  logic signed [7:0]  a_e,
    input  logic        a_neg,
    input  logic [79:0] b_prod,
    input  logic signed [7:0]  b_e,
    input  logic        b_neg,
    output logic        valid_out,
    output logic [47:0] result
);
    localparam logic [1:0] P1 = 2'b01;
    localparam logic [1:0] N1 = 2'b10;
    localparam int W = 42;

    function automatic logic signed [2:0] trit_val2(input logic [1:0] c);
        case (c)
            P1: trit_val2 = 3'sd1;
            N1: trit_val2 = -3'sd1;
            default: trit_val2 = 3'sd0;
        endcase
    endfunction

    function automatic logic [1:0] int2trit2(input logic signed [2:0] v);
        case (v)
            3'sd1: int2trit2 = P1;
            -3'sd1: int2trit2 = N1;
            default: int2trit2 = 2'b00;
        endcase
    endfunction

    function automatic logic [7:0] exp_code(input logic signed [7:0] v);
        logic [7:0] out;
        case (v)
            -8'sd40: out = {2'b10,2'b10,2'b10,2'b10};
            -8'sd39: out = {2'b10,2'b10,2'b10,2'b00};
            -8'sd38: out = {2'b10,2'b10,2'b10,2'b01};
            -8'sd37: out = {2'b10,2'b10,2'b00,2'b10};
            -8'sd36: out = {2'b10,2'b10,2'b00,2'b00};
            -8'sd35: out = {2'b10,2'b10,2'b00,2'b01};
            -8'sd34: out = {2'b10,2'b10,2'b01,2'b10};
            -8'sd33: out = {2'b10,2'b10,2'b01,2'b00};
            -8'sd32: out = {2'b10,2'b10,2'b01,2'b01};
            -8'sd31: out = {2'b10,2'b00,2'b10,2'b10};
            -8'sd30: out = {2'b10,2'b00,2'b10,2'b00};
            -8'sd29: out = {2'b10,2'b00,2'b10,2'b01};
            -8'sd28: out = {2'b10,2'b00,2'b00,2'b10};
            -8'sd27: out = {2'b10,2'b00,2'b00,2'b00};
            -8'sd26: out = {2'b10,2'b00,2'b00,2'b01};
            -8'sd25: out = {2'b10,2'b00,2'b01,2'b10};
            -8'sd24: out = {2'b10,2'b00,2'b01,2'b00};
            -8'sd23: out = {2'b10,2'b00,2'b01,2'b01};
            -8'sd22: out = {2'b10,2'b01,2'b10,2'b10};
            -8'sd21: out = {2'b10,2'b01,2'b10,2'b00};
            -8'sd20: out = {2'b10,2'b01,2'b10,2'b01};
            -8'sd19: out = {2'b10,2'b01,2'b00,2'b10};
            -8'sd18: out = {2'b10,2'b01,2'b00,2'b00};
            -8'sd17: out = {2'b10,2'b01,2'b00,2'b01};
            -8'sd16: out = {2'b10,2'b01,2'b01,2'b10};
            -8'sd15: out = {2'b10,2'b01,2'b01,2'b00};
            -8'sd14: out = {2'b10,2'b01,2'b01,2'b01};
            -8'sd13: out = {2'b00,2'b10,2'b10,2'b10};
            -8'sd12: out = {2'b00,2'b10,2'b10,2'b00};
            -8'sd11: out = {2'b00,2'b10,2'b10,2'b01};
            -8'sd10: out = {2'b00,2'b10,2'b00,2'b10};
            -8'sd9 : out = {2'b00,2'b10,2'b00,2'b00};
            -8'sd8 : out = {2'b00,2'b10,2'b00,2'b01};
            -8'sd7 : out = {2'b00,2'b10,2'b01,2'b10};
            -8'sd6 : out = {2'b00,2'b10,2'b01,2'b00};
            -8'sd5 : out = {2'b00,2'b10,2'b01,2'b01};
            -8'sd4 : out = {2'b00,2'b00,2'b10,2'b10};
            -8'sd3 : out = {2'b00,2'b00,2'b10,2'b00};
            -8'sd2 : out = {2'b00,2'b00,2'b10,2'b01};
            -8'sd1 : out = {2'b00,2'b00,2'b00,2'b10};
            8'sd0  : out = {2'b00,2'b00,2'b00,2'b00};
            8'sd1  : out = {2'b00,2'b00,2'b00,2'b01};
            8'sd2  : out = {2'b00,2'b00,2'b01,2'b10};
            8'sd3  : out = {2'b00,2'b00,2'b01,2'b00};
            8'sd4  : out = {2'b00,2'b00,2'b01,2'b01};
            8'sd5  : out = {2'b00,2'b01,2'b10,2'b10};
            8'sd6  : out = {2'b00,2'b01,2'b10,2'b00};
            8'sd7  : out = {2'b00,2'b01,2'b10,2'b01};
            8'sd8  : out = {2'b00,2'b01,2'b00,2'b10};
            8'sd9  : out = {2'b00,2'b01,2'b00,2'b00};
            8'sd10 : out = {2'b00,2'b01,2'b00,2'b01};
            8'sd11 : out = {2'b00,2'b01,2'b01,2'b10};
            8'sd12 : out = {2'b00,2'b01,2'b01,2'b00};
            8'sd13 : out = {2'b00,2'b01,2'b01,2'b01};
            8'sd14 : out = {2'b01,2'b10,2'b10,2'b10};
            8'sd15 : out = {2'b01,2'b10,2'b10,2'b00};
            8'sd16 : out = {2'b01,2'b10,2'b10,2'b01};
            8'sd17 : out = {2'b01,2'b10,2'b00,2'b10};
            8'sd18 : out = {2'b01,2'b10,2'b00,2'b00};
            8'sd19 : out = {2'b01,2'b10,2'b00,2'b01};
            8'sd20 : out = {2'b01,2'b10,2'b01,2'b10};
            8'sd21 : out = {2'b01,2'b10,2'b01,2'b00};
            8'sd22 : out = {2'b01,2'b10,2'b01,2'b01};
            8'sd23 : out = {2'b01,2'b00,2'b10,2'b10};
            8'sd24 : out = {2'b01,2'b00,2'b10,2'b00};
            8'sd25 : out = {2'b01,2'b00,2'b10,2'b01};
            8'sd26 : out = {2'b01,2'b00,2'b00,2'b10};
            8'sd27 : out = {2'b01,2'b00,2'b00,2'b00};
            8'sd28 : out = {2'b01,2'b00,2'b00,2'b01};
            8'sd29 : out = {2'b01,2'b00,2'b01,2'b10};
            8'sd30 : out = {2'b01,2'b00,2'b01,2'b00};
            8'sd31 : out = {2'b01,2'b00,2'b01,2'b01};
            8'sd32 : out = {2'b01,2'b01,2'b10,2'b10};
            8'sd33 : out = {2'b01,2'b01,2'b10,2'b00};
            8'sd34 : out = {2'b01,2'b01,2'b10,2'b01};
            8'sd35 : out = {2'b01,2'b01,2'b00,2'b10};
            8'sd36 : out = {2'b01,2'b01,2'b00,2'b00};
            8'sd37 : out = {2'b01,2'b01,2'b00,2'b01};
            8'sd38 : out = {2'b01,2'b01,2'b01,2'b10};
            8'sd39 : out = {2'b01,2'b01,2'b01,2'b00};
            8'sd40 : out = {2'b01,2'b01,2'b01,2'b01};
            default: out = 8'h00;
        endcase
        exp_code = out;
    endfunction

    // ---- регистры ----
    logic [2*W-1:0] m_big, m_small;
    logic signed [7:0] m_big_e;
    logic signed [7:0] e_sum;
    logic [2*W-1:0] sum;
    logic [47:0] result_q;
    logic valid_q;
    logic [4:0] k_algn;
    logic zero_q, sat_q;

    // ---- Δe (9 бит, BUG-040 fix) и k_algn = min(|Δe|, 22) ----
    logic signed [8:0] de_s;
    logic [8:0] de_a;
    logic [4:0] k_algn_c;
    assign de_s = $signed({a_e[7], a_e}) - $signed({b_e[7], b_e});
    assign de_a = de_s[8] ? (9'd0 - de_s) : de_s;
    assign k_algn_c = (de_a > 9'd22) ? 5'd22 : de_a[4:0];

    // ---- BUG-041: детект нулевых операндов (мантисса == 0, все триты 00) ----
    logic za, zb;
    assign za = (a_prod == 80'h0);
    assign zb = (b_prod == 80'h0);

    // ---- ALGN баррель: чистый сбалансированный сдвиг на k_algn (nearest) ----
    logic [2*W-1:0] algn_y;
    always_comb begin
        for (int t = 0; t < W; t++)
            algn_y[2*t +: 2] = (t + k_algn <= W-1)
                             ? m_small[2*(t + k_algn) +: 2] : 2'b00;
    end

    // ---- ADD: 42-тритная сумма, разбита на 3 секции по 14 тритов (BUG-043) ----
    // Каждая секция ~14 тритов = ~14 LUT6 = ~7ns — укладывается в 8ns.
    // Перенос между секциями — через регистр carry_mid0_q/carry_mid1_q.
    logic signed [2:0] carry_mid0, carry_mid1;
    logic [27:0] add_mant_sec0, add_mant_sec1, add_mant_sec2;  // 14 тритов каждая

    always_comb begin
        logic signed [2:0] c;
        c = 3'sd0;
        for (int t = 0; t < 14; t++) begin
            logic signed [2:0] sv;
            sv = trit_val2(m_big[2*t +: 2]) + trit_val2(m_small[2*t +: 2]) + c;
            if (sv > 1) begin c = 3'sd1; add_mant_sec0[2*t +: 2] = int2trit2(sv - 3); end
            else if (sv < -1) begin c = -3'sd1; add_mant_sec0[2*t +: 2] = int2trit2(sv + 3); end
            else begin c = 3'sd0; add_mant_sec0[2*t +: 2] = int2trit2(sv); end
        end
        carry_mid0 = c;
    end

    always_comb begin
        logic signed [2:0] c;
        c = carry_mid0_q;
        for (int t = 14; t < 28; t++) begin
            logic signed [2:0] sv;
            sv = trit_val2(m_big[2*t +: 2]) + trit_val2(m_small[2*t +: 2]) + c;
            if (sv > 1) begin c = 3'sd1; add_mant_sec1[2*(t-14) +: 2] = int2trit2(sv - 3); end
            else if (sv < -1) begin c = -3'sd1; add_mant_sec1[2*(t-14) +: 2] = int2trit2(sv + 3); end
            else begin c = 3'sd0; add_mant_sec1[2*(t-14) +: 2] = int2trit2(sv); end
        end
        carry_mid1 = c;
    end

    always_comb begin
        logic signed [2:0] c;
        c = carry_mid1_q;
        for (int t = 28; t < W; t++) begin
            logic signed [2:0] sv;
            sv = trit_val2(m_big[2*t +: 2]) + trit_val2(m_small[2*t +: 2]) + c;
            if (sv > 1) begin c = 3'sd1; add_mant_sec2[2*(t-28) +: 2] = int2trit2(sv - 3); end
            else if (sv < -1) begin c = -3'sd1; add_mant_sec2[2*(t-28) +: 2] = int2trit2(sv + 3); end
            else begin c = 3'sd0; add_mant_sec2[2*(t-28) +: 2] = int2trit2(sv); end
        end
    end

    // ---- NORM: знак, p (старший сбаланс.), P (каноническая), барьеры ----
    logic        sum_neg;    // старший ненулевой трит sum == N1
    logic        p_found;    // sum != 0
    logic [5:0]  p_top;      // позиция старшего ненулевого трита
    logic        rest_n1;    // старший ненулевой НИЖЕ p_top == N1
    logic [5:0]  P_can;      // каноническая floor(log3|sum|): P = p - rest_n1
    logic [83:0] sum_abs;

    always_comb begin
        sum_neg = 1'b0; p_found = 1'b0; p_top = 6'd0;
        for (int t = W-1; t >= 0; t--) begin
            if (sum[2*t +: 2] != 2'b00 && !p_found) begin
                p_found = 1'b1;
                p_top   = 6'(t);
                sum_neg = (sum[2*t +: 2] == N1);
            end
        end
    end
    // отдельный проход для rest (старший ненулевой ниже p_top)
    always_comb begin
        logic rf;
        rf = 1'b0; rest_n1 = 1'b0;
        for (int t = W-2; t >= 0; t--) begin
            if (!rf && 32'(t) < 32'(p_top) && sum[2*t +: 2] != 2'b00) begin
                rf = 1'b1;
                rest_n1 = (sum[2*t +: 2] == N1);
            end
        end
    end

    always_comb begin
        if (!p_found)          P_can = 6'd0;
        else if (p_top == 0)   P_can = 6'd0;                  // |sum| == 1
        else                   P_can = rest_n1 ? (p_top - 6'd1) : p_top;
    end

    always_comb begin
        for (int t = 0; t < W; t++)
            sum_abs[2*t +: 2] = sum_neg
                              ? ((sum[2*t +: 2] == P1) ? N1 :
                                 (sum[2*t +: 2] == N1) ? P1 : 2'b00)
                              : sum[2*t +: 2];
    end

    logic        up_big;      // P >= 19  -> floor/3^(P-18)
    logic        dn_small;    // P <= 17  -> x3^(18-P)
    logic [5:0]  k_nrm;       // P - 18 (1..23)
    logic        sat_entry, sat_k, sat_norm;
    logic [83:0] fq;          // ÷-баррель (сдвиг |sum|)
    logic        corr_n1;     // коррекция floor: старший отброшенный == N1
    logic [83:0] fq_dec;      // floor-результат (модуль)
    logic [5:0]  k_dn;        // min(18-P, e_sum+40), 0..18
    logic [83:0] mul_y;       // ×-баррель (сдвиг sum влево)
    logic [83:0] norm_next;
    logic signed [7:0] e_sum_next;

    assign up_big   = p_found && (P_can >= 6'd19);
    assign dn_small = p_found && (P_can <= 6'd17);
    assign k_nrm    = P_can - 6'd18;
    assign sat_entry = (e_sum > 8'sd40);
    assign sat_k     = up_big &&
        (($signed({e_sum[7], e_sum}) + $signed({2'b00, k_nrm})) > 9'sd40);
    assign sat_norm  = sat_entry || sat_k;

    // ÷-баррель: fq[t] = sum_abs[t + k_nrm]
    always_comb begin
        for (int t = 0; t < W; t++)
            fq[2*t +: 2] = (t + k_nrm <= W-1)
                         ? sum_abs[2*(t + k_nrm) +: 2] : 2'b00;
    end
    // коррекция floor: старший ненулевой из отброшенных (t < k_nrm) == N1
    always_comb begin
        logic cf;
        cf = 1'b0; corr_n1 = 1'b0;
        for (int t = W-1; t >= 0; t--) begin
            if (!cf && 32'(t) < 32'(k_nrm) && sum_abs[2*t +: 2] != 2'b00) begin
                cf = 1'b1;
                corr_n1 = (sum_abs[2*t +: 2] == N1);
            end
        end
    end
    // тернарный декремент fq (borrow идёт по цепочке N1)
    always_comb begin
        logic [1:0] borr;
        logic signed [2:0] sv;
        fq_dec = fq;
        borr   = corr_n1 ? N1 : 2'b00;
        for (int t = 0; t < W; t++) begin
            if (borr != 2'b00) begin
                sv = trit_val2(fq_dec[2*t +: 2]) + trit_val2(borr);
                if (sv < -1) begin
                    fq_dec[2*t +: 2] = P1;   // -2 -> +1, borrow дальше
                    borr = N1;
                end else begin
                    fq_dec[2*t +: 2] = int2trit2(sv);
                    borr = 2'b00;
                end
            end
        end
    end

    // ×-баррель: mul_y[t] = sum[t - k_dn] (знак сохраняется, точно)
    logic signed [8:0] room_dn;    // e_sum + 40
    logic [5:0]  need_dn;          // 18 - P (1..18 при P<=17)
    logic signed [8:0] k_dn_s;
    assign room_dn = $signed({e_sum[7], e_sum}) + 9'sd40;
    assign need_dn = 6'd18 - P_can;
    always_comb begin
        if (!dn_small)
            k_dn_s = 9'sd0;
        else if (room_dn < $signed({2'b00, need_dn}))
            k_dn_s = (room_dn < 9'sd0) ? 9'sd0 : room_dn;
        else
            k_dn_s = $signed({2'b00, need_dn});
    end
    assign k_dn = k_dn_s[5:0];

    always_comb begin
        for (int t = 0; t < W; t++)
            mul_y[2*t +: 2] = (32'(t) >= 32'(k_dn))
                            ? sum[2*(t - k_dn) +: 2] : 2'b00;
    end

    // тернарная инверсия (переназнак после ÷ по модулю)
    logic [83:0] fq_sign;
    always_comb begin
        for (int t = 0; t < W; t++)
            fq_sign[2*t +: 2] = sum_neg
                              ? ((fq_dec[2*t +: 2] == P1) ? N1 :
                                 (fq_dec[2*t +: 2] == N1) ? P1 : 2'b00)
                              : fq_dec[2*t +: 2];
    end

    always_comb begin
        if (!p_found)                   norm_next = sum;      // sum == 0
        else if (up_big)                norm_next = fq_sign;
        else if (dn_small && k_dn != 0) norm_next = mul_y;
        else                            norm_next = sum;      // P==18 либо k_dn==0
    end

    always_comb begin
        logic signed [8:0] es9;
        if (up_big)
            es9 = $signed({e_sum[7], e_sum}) + $signed({2'b00, k_nrm});
        else if (dn_small)
            es9 = $signed({e_sum[7], e_sum}) - $signed({3'b000, k_dn});
        else
            es9 = $signed({e_sum[7], e_sum});
        e_sum_next = es9[7:0];
    end

    // ---- FSM: фиксированные 9 тактов (BUG-045: PH_NORM разбит на 2 под-фазы) ----
    // PH_NORM1: вычисление sum_abs, p_found, P_can, k_nrm, fq, corr_n1, borrow/fq_dec
    // PH_NORM2: вычисление norm_next (fq_sign/mul_y/shift) + e_sum_next
    localparam int PH_IDLE = 0;
    localparam int PH_INIT = 1;
    localparam int PH_ALGN = 2;
    localparam int PH_ADD0 = 3;
    localparam int PH_ADD1 = 4;
    localparam int PH_ADD2 = 5;
    localparam int PH_NORM1 = 6;
    localparam int PH_NORM2 = 7;
    localparam int PH_DONE = 8;

    logic [2:0] phase;
    logic signed [2:0] carry_mid0_q, carry_mid1_q;
    // ---- PH_NORM1 -> PH_NORM2: промежуточные регистры нормализации (BUG-045) ----
    logic [83:0] sum_abs_q;   // модуль суммы (для ÷-барреля в NORM2)
    logic [83:0] fq_dec_q;    // результат floor-деления (без инверсии знака)
    logic [83:0] sum_q;       // копия sum (для ×-барреля mul_y и zero-случая)
    logic        sum_neg_q;   // знак исходной sum (для инверсии fq_dec)
    logic        up_big_q;    // P >= 19
    logic        dn_small_q;  // P <= 17
    logic [5:0]  k_dn_q;      // сдвиг влево (×3^k)
    logic signed [7:0] e_sum_next_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE;
            m_big <= 0; m_small <= 0; m_big_e <= 0;
            e_sum <= 0; sum <= 0; result_q <= 0; valid_q <= 0;
            k_algn <= 0; zero_q <= 0; sat_q <= 0;
            carry_mid0_q <= 0; carry_mid1_q <= 0;
        end else begin
            valid_q <= 0;
            case (phase)
                PH_IDLE: begin
                    if (valid_in) begin
                        if (za && zb) begin           // BUG-041: 0 + 0 = 0
                            m_big   <= 84'h0;
                            m_small <= 84'h0;
                            m_big_e <= 8'sd0;
                            k_algn  <= 5'd0;
                        end else if (za) begin        // BUG-041: 0 + b = norm(b), b — big вне зависимости от e
                            m_big   <= {2'b00, b_prod};
                            m_small <= 84'h0;
                            m_big_e <= b_e;
                            k_algn  <= 5'd0;
                        end else if (zb) begin        // BUG-041: a + 0 = norm(a)
                            m_big   <= {2'b00, a_prod};
                            m_small <= 84'h0;
                            m_big_e <= a_e;
                            k_algn  <= 5'd0;
                        end else if (a_e > b_e) begin
                            m_big   <= {2'b00, a_prod};
                            m_small <= {2'b00, b_prod};
                            m_big_e <= a_e;
                            k_algn <= k_algn_c;
                        end else begin
                            m_big   <= {2'b00, b_prod};
                            m_small <= {2'b00, a_prod};
                            m_big_e <= b_e;
                            k_algn <= k_algn_c;
                        end
                        phase <= PH_INIT;
                    end
                end
                PH_INIT: begin
                    e_sum <= m_big_e;
                    phase <= PH_ALGN;
                end
                PH_ALGN: begin
                    m_small <= algn_y;      // баррель выравнивания, 1 такт
                    phase <= PH_ADD0;
                end
                PH_ADD0: begin
                    sum[27:0]       <= add_mant_sec0[27:0];     // триты 0..13
                    carry_mid0_q    <= carry_mid0;
                    phase <= PH_ADD1;
                end
                PH_ADD1: begin
                    sum[55:28]      <= add_mant_sec1[27:0];     // триты 14..27
                    carry_mid1_q    <= carry_mid1;
                    phase <= PH_ADD2;
                end
                PH_ADD2: begin
                    sum[83:56]      <= add_mant_sec2[27:0];     // триты 28..41
                    phase <= PH_NORM1;
                end
                PH_NORM1: begin
                    // вычисляем всё то же, что было в PH_NORM, но без записи sum/e_sum
                    zero_q <= !p_found;
                    sat_q  <= sat_norm;
                    sum_abs_q   <= sum_abs;
                    fq_dec_q    <= fq_dec;
                    sum_q       <= sum;
                    sum_neg_q   <= sum_neg;
                    up_big_q    <= up_big;
                    dn_small_q  <= dn_small;
                    k_dn_q      <= k_dn;
                    e_sum_next_q <= e_sum_next;
                    phase <= PH_NORM2;
                end
                PH_NORM2: begin
                    if (!sat_q) begin
                        if (up_big_q) begin
                            // инверсия и запись fq_dec
                            for (int t = 0; t < W; t++) begin
                                logic [1:0] tv;
                                tv = sum_neg_q ? ((fq_dec_q[2*t +: 2] == P1) ? N1 :
                                    (fq_dec_q[2*t +: 2] == N1) ? P1 : 2'b00) : fq_dec_q[2*t +: 2];
                                sum[2*t +: 2] <= tv;
                            end
                            e_sum <= e_sum_next_q;
                        end else if (dn_small_q && k_dn_q != 0) begin
                            for (int t = 0; t < W; t++) begin
                                logic [1:0] tv;
                                tv = (32'(t) >= 32'(k_dn_q)) ? sum_q[2*(t - k_dn_q) +: 2] : 2'b00;
                                sum[2*t +: 2] <= tv;
                            end
                            e_sum <= e_sum_next_q;
                        end
                        // elif sum == 0 / P==18: sum не меняем
                    end
                    phase <= PH_DONE;
                end
                PH_DONE: begin
                    if (zero_q)
                        result_q <= 48'h0;
                    else if (sat_q)
                        result_q <= {8'hFF, 40'hFFFFFFFFFF};
                    else if (e_sum < -8'sd40)
                        result_q <= 48'h0;
                    else
                        result_q <= {exp_code(e_sum), sum[39:0]};
                    valid_q <= 1;
                    phase <= PH_IDLE;
                end
                default: phase <= PH_IDLE;
            endcase
        end
    end

    assign valid_out = valid_q;
    assign result    = result_q;

endmodule
