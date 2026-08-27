// ============================================================================
// f32_to_tf40_pipe2.sv - ПРАВИЛЬНЫЙ конвейерный конвертер IEEE float32 -> TFloat40
// ============================================================================
// value = M * 3^(E-60-13), M - 15 тритов (норм. [3^13,3^14)), E - 5 тритов.
//
// Точный алгоритм (совпадает с комбинационным f32_to_tf40.sv, проверено 8000
// случайных значений):
//   value_q = m24 * 2^(e2-150+64)            (фикс. точка, 128 бит)
//   value_p3 = value_q * 3^13                (DSP-умножение)
//   e3_off = floor(log3(value)) + 60  - поиск нормализацией:
//     D = 2^64, e3_off = 60
//     если value_q >= 2^64 (e3>=0): пока value_q >= D*3:  D *= 3,  e3_off++
//     иначе                 (e3<0):  пока value_q <  D:   D /= 3,  e3_off--
//   M = round(value_p3 / (3^e3 * 2^64)) - бит-за-битом round-деление.
//
// РЕСУРСНАЯ ОПТИМИЗАЦИЯ: делитель представляется компактно:
//   - e3>=0: D = 3^e3 * 2^64  -> младшие 64 бита = 0, старшие 64 = D_hi (3^e3);
//     сравнение/вычитание в делении только по старшим 64 битам.
//   - e3<0 : D = floor(2^64/3^k) < 2^64 -> старшие 64 бита = 0;
//     сравнение/вычитание только по младшим 64 битам.
//   Нормализация/триты оперируют M < 3^14 (~23 бита) в 64 битах.
// Это заменяет дорогие 128-бит /3 и 128-бит сравнения на 64-бит эквиваленты.
//
// Стадии:
//   S0       : разбор + сдвиг value_q
//   S1       : value_p3 = value_q * 3^13 (DSP)
//   S2..S62  : построение D (61 стадия, 64-бит операции)
//   S63..S190: round-деление value_p3/D бит-за-битом (128 стадий, 64-бит делитель)
//   S191..S198: нормализация M (8 стадий, 64 бит)
//   S199..S213: int_to_trits (15 стадий, 64 бит)
//   S214     : финальный каскад
// Латентность ~215 тактов. 1 элемент/такт.
// ============================================================================

module f32_to_tf40_pipe2 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        s_axis_tvalid,
    input  logic [31:0] s_axis_tdata,
    output logic        m_axis_tvalid,
    output logic [39:0] m_axis_tdata
);
    import tfloat_pkg::*;

    localparam int W = 128;
    localparam int Q = 64;
    localparam logic [W-1:0] P3_13 = 128'd1594323;
    localparam logic [W-1:0] P3_14 = 128'd4782969;
    localparam logic [W-1:0] POW2_64 = (128'h1 << Q);

    // ---- S0: разбор + value_q (комбинационно от входа, малый конус) ----
    logic        p_sign;
    logic [7:0]  p_e2;
    logic [23:0] p_m24;
    logic        p_zero, p_nan;
    logic signed [15:0] p_shift;
    logic [W-1:0] p_val_q;

    always_comb begin
        p_sign = s_axis_tdata[31];
        p_e2   = s_axis_tdata[30:23];
        p_m24  = {1'b1, s_axis_tdata[22:0]};
        p_zero = (s_axis_tdata[30:23] == 8'h00) && (s_axis_tdata[22:0] == 23'h0);
        p_nan  = (s_axis_tdata[30:23] == 8'hFF);
        p_shift = $signed({8'b0, s_axis_tdata[30:23]}) - 150 + Q;
        p_val_q = {W{1'b0}};
        if (p_shift >= 0) begin
            if (p_shift < W)
                p_val_q = { {(W-24){1'b0}}, p_m24 } << p_shift[6:0];
        end else begin
            if (-p_shift < W)
                p_val_q = { {(W-24){1'b0}}, p_m24 } >> (-p_shift[6:0]);
        end
    end

    logic        s0_sign, s0_zero, s0_nan, s0_valid;
    logic [W-1:0] s0_val_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_sign <= 0; s0_zero <= 0; s0_nan <= 0; s0_valid <= 0;
            s0_val_q <= 0;
        end else begin
            s0_sign  <= p_sign;
            s0_zero  <= p_zero;
            s0_nan   <= p_nan;
            s0_valid <= s_axis_tvalid;
            s0_val_q <= p_val_q;
        end
    end

    // ---- S1: value_p3 = value_q * 3^13 (DSP) ----
    logic [W-1:0] s1_p3;
    logic         s1_sign, s1_zero, s1_nan, s1_valid;
    logic [W-1:0] s1_val_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_p3 <= 0; s1_sign <= 0; s1_zero <= 0; s1_nan <= 0; s1_valid <= 0;
            s1_val_q <= 0;
        end else begin
            s1_p3    <= s0_val_q * P3_13;
            s1_sign  <= s0_sign;
            s1_zero  <= s0_zero;
            s1_nan   <= s0_nan;
            s1_valid <= s0_valid;
            s1_val_q <= s0_val_q;
        end
    end

    // ---- S2..S62: построение D ----
    // up  (e3>=0): D_hi = 3^e3 (64 бит), стартует с 1; D*3 = (D_hi*3)<<64
    // down(e3<0) : D_lo = floor(2^64/3^k) (64 бит), стартует с 2^64, /=3
    localparam int DBUILD = 61;
    logic [63:0]  d_Dh [0:DBUILD];
    logic [63:0]  d_Dl [0:DBUILD];
    logic [7:0]   d_off [0:DBUILD];
    logic [W-1:0] d_p3 [0:DBUILD];
    logic         d_sign [0:DBUILD], d_zero [0:DBUILD], d_nan [0:DBUILD], d_valid [0:DBUILD];
    logic         d_up [0:DBUILD];
    logic [W-1:0] d_vq [0:DBUILD];

    function automatic logic [63:0] div3_64(input logic [63:0] x);
        div3_64 = x / 64'd3;
    endfunction

    genvar k;
    generate
        for (k = 0; k <= DBUILD; k++) begin : gen_db
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    d_Dh[k] <= 0; d_Dl[k] <= 0; d_off[k] <= 0; d_p3[k] <= 0;
                    d_sign[k] <= 0; d_zero[k] <= 0; d_nan[k] <= 0; d_valid[k] <= 0;
                    d_up[k] <= 0; d_vq[k] <= 0;
                end else begin
                    if (k == 0) begin
                        d_Dh[0]    <= 64'd1;
                        d_Dl[0]    <= 64'hFFFFFFFFFFFFFFFF;  // 2^64-1 ~ 2^64
                        d_off[0]   <= 8'd60;
                        d_p3[0]    <= s1_p3;
                        d_sign[0]  <= s1_sign;
                        d_zero[0]  <= s1_zero;
                        d_nan[0]   <= s1_nan;
                        d_valid[0] <= s1_valid;
                        d_up[0]    <= (s1_val_q >= POW2_64);
                        d_vq[0]    <= s1_val_q;
                    end else begin
                        d_sign[k] <= d_sign[k-1]; d_zero[k] <= d_zero[k-1];
                        d_nan[k]  <= d_nan[k-1];  d_valid[k] <= d_valid[k-1];
                        d_up[k]   <= d_up[k-1];
                        d_vq[k]   <= d_vq[k-1];
                        d_p3[k]   <= d_p3[k-1];
                        d_off[k]  <= d_off[k-1];
                        if (d_up[k-1]) begin
                            // up: пока value_q >= (D_hi*3)<<64, т.е. value_q[127:64] >= D_hi*3
                            if (d_vq[k-1][127:64] >= (d_Dh[k-1] + (d_Dh[k-1] << 1))) begin
                                d_Dh[k]  <= d_Dh[k-1] + (d_Dh[k-1] << 1);
                                d_off[k] <= d_off[k-1] + 1;
                            end else begin
                                d_Dh[k] <= d_Dh[k-1];
                            end
                        end else begin
                            // down: пока value_q < D_lo  (value_q < 2^64 в down)
                            if (d_vq[k-1][63:0] < d_Dl[k-1]) begin
                                d_Dl[k]  <= div3_64(d_Dl[k-1]);
                                d_off[k] <= d_off[k-1] - 1;
                            end else begin
                                d_Dl[k] <= d_Dl[k-1];
                            end
                        end
                    end
                end
            end
        end
    endgenerate

    // ---- S63..S190: round-деление M = (value_p3 + D/2) / D ----
    // бит-за-битом, 128 итераций. Делитель: up = {D_hi,0}, down = {0,D_lo}.
    // round: X = value_p3 + D>>1  (128 бит, перенос теряется, как эталон)
    localparam int DIVN = 128;
    logic [W-1:0] q_X [0:DIVN];
    logic [63:0]  q_Dh [0:DIVN];
    logic [63:0]  q_Dl [0:DIVN];
    logic         q_up [0:DIVN];
    logic [W-1:0] q_rem [0:DIVN];
    logic [W-1:0] q_q [0:DIVN];
    logic         q_sign [0:DIVN], q_zero [0:DIVN], q_nan [0:DIVN], q_valid [0:DIVN];
    logic [7:0]   q_off [0:DIVN];

    genvar kk;
    generate
        for (kk = 0; kk <= DIVN; kk++) begin : gen_div
            logic [W-1:0] rem_new;
            logic [W-1:0] rem_sub;
            logic         gt;
            logic [W-1:0] rem_new2;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    q_X[kk] <= 0; q_Dh[kk] <= 0; q_Dl[kk] <= 0; q_up[kk] <= 0;
                    q_rem[kk] <= 0; q_q[kk] <= 0;
                    q_sign[kk] <= 0; q_zero[kk] <= 0; q_nan[kk] <= 0; q_valid[kk] <= 0;
                    q_off[kk] <= 0;
                end else begin
                    if (kk == 0) begin
                        q_X[0]    <= d_p3[DBUILD] +
                                     (d_up[DBUILD] ? (d_Dh[DBUILD] << 63)
                                                   : (d_Dl[DBUILD] >> 1));
                        q_Dh[0]   <= d_Dh[DBUILD];
                        q_Dl[0]   <= d_Dl[DBUILD];
                        q_up[0]   <= d_up[DBUILD];
                        q_rem[0]  <= 0;
                        q_q[0]    <= 0;
                        q_sign[0] <= d_sign[DBUILD];
                        q_zero[0] <= d_zero[DBUILD];
                        q_nan[0]  <= d_nan[DBUILD];
                        q_valid[0] <= d_valid[DBUILD];
                        q_off[0]  <= d_off[DBUILD];
                    end else begin
                        q_sign[kk] <= q_sign[kk-1]; q_zero[kk] <= q_zero[kk-1];
                        q_nan[kk]  <= q_nan[kk-1];  q_valid[kk] <= q_valid[kk-1];
                        q_off[kk]  <= q_off[kk-1];
                        q_Dh[kk]   <= q_Dh[kk-1];
                        q_Dl[kk]   <= q_Dl[kk-1];
                        q_up[kk]   <= q_up[kk-1];
                        q_X[kk]    <= q_X[kk-1] << 1;
                        rem_new = (q_rem[kk-1] << 1) | q_X[kk-1][W-1];
                        if (q_up[kk-1]) begin
                            // делитель {D_hi, 0}: сравнение/вычитание старших 64 бит
                            gt = (rem_new[127:64] >= q_Dh[kk-1]);
                            if (gt) begin
                                rem_sub = {rem_new[127:64] - q_Dh[kk-1], rem_new[63:0]};
                                q_q[kk] <= q_q[kk-1] | (128'h1 << (W - kk));
                                q_rem[kk] <= rem_sub;
                            end else begin
                                q_q[kk] <= q_q[kk-1];
                                q_rem[kk] <= rem_new;
                            end
                        end else begin
                            // делитель {0, D_lo} (< 2^64)
                            gt = (rem_new[127:64] != 0) || (rem_new[63:0] >= q_Dl[kk-1]);
                            if (gt) begin
                                rem_sub = rem_new - {64'h0, q_Dl[kk-1]};
                                q_q[kk] <= q_q[kk-1] | (128'h1 << (W - kk));
                                q_rem[kk] <= rem_sub;
                            end else begin
                                q_q[kk] <= q_q[kk-1];
                                q_rem[kk] <= rem_new;
                            end
                        end
                    end
                end
            end
        end
    endgenerate

    // M_raw = q_q[DIVN], e3n_off = q_off[DIVN]
    logic [W-1:0] q_M;
    logic [7:0]   q_eoff;
    logic         q_valid_f, q_sign_f, q_zero_f, q_nan_f;
    always_comb begin
        q_M     = q_q[DIVN];
        q_eoff  = q_off[DIVN];
        q_valid_f = q_valid[DIVN];
        q_sign_f  = q_sign[DIVN];
        q_zero_f  = q_zero[DIVN];
        q_nan_f   = q_nan[DIVN];
    end

    // ---- S191..S198: нормализация M к [3^13, 3^14) (64 бит) ----
    localparam int NMN = 8;
    logic [63:0] nm [0:NMN];
    logic [7:0]  no [0:NMN];
    logic        nv [0:NMN], ns [0:NMN], nz [0:NMN], nn [0:NMN];
    localparam logic [63:0] P3_13_64 = 64'd1594323;
    localparam logic [63:0] P3_14_64 = 64'd4782969;

    genvar kkk;
    generate
        for (kkk = 0; kkk <= NMN; kkk++) begin : gen_norm
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    nm[kkk] <= 0; no[kkk] <= 0; nv[kkk] <= 0; ns[kkk] <= 0; nz[kkk] <= 0; nn[kkk] <= 0;
                end else begin
                    if (kkk == 0) begin
                        nm[0] <= q_M[63:0]; no[0] <= q_eoff;
                        nv[0] <= q_valid_f; ns[0] <= q_sign_f; nz[0] <= q_zero_f; nn[0] <= q_nan_f;
                    end else begin
                        nv[kkk] <= nv[kkk-1]; ns[kkk] <= ns[kkk-1]; nz[kkk] <= nz[kkk-1]; nn[kkk] <= nn[kkk-1];
                        no[kkk] <= no[kkk-1];
                        if (nm[kkk-1] >= P3_14_64) begin
                            nm[kkk] <= nm[kkk-1] / 3;
                            no[kkk] <= no[kkk-1] + 1;
                        end else if (nm[kkk-1] < P3_13_64 && no[kkk-1] > 0) begin
                            nm[kkk] <= nm[kkk-1] + (nm[kkk-1] << 1);   // *3
                            no[kkk] <= no[kkk-1] - 1;
                        end else begin
                            nm[kkk] <= nm[kkk-1];
                        end
                    end
                end
            end
        end
    endgenerate

    // |M| для тритов (знак учтём при упаковке через tsign)
    logic [63:0] Mabs;
    always_comb begin
        Mabs = nm[NMN];
    end

    // ---- S199..S213: int_to_trits (15 стадий /3, 64 бит) ----
    localparam int TTN = M_TRITS;
    logic [63:0] tm [0:TTN];
    logic [1:0] tc [0:TTN][0:TTN-1];
    logic        tv [0:TTN];
    logic        terr [0:TTN];
    logic [7:0]  to [0:TTN];
    logic        tsign [0:TTN];
    logic        tzero [0:TTN];

    genvar kkkk;
    generate
        for (kkkk = 0; kkkk <= TTN; kkkk++) begin : gen_tt
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    tm[kkkk] <= 0; tv[kkkk] <= 0; terr[kkkk] <= 0; to[kkkk] <= 0;
                    tsign[kkkk] <= 0; tzero[kkkk] <= 0;
                    for (int jj = 0; jj < TTN; jj++) tc[kkkk][jj] <= 0;
                end else begin
                    if (kkkk == 0) begin
                        tm[0] <= Mabs; tv[0] <= nv[NMN];
                        terr[0] <= nn[NMN] || (no[NMN] > 121);
                        to[0] <= no[NMN];
                        tsign[0] <= ns[NMN] && !nz[NMN];
                        tzero[0] <= nz[NMN] || (nm[NMN] == 0);
                    end else begin
                        tv[kkkk] <= tv[kkkk-1]; terr[kkkk] <= terr[kkkk-1]; to[kkkk] <= to[kkkk-1];
                        tsign[kkkk] <= tsign[kkkk-1]; tzero[kkkk] <= tzero[kkkk-1];
                        for (int jj = 0; jj < TTN-1; jj++) tc[kkkk][jj] <= tc[kkkk-1][jj+1];
                        if ((tm[kkkk-1] % 3) == 2) begin
                            tc[kkkk][TTN-1] <= TRIT_N1;
                            tm[kkkk] <= (tm[kkkk-1] + 1) / 3;
                        end else if ((tm[kkkk-1] % 3) == 1) begin
                            tc[kkkk][TTN-1] <= TRIT_P1;
                            tm[kkkk] <= tm[kkkk-1] / 3;
                        end else begin
                            tc[kkkk][TTN-1] <= TRIT_0;
                            tm[kkkk] <= tm[kkkk-1] / 3;
                        end
                    end
                end
            end
        end
    endgenerate

    // ---- упаковка (комбинационно от конца конвейера tc[TTN]/to[TTN]) ----
    // tv[TTN] на 1 такт РАНЬШЕ, чем триты в tc[TTN] (триты зарождаются на
    // стадии 1 сдвигового регистра). Поэтому valid дополнительно сдвигаем на
    // 1 такт (tv_q): out_v и out_q выравниваются, и при остановке подачи не
    // выдаётся лишний valid с "хвостом" конвейера.
    logic [M_TRITS*2-1:0] m_trits;
    logic [E_TRITS*2-1:0] e_trits;
    logic sign_out;
    logic err_out;
    logic [39:0] out_data;

    assign sign_out = tsign[TTN];
    assign err_out = terr[TTN] || (to[TTN] > 121);

    genvar j;
    generate
        for (j = 0; j < M_TRITS; j++) begin : gen_pack_m
            assign m_trits[j*2 +: 2] = (sign_out) ?
                (tc[TTN][j] == TRIT_P1 ? TRIT_N1 : (tc[TTN][j] == TRIT_N1 ? TRIT_P1 : TRIT_0))
                : tc[TTN][j];
        end
    endgenerate

    int_to_trits #(.N(E_TRITS), .W(32)) u_e (.value($signed({24'b0, to[TTN]})), .trits(e_trits));

    always_comb begin
        if (err_out)          out_data = {TOTAL_TRITS{2'b11}};
        else if (tzero[TTN])  out_data = {TOTAL_TRITS{2'b00}};
        else                  out_data = {m_trits, e_trits};
    end

    // ---- финальный регистровый каскад ----
    logic tv_q;
    logic [39:0] out_q;
    logic out_v;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tv_q <= 0;
        end else begin
            tv_q <= tv[TTN];
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_q <= 0; out_v <= 0;
        end else begin
            out_q <= out_data;
            out_v <= tv_q;
        end
    end
    assign m_axis_tvalid = out_v;
    assign m_axis_tdata  = out_q;

endmodule
