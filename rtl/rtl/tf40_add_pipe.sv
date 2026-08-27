// ============================================================================
// tf40_add_pipe.sv - конвейерное сложение TFloat40 (малые стадии, LUT)
// ============================================================================
// value = M * 3^(E-60-13). Сложение (совпадает с tf40_add / Python _add_tf):
//   1) выравнивание: меньшая мантисса /3^k (k=|ea-eb|, round-half-up)
//   2) M_sum = Ma + Mb (выровненные), e_sum = max(ea, eb)
//   3) нормализация к [3^13, 3^14)  (вниз /3, вверх *3)
//   4) int_to_trits для мантиссы (15 стадий)
// Стадии:
//   S1:  декодирование/выбор + e_sum + k_shift
//   S2..S17: выравнивание (до 16 стадий /3 с round-half-up)
//   S18: сложение мантисс
//   S19..S34: нормализация (16 стадий /3 или *3)
//   S35..S49: int_to_trits (15 стадий /3, сдвиговый регистр тритов)
//   S50: двойной буфер пакета
//   S51..S52: финальный регистровый каскад
// Латентность ~52 такта. 1 элемент/такт.
// ============================================================================

module tf40_add_pipe (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        s_axis_tvalid,
    input  logic [39:0] s_axis_a,
    input  logic [39:0] s_axis_b,
    output logic        m_axis_tvalid,
    output logic [39:0] m_axis_tdata
);
    import tfloat_pkg::*;

    // round-half-up деление на 3 (как Python _shift_right_int для k=1)
    function automatic signed [47:0] rhu_div3(input signed [47:0] x);
        if (x >= 0) rhu_div3 = (x + 1) / 3;
        else        rhu_div3 = -((-x + 1) / 3);
    endfunction

    // ---- декодирование (комбинационное от входа, малый конус) ----
    // M < 3^14 (~23 бита), выравнивание/сумма < ~9.6M: 48 бит достаточно.
    logic signed [47:0] Ma, Mb;
    logic signed [15:0] ea, eb;
    logic a_err, b_err;
    always_comb begin
        Ma = 64'sd0;
        for (int i = M_TRITS-1; i >= 0; i--)
            Ma = Ma*3 + $signed(trit_val(s_axis_a[E_BITS + i*2 +: 2]));
    end
    always_comb begin
        Mb = 64'sd0;
        for (int i = M_TRITS-1; i >= 0; i--)
            Mb = Mb*3 + $signed(trit_val(s_axis_b[E_BITS + i*2 +: 2]));
    end
    always_comb begin
        ea = 16'sd0;
        for (int i = E_TRITS-1; i >= 0; i--)
            ea = ea*3 + $signed(trit_val(s_axis_a[i*2 +: 2]));
        ea = ea - E_BIAS;
    end
    always_comb begin
        eb = 16'sd0;
        for (int i = E_TRITS-1; i >= 0; i--)
            eb = eb*3 + $signed(trit_val(s_axis_b[i*2 +: 2]));
        eb = eb - E_BIAS;
    end
    assign a_err = (s_axis_a[0 +: 2] == TRIT_ERR) || (s_axis_a[2 +: 2] == TRIT_ERR);
    assign b_err = (s_axis_b[0 +: 2] == TRIT_ERR) || (s_axis_b[2 +: 2] == TRIT_ERR);

    // ---- S1: выбор большей экспоненты, k_shift, e_sum ----
    // выравнивание: мантисса (<= 3^14) обнуляется после <= 15 делений /3,
    // поэтому достаточно SHIFT_MAX = 16 стадий (совпадает с 64 стадиями).
    localparam int SHIFT_MAX = 16;
    logic signed [15:0] ediff;
    logic [7:0] k_shift;
    logic signed [47:0] big_m, small_m;
    logic signed [15:0] e_sum;
    always_comb begin
        ediff = (ea > eb) ? (ea - eb) : (eb - ea);
        k_shift = (ediff > SHIFT_MAX) ? SHIFT_MAX[7:0] : ediff[7:0];
        big_m   = (ea > eb) ? Ma : Mb;
        small_m = (ea > eb) ? Mb : Ma;
        e_sum   = (ea > eb) ? ea : eb;
    end
    logic        s1_valid, s1_err;
    logic [7:0]  s1_ks;
    logic signed [47:0] s1_big, s1_small;
    logic signed [15:0] s1_esum;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 0; s1_err <= 0; s1_ks <= 0;
            s1_big <= 0; s1_small <= 0; s1_esum <= 0;
        end else begin
            s1_valid <= s_axis_tvalid;
            s1_err   <= a_err || b_err;
            s1_ks    <= k_shift;
            s1_big   <= big_m;
            s1_small <= small_m;
            s1_esum  <= e_sum;
        end
    end

    // ---- S2..S17: выравнивание (round-half-up /3, до SHIFT_MAX стадий) ----
    logic signed [47:0] sm [0:SHIFT_MAX];
    logic signed [47:0] bm [0:SHIFT_MAX];
    logic [7:0] scnt [0:SHIFT_MAX];
    logic signed [15:0] es [0:SHIFT_MAX];
    logic sv [0:SHIFT_MAX];
    logic se [0:SHIFT_MAX];

    genvar k;
    generate
        for (k = 0; k <= SHIFT_MAX; k++) begin : gen_shift
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    sm[k] <= 0; bm[k] <= 0; scnt[k] <= 0; es[k] <= 0;
                    sv[k] <= 0; se[k] <= 0;
                end else begin
                    if (k == 0) begin
                        sm[0] <= s1_small; bm[0] <= s1_big; scnt[0] <= s1_ks;
                        es[0] <= s1_esum; sv[0] <= s1_valid; se[0] <= s1_err;
                    end else begin
                        sv[k] <= sv[k-1]; se[k] <= se[k-1]; es[k] <= es[k-1];
                        bm[k] <= bm[k-1];
                        if (scnt[k-1] > 0) begin
                            sm[k] <= rhu_div3(sm[k-1]);
                            scnt[k] <= scnt[k-1] - 1;
                        end else begin
                            sm[k] <= sm[k-1];
                            scnt[k] <= scnt[k-1];
                        end
                    end
                end
            end
        end
    endgenerate

    // ---- S18: сложение мантисс ----
    logic signed [47:0] M_sum;
    logic signed [15:0] esum2;
    logic        s2_valid, s2_err;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            M_sum <= 0; esum2 <= 0; s2_valid <= 0; s2_err <= 0;
        end else begin
            M_sum   <= bm[SHIFT_MAX] + sm[SHIFT_MAX];
            esum2   <= es[SHIFT_MAX];
            s2_valid <= sv[SHIFT_MAX];
            s2_err   <= se[SHIFT_MAX];
        end
    end

    // ---- S19..S34: нормализация к [3^13, 3^14) ----
    localparam int NMN = 16;
    logic signed [47:0] nm [0:NMN];
    logic signed [31:0] ne [0:NMN];
    logic        nv [0:NMN], ne_ [0:NMN];
    localparam signed [47:0] P3_13 = 48'sd1594323;
    localparam signed [47:0] P3_14 = 48'sd4782969;

    generate
        for (k = 0; k <= NMN; k++) begin : gen_norm
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    nm[k] <= 0; ne[k] <= 0; nv[k] <= 0; ne_[k] <= 0;
                end else begin
                    if (k == 0) begin
                        nm[0] <= M_sum; ne[0] <= esum2;
                        nv[0] <= s2_valid; ne_[0] <= s2_err;
                    end else begin
                        nv[k] <= nv[k-1]; ne_[k] <= ne_[k-1];
                        ne[k] <= ne[k-1];
                        if (nm[k-1] >= P3_14 || nm[k-1] <= -P3_14) begin
                            if (nm[k-1] >= 0) nm[k] <= nm[k-1] / 3;
                            else nm[k] <= -((-nm[k-1]) / 3);
                            ne[k] <= ne[k-1] + 1;
                        end else if (nm[k-1] < P3_13 && nm[k-1] > -P3_13 &&
                                     ne[k-1] > -E_BIAS) begin
                            nm[k] <= nm[k-1] + (nm[k-1] << 1);   // *3
                            ne[k] <= ne[k-1] - 1;
                        end else begin
                            nm[k] <= nm[k-1];
                        end
                    end
                end
            end
        end
    endgenerate

    // финальные флаги (комбинационно от стадии NMN)
    logic signed [47:0] Mn_f;
    logic signed [31:0] en_f;
    logic ovf_f;
    logic nvalid_f;
    always_comb begin
        Mn_f = (ne[NMN] < -E_BIAS) ? 48'sd0 : nm[NMN];
        en_f = (ne[NMN] < -E_BIAS) ? 32'sd0 : ne[NMN];
        ovf_f = (ne[NMN] > E_BIAS + 121);
    end
    assign nvalid_f = nv[NMN];

    // ---- S35..S49: int_to_trits (15 стадий /3, сдвиговый регистр тритов) ----
    localparam int TTN = M_TRITS;
    logic signed [47:0] tm [0:TTN];
    logic [1:0] tc [0:TTN][0:TTN-1];
    logic        tv [0:TTN];
    logic        terr [0:TTN];
    logic signed [31:0] te [0:TTN];
    logic        tsign [0:TTN];
    logic        tzero [0:TTN];
    logic [47:0] tnm;

    always_comb begin
        if (Mn_f >= 0) tnm = Mn_f;
        else           tnm = -Mn_f;
    end

    genvar kk;
    generate
        for (kk = 0; kk <= TTN; kk++) begin : gen_tt
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    tm[kk] <= 0; tv[kk] <= 0; terr[kk] <= 0; te[kk] <= 0;
                    tsign[kk] <= 0; tzero[kk] <= 0;
                    for (int jj = 0; jj < TTN; jj++) tc[kk][jj] <= 0;
                end else begin
                    if (kk == 0) begin
                        tm[0] <= tnm; tv[0] <= nvalid_f;
                        terr[0] <= ne_[NMN] || ovf_f;
                        te[0] <= en_f;
                        tsign[0] <= (Mn_f < 0) && (Mn_f != 0);
                        tzero[0] <= (Mn_f == 0);
                    end else begin
                        tv[kk] <= tv[kk-1]; terr[kk] <= terr[kk-1]; te[kk] <= te[kk-1];
                        tsign[kk] <= tsign[kk-1]; tzero[kk] <= tzero[kk-1];
                        for (int jj = 0; jj < TTN-1; jj++) tc[kk][jj] <= tc[kk-1][jj+1];
                        if ((tm[kk-1] % 3) == 2) begin
                            tc[kk][TTN-1] <= TRIT_N1;
                            tm[kk] <= (tm[kk-1] + 1) / 3;
                        end else if ((tm[kk-1] % 3) == 1) begin
                            tc[kk][TTN-1] <= TRIT_P1;
                            tm[kk] <= tm[kk-1] / 3;
                        end else begin
                            tc[kk][TTN-1] <= TRIT_0;
                            tm[kk] <= tm[kk-1] / 3;
                        end
                    end
                end
            end
        end
    endgenerate

    // ---- упаковка (комбинационно от конца конвейера tc[TTN]/te[TTN]) ----
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
    assign err_out = terr[TTN] || (te[TTN] > E_BIAS + 121);

    genvar j;
    generate
        for (j = 0; j < M_TRITS; j++) begin : gen_pack_m
            assign m_trits[j*2 +: 2] = (sign_out) ?
                (tc[TTN][j] == TRIT_P1 ? TRIT_N1 : (tc[TTN][j] == TRIT_N1 ? TRIT_P1 : TRIT_0))
                : tc[TTN][j];
        end
    endgenerate

    int_to_trits #(.N(E_TRITS), .W(32)) u_e (.value(te[TTN] + E_BIAS), .trits(e_trits));

    always_comb begin
        if (err_out)          out_data = {TOTAL_TRITS{2'b11}};
        else if (tzero[TTN])  out_data = {TOTAL_TRITS{2'b00}};
        else                  out_data = {m_trits, e_trits};
    end

    // ---- финальный регистровый каскад (синхронизация выдачи) ----
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
