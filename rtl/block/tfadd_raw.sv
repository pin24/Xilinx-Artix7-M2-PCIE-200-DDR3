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
        logic signed [7:0] x;
        logic [7:0] out;
        x = v;
        for (int i = 0; i < 4; i++) begin
            logic signed [7:0] q;
            logic signed [2:0] rv;
            logic [1:0] rcode;
            q = x / 3;
            rv = x - 3*q;
            if (rv == 2) begin rcode = 2'b10; q = q + 1; end
            else if (rv == -2) begin rcode = 2'b01; q = q - 1; end
            else if (rv == 1) rcode = 2'b01;
            else if (rv == -1) rcode = 2'b10;
            else rcode = 2'b00;
            out[2*i +: 2] = rcode;
            x = q;
        end
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

    // ---- ALGN баррель: чистый сбалансированный сдвиг на k_algn (nearest) ----
    logic [2*W-1:0] algn_y;
    always_comb begin
        for (int t = 0; t < W; t++)
            algn_y[2*t +: 2] = (t + k_algn <= W-1)
                             ? m_small[2*(t + k_algn) +: 2] : 2'b00;
    end

    // ---- ADD: поразрядное сложение m_big + m_small (42 трита, как в serial) ----
    logic [2*W-1:0] add_mant;
    always_comb begin
        logic signed [2:0] carry;
        carry = 3'sd0;
        for (int t = 0; t < W; t++) begin
            logic signed [2:0] sv;
            sv = trit_val2(m_big[2*t +: 2]) + trit_val2(m_small[2*t +: 2]) + carry;
            if (sv > 1) begin
                carry = 3'sd1;
                add_mant[2*t +: 2] = int2trit2(sv - 3);
            end else if (sv < -1) begin
                carry = -3'sd1;
                add_mant[2*t +: 2] = int2trit2(sv + 3);
            end else begin
                carry = 3'sd0;
                add_mant[2*t +: 2] = int2trit2(sv);
            end
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

    // ---- FSM: фиксированные 6 тактов ----
    localparam int PH_IDLE = 0;
    localparam int PH_INIT = 1;
    localparam int PH_ALGN = 2;
    localparam int PH_ADD  = 3;
    localparam int PH_NORM = 4;
    localparam int PH_DONE = 5;

    logic [2:0] phase;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE;
            m_big <= 0; m_small <= 0; m_big_e <= 0;
            e_sum <= 0; sum <= 0; result_q <= 0; valid_q <= 0;
            k_algn <= 0; zero_q <= 0; sat_q <= 0;
        end else begin
            valid_q <= 0;
            case (phase)
                PH_IDLE: begin
                    if (valid_in) begin
                        if (a_e > b_e) begin
                            m_big   <= {2'b00, a_prod};
                            m_small <= {2'b00, b_prod};
                            m_big_e <= a_e;
                        end else begin
                            m_big   <= {2'b00, b_prod};
                            m_small <= {2'b00, a_prod};
                            m_big_e <= b_e;
                        end
                        k_algn <= k_algn_c;
                        phase <= PH_INIT;
                    end
                end
                PH_INIT: begin
                    e_sum <= m_big_e;
                    phase <= PH_ALGN;
                end
                PH_ALGN: begin
                    m_small <= algn_y;      // баррель выравнивания, 1 такт
                    phase <= PH_ADD;
                end
                PH_ADD: begin
                    sum <= add_mant;        // 42-тритная сумма, 1 такт
                    phase <= PH_NORM;
                end
                PH_NORM: begin
                    zero_q <= !p_found;
                    sat_q  <= sat_norm;
                    if (!sat_norm) begin
                        sum   <= norm_next;
                        e_sum <= e_sum_next;
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
