// ============================================================================
// tf40_mul_pipe.sv - конвейерное умножение TFloat40 (малые стадии, DSP+LUT)
// ============================================================================
// value = M * 3^(E-60-13). Умножение:
//   M = floor(Ma*Mb / 3^13), e = ea+eb
// Стадии (каждая - регистр, маленький конус):
//   S1:  Ma*Mb (DSP48E1, 64x64)
//   S2..S14: деление на 3^13 (13 стадий /3, LUT)
//   S15..S22: нормализация к [3^13,3^14) (8 стадий, /3 или *3)
//   S23..S37: int_to_trits (15 стадий /3)
// Латентность ~37 тактов. 1 элемент/такт (конвейер заполняется).
// ============================================================================

module tf40_mul_pipe (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        s_axis_tvalid,
    input  logic [39:0] s_axis_a,
    input  logic [39:0] s_axis_b,
    output logic        m_axis_tvalid,
    output logic [39:0] m_axis_tdata
);
    import tfloat_pkg::*;

    // ---- декодирование (комбинационное от входа, малый конус) ----
    logic signed [63:0] Ma, Mb;
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

    // ---- S1: произведение (DSP) + сумма экспонент + err ----
    // M < 3^14 (~23 бита), произведение < 3^28 (~45 бит): 48 бит достаточно.
    logic signed [47:0] prod;
    logic signed [31:0]  e_sum;
    logic p_valid, p_err;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod <= 0; e_sum <= 0; p_valid <= 0; p_err <= 0;
        end else begin
            prod    <= Ma * Mb;          // DSP48E1
            e_sum   <= ea + eb;
            p_valid <= s_axis_tvalid;
            p_err   <= a_err || b_err;
        end
    end

    // ---- S2..S14: деление на 3^13 (13 стадий /3, LUT) ----
    localparam int DIVN = 13;
    logic signed [47:0] dv [0:DIVN];
    logic signed [31:0]  de [0:DIVN];
    logic        dvalid [0:DIVN];
    logic        derr [0:DIVN];

    genvar k;
    generate
        for (k = 0; k <= DIVN; k++) begin : gen_div
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    dv[k] <= 0; de[k] <= 0; dvalid[k] <= 0; derr[k] <= 0;
                end else begin
                    if (k == 0) begin
                        dv[0] <= prod; de[0] <= e_sum;
                        dvalid[0] <= p_valid; derr[0] <= p_err;
                    end else begin
                        dvalid[k] <= dvalid[k-1];
                        derr[k]   <= derr[k-1];
                        de[k]     <= de[k-1];
                        // целочисленное /3 (floor для |x|, знак сохраняется)
                        if (dv[k-1] >= 0) dv[k] <= dv[k-1] / 3;
                        else dv[k] <= -((-dv[k-1]) / 3);
                    end
                end
            end
        end
    endgenerate

    // ---- S15..S22: нормализация к [3^13, 3^14) ----
    localparam int NMN = 8;
    logic signed [47:0] nm [0:NMN];
    logic signed [31:0]  ne [0:NMN];
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
                        nm[0] <= dv[DIVN]; ne[0] <= de[DIVN];
                        nv[0] <= dvalid[DIVN]; ne_[0] <= derr[DIVN];
                    end else begin
                        nv[k] <= nv[k-1]; ne_[k] <= ne_[k-1];
                        ne[k] <= ne[k-1];
                        if (nm[k-1] >= P3_14 || nm[k-1] <= -P3_14) begin
                            if (nm[k-1] >= 0) nm[k] <= nm[k-1] / 3;
                            else nm[k] <= -((-nm[k-1]) / 3);
                            ne[k] <= ne[k-1] + 1;
                        end else if (nm[k-1] < P3_13 && nm[k-1] > -P3_13 && ne[k-1] > -E_BIAS) begin
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

    // ---- S23..S37: int_to_trits (15 стадий /3) ----
    // Триты НЕ пишутся в фиксированные позиции напрямую (при перекрытии пар
    // младшие триты были бы перезаписаны следующей парой до готовности старших).
    // Вместо этого триты путешествуют по конвейеру СДВИГОВЫМ регистром tc[stage][j]:
    // на стадии k новый (более старший) трит входит в слот TTN-1, остальные
    // сдвигаются в сторону младших. На последней стадии tc[TTN][0..14] содержат
    // ВСЕ триты одной пары, готовые одновременно и держащиеся 1 такт - это
    // гарантирует корректную синхронизацию с tv[TTN] при любой подаче.
    localparam int TTN = M_TRITS;
    logic signed [47:0] tm [0:TTN];
    logic [1:0] tc [0:TTN][0:TTN-1];
    logic        tv [0:TTN];
    logic        terr [0:TTN];
    logic signed [31:0] te [0:TTN];
    logic        tsign [0:TTN];   // знак, проведённый параллельно тритам
    logic        tzero [0:TTN];   // флаг нуля, проведённый параллельно тритам
    logic [47:0] tnm;

    always_comb tnm = (nm[NMN] >= 0) ? nm[NMN] : -nm[NMN];  // |M|

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
                        tm[0] <= tnm; tv[0] <= nv[NMN]; terr[0] <= ne_[NMN]; te[0] <= ne[NMN];
                        tsign[0] <= (nm[NMN] < 0) && (nm[NMN] != 0);
                        tzero[0] <= (nm[NMN] == 0);
                    end else begin
                        tv[kk] <= tv[kk-1]; terr[kk] <= terr[kk-1]; te[kk] <= te[kk-1];
                        tsign[kk] <= tsign[kk-1]; tzero[kk] <= tzero[kk-1];
                        // сдвиг тритов: старшие в младшие слоты, новый в TTN-1
                        for (int jj = 0; jj < TTN-1; jj++) tc[kk][jj] <= tc[kk-1][jj+1];
                        // остаток mod 3, затем /3 (balanced: r==2 -> -1, перенос)
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
            // tc[TTN][j]: j=0 младший трит, j=M_TRITS-1 старший
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
