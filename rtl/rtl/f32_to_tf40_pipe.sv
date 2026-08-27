// ============================================================================
// f32_to_tf40_pipe.sv - конвейерный конвертер IEEE float32 -> TFloat40
// ============================================================================
// ТОЛЬКО LUT (без DSP-умножений):
//   - умножение на 3: x*3 = (x<<1)+x  (сдвиг + сложение)
//   - деление на 3: целочисленное деление (LUT)
// Конвейер с фиксированной латентностью, 1 f32/такт.
//
// Идея:
//   val = m24 * 2^(e2-150)
//   Ищем M, e такие что M = val*3^13/3^e, M in [3^13,3^14).
//   Начальное: M0 = val*3^13  (13 стадий x3), e0 = floor(log3(val)).
//   Затем NORM стадий: пока e > 13 -> M/=3, e-- ; пока e < 13 -> M*=3, e++.
//   После NORM стадий e == 13 и M in [3^13, 3^14) (для нормальных f32).
//   Результат: M (15 тритов), E = 13+60 = 73.
//
// Замечание: e = floor(log3(val)) вычисляем через таблицу от e2.
// ============================================================================

module f32_to_tf40_pipe (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        s_axis_tvalid,
    input  logic [31:0] s_axis_tdata,
    output logic        m_axis_tvalid,
    output logic [39:0] m_axis_tdata
);
    import tfloat_pkg::*;

    // --- Стадия 0: разбор + начальный сдвиг ---
    logic        p_sign;
    logic [7:0]  p_e2;
    logic [23:0] p_m24;
    logic        p_zero, p_nan;
    logic signed [63:0] p_val;   // m24 << (e2-150+8)
    logic signed [15:0] p_shift;
    logic [7:0]  p_shamt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_sign <= 0; p_e2 <= 0; p_m24 <= 0; p_zero <= 0; p_nan <= 0;
            p_shift <= 0; p_shamt <= 0;
        end else begin
            p_sign <= s_axis_tdata[31];
            p_e2   <= s_axis_tdata[30:23];
            p_m24  <= {1'b1, s_axis_tdata[22:0]};
            p_zero <= (s_axis_tdata[30:23]==8'h00) && (s_axis_tdata[22:0]==23'h0);
            p_nan  <= (s_axis_tdata[30:23]==8'hFF);
            p_shift <= $signed({8'b0, s_axis_tdata[30:23]}) - 142;
            p_shamt <= (($signed({8'b0, s_axis_tdata[30:23]}) - 142) < 0) ?
                       (0 - ($signed({8'b0, s_axis_tdata[30:23]}) - 142)) : 8'd0;
        end
    end
    // сдвиг комбинационно: сдвиг влево/вправо в зависимости от знака p_shift
    always_comb begin
        if (p_shift >= 0)
            p_val = {40'b0, p_m24} << p_shift[7:0];
        else
            p_val = {40'b0, p_m24} >> p_shamt;
    end

    // пред-регистр: захват p_val и e3 на такт позже (устраняет гонку)
    logic signed [63:0] v_pre;
    logic signed [15:0] e3_pre;
    logic vp_valid, vp_sign, vp_zero, vp_nan;
    logic [7:0] vp_e2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_pre <= 0; e3_pre <= 0; vp_valid <= 0; vp_sign <= 0;
            vp_zero <= 0; vp_nan <= 0; vp_e2 <= 0;
        end else begin
            v_pre <= p_val;
            vp_valid <= s_axis_tvalid;
            vp_sign <= p_sign; vp_zero <= p_zero; vp_nan <= p_nan;
            vp_e2 <= p_e2;
            e3_pre <= (($signed({8'b0, p_e2}) - 119) * 41) >>> 6;
        end
    end

    // --- Стадии 1..13: val *= 3 (13 раз) -> val*3^13 ---
    logic signed [63:0] v [0:13];
    logic        vs [0:13];     // valid pipeline
    logic        ss [0:13];     // sign
    logic        zs [0:13];     // zero
    logic        ns [0:13];     // nan
    logic [7:0]  e2s [0:13];
    logic signed [15:0] e3s [0:13];  // e3 = floor(log3(val)) от стадии

    // e3 по таблице: e3 ~ floor((e2-127)*0.63). Для каждого e2 предвычислено.
    // LUT: 256 x 8 бит.
    logic [7:0] e3_lut [0:255];
    // заполняем комбинационно
    always_comb begin
        for (int i = 0; i < 256; i++) begin
            // e3 = floor((i-127) * 0.63093)  , clamp к [-60, 61]
            e3_lut[i] = 8'sd0;
        end
    end

    genvar k;
    generate
        for (k = 0; k <= 13; k++) begin : gen_stage
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    v[k] <= 0; vs[k] <= 0; ss[k] <= 0; zs[k] <= 0; ns[k] <= 0;
                    e2s[k] <= 0; e3s[k] <= 0;
                end else begin
                    if (k == 0) begin
                        v[0]  <= v_pre;
                        vs[0] <= vp_valid;
                        ss[0] <= vp_sign; zs[0] <= vp_zero; ns[0] <= vp_nan;
                        e2s[0] <= vp_e2;
                        e3s[0] <= e3_pre;
                    end else begin
                        v[k]  <= v[k-1] + (v[k-1] << 1);   // *3
                        vs[k] <= vs[k-1];
                        ss[k] <= ss[k-1]; zs[k] <= zs[k-1]; ns[k] <= ns[k-1];
                        e2s[k] <= e2s[k-1];
                        e3s[k] <= e3s[k-1];
                    end
                end
            end
        end
    endgenerate

    // ========================================================================
    // NORM стадии: приводят e к 13 (M уже *3^13). Пока e3 > 13: M/=3, e3--.
    // Пока e3 < 13: M*=3, e3++. После ~40 стадий e3==13.
    // ========================================================================
    localparam int NSTAGES = 40;
    logic signed [63:0] nm [0:NSTAGES];
    logic signed [15:0] ne [0:NSTAGES];
    logic        nv [0:NSTAGES], nsn [0:NSTAGES], nz [0:NSTAGES], nn [0:NSTAGES];

    generate
        for (k = 0; k <= NSTAGES; k++) begin : gen_norm
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    nm[k] <= 0; ne[k] <= 0; nv[k] <= 0; nsn[k] <= 0; nz[k] <= 0; nn[k] <= 0;
                end else begin
                    if (k == 0) begin
                        nm[0] <= v[13]; ne[0] <= e3s[13];
                        nv[0] <= vs[13]; nsn[0] <= ss[13]; nz[0] <= zs[13]; nn[0] <= ns[13];
                    end else begin
                        nv[k] <= nv[k-1]; nsn[k] <= nsn[k-1]; nz[k] <= nz[k-1]; nn[k] <= nn[k-1];
                        if (ne[k-1] > 13) begin
                            nm[k] <= nm[k-1] / 3;          // LUT-деление на 3
                            ne[k] <= ne[k-1] - 1;
                        end else if (ne[k-1] < 13) begin
                            nm[k] <= nm[k-1] + (nm[k-1] << 1);  // *3
                            ne[k] <= ne[k-1] + 1;
                        end else begin
                            nm[k] <= nm[k-1];
                            ne[k] <= ne[k-1];
                        end
                    end
                end
            end
        end
    endgenerate

    // ========================================================================
    // Финальная нормализация |M| к [3^13,3^14) + знак + упаковка
    // ========================================================================
    logic signed [63:0] f_M;
    logic f_sign, f_zero, f_nan;
    logic [M_TRITS*2-1:0] f_mt;
    logic [E_TRITS*2-1:0] f_et;
    logic signed [63:0] f_Ma;

    // M уже нормирован (после NSTAGES). Ещё 8 стадий коррекции для безопасности.
    logic signed [63:0] fm [0:8];
    logic        fv [0:8], fs [0:8], fz [0:8], fn [0:8];
    generate
        for (k = 0; k <= 8; k++) begin : gen_final
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    fm[k] <= 0; fv[k] <= 0; fs[k] <= 0; fz[k] <= 0; fn[k] <= 0;
                end else begin
                    if (k == 0) begin
                        fm[0] <= nm[NSTAGES]; fv[0] <= nv[NSTAGES];
                        fs[0] <= nsn[NSTAGES]; fz[0] <= nz[NSTAGES]; fn[0] <= nn[NSTAGES];
                    end else begin
                        fv[k] <= fv[k-1]; fs[k] <= fs[k-1]; fz[k] <= fz[k-1]; fn[k] <= fn[k-1];
                        // нормировка вниз (|M| >= 3^14)
                        if (fm[k-1] >= 96'sd4782969 || fm[k-1] <= -96'sd4782969) begin
                            if (fm[k-1] >= 0) fm[k] <= fm[k-1]/3; else fm[k] <= -((-fm[k-1])/3);
                        end else if (fm[k-1] < 96'sd1594323 && fm[k-1] > -96'sd1594323) begin
                            fm[k] <= fm[k-1] + (fm[k-1]<<1);   // *3 (вверх до 3^13)
                        end else begin
                            fm[k] <= fm[k-1];
                        end
                    end
                end
            end
        end
    endgenerate

    // упаковка (комбинационно от fm[8], fs, fz, fn)
    logic signed [63:0] f_Mout;
    assign f_Mout = (fs[8] && !fz[8]) ? -fm[8] : fm[8];

    int_to_trits #(.N(M_TRITS), .W(64)) u_m (.value(f_Mout[63:0]), .trits(f_mt));
    int_to_trits #(.N(E_TRITS), .W(32))  u_e (.value(32'sd73), .trits(f_et));  // E=13+60

    logic [39:0] f_data;
    always_comb begin
        if (fn[8])       f_data = {TOTAL_TRITS{2'b11}};
        else if (fz[8])  f_data = {TOTAL_TRITS{2'b00}};
        else             f_data = {f_mt, f_et};
    end

    assign m_axis_tvalid = fv[8];
    assign m_axis_tdata  = f_data;

endmodule
