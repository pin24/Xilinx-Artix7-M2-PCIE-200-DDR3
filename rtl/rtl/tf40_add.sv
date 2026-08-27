// ============================================================================
// tf40_add.sv - сложение TFloat40 (проверенная логика из tf40_alu)
// ============================================================================
module tf40_add (
    input  logic [39:0] a,
    input  logic [39:0] b,
    output logic [39:0] result,
    output logic        err_out
);
    import tfloat_pkg::*;
    logic [M_TRITS*2-1:0] a_m, b_m;
    logic [E_TRITS*2-1:0] a_e, b_e;
    assign a_m = a[TOTAL_BITS-1 : E_BITS];
    assign b_m = b[TOTAL_BITS-1 : E_BITS];
    assign a_e = a[E_BITS-1 : 0];
    assign b_e = b[E_BITS-1 : 0];

    logic signed [63:0] Ma, Mb;
    always_comb begin
        Ma = 64'sd0;
        for (int i = M_TRITS-1; i >= 0; i--)
            Ma = Ma*3 + $signed(trit_val(a_m[i*2 +: 2]));
    end
    always_comb begin
        Mb = 64'sd0;
        for (int i = M_TRITS-1; i >= 0; i--)
            Mb = Mb*3 + $signed(trit_val(b_m[i*2 +: 2]));
    end
    logic signed [15:0] ea, eb;
    always_comb begin
        ea = 16'sd0;
        for (int i = E_TRITS-1; i >= 0; i--)
            ea = ea*3 + $signed(trit_val(a_e[i*2 +: 2]));
        ea = ea - E_BIAS;
    end
    always_comb begin
        eb = 16'sd0;
        for (int i = E_TRITS-1; i >= 0; i--)
            eb = eb*3 + $signed(trit_val(b_e[i*2 +: 2]));
        eb = eb - E_BIAS;
    end

    logic a_err, b_err;
    assign a_err = (a[0 +: 2] == TRIT_ERR) || (a[2 +: 2] == TRIT_ERR);
    assign b_err = (b[0 +: 2] == TRIT_ERR) || (b[2 +: 2] == TRIT_ERR);

    // выравнивание экспонент (Python _shift_right_int с round)
    logic [7:0] k_shift;
    assign k_shift = (ea > eb) ? ((ea-eb) > 64 ? 64 : (ea-eb)) :
                     ((eb-ea) > 64 ? 64 : (eb-ea));

    logic signed [63:0] sh_work, Ma_sh, Mb_sh;
    logic signed [15:0] e_sum;
    always_comb begin
        sh_work = (ea > eb) ? Mb : Ma;
        for (int i = 0; i < 64; i++) begin
            if (i < k_shift) begin
                // round-half-up деление на 3 (как Python _shift_right_int)
                if (sh_work >= 0) sh_work = (sh_work + 1) / 3;
                else sh_work = -(((-sh_work) + 1) / 3);
            end
        end
        Ma_sh = (ea > eb) ? Ma : sh_work;
        Mb_sh = (ea > eb) ? sh_work : Mb;
        e_sum = (ea > eb) ? ea : eb;
    end

    logic signed [63:0] M_sum;
    always_comb M_sum = Ma_sh + Mb_sh;

    // нормализация
    logic signed [127:0] Mn;
    logic signed [31:0]  en;
    logic ovf;
    logic [M_TRITS*2-1:0] m_out;
    logic [E_TRITS*2-1:0] e_out;
    localparam signed [127:0] P3_13 = 128'sd1594323;
    localparam signed [127:0] P3_14 = 128'sd4782969;
    always_comb begin
        Mn = $signed({{64{M_sum[63]}}, M_sum});
        en = e_sum;
        ovf = 0;
        if (Mn != 0) begin
            for (int i = 0; i < 64; i++) begin
                if (Mn >= P3_14 || Mn <= -P3_14) begin
                    if (Mn >= 0) Mn = Mn / 3; else Mn = -((-Mn)/3);
                    en = en + 1;
                end
            end
            for (int i = 0; i < 64; i++) begin
                if (Mn < P3_13 && Mn > -P3_13 && en > -E_BIAS) begin
                    Mn = Mn * 3; en = en - 1;
                end
            end
            if (en > E_BIAS + 121) ovf = 1;
            if (en < -E_BIAS) begin Mn = 0; en = 0; end
        end
    end
    int_to_trits #(.N(M_TRITS), .W(128)) u_m (.value(Mn[127:0]), .trits(m_out));
    int_to_trits #(.N(E_TRITS), .W(32))  u_e (.value(en[31:0]+E_BIAS), .trits(e_out));

    logic err_sel;
    assign err_sel = a_err || b_err || ovf;
    always_comb begin
        if (err_sel)      result = {TOTAL_TRITS{2'b11}};
        else if (Mn == 0) result = {TOTAL_TRITS{2'b00}};
        else              result = {m_out, e_out};
    end
    assign err_out = err_sel;
endmodule
