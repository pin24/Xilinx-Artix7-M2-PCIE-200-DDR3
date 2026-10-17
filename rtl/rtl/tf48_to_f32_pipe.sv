// ============================================================================
// tf48_to_f32_pipe.sv - КОНВЕЙЕРНЫЙ конвертер TFloat48 -> float32 (RNE)
// ============================================================================
// Бит-в-бит эквивалентен комбинационному tf48_to_f32.sv, НО широкая
// 192-битная делительная цепь (q=num/den, rem=num%den) вынесена в
// таймингово-безопасный byte-serial конвейер tf48_div_pipe (BPB=8,
// NS=ceil(192/8)=24 стадии).
//
// Вход tf48 в конвенции ядра: [47:40]=e, [39:0]=M. Результат - float32 с
// RNE (round-to-nearest-even), как host TFloat.to_float(). Эталон того,
// что делает 2-я ветка: tf48 результат ядра -> fp32 (4 байта).
//
// Латентность: 1 (пре-стадия) + 24 (делитель) + 1 (выход) ~ 26 тактов.
// Throughput: 1 элемент/такт.
// ============================================================================

module tf48_to_f32_pipe (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        s_axis_tvalid,
    input  logic [47:0] s_axis_tdata,
    output logic        m_axis_tvalid,
    output logic [31:0] m_axis_tdata
);
    import tf48_pkg::*;

    localparam int W = 192;   // ширина рациональной арифметики

    // ============ КОМБИНАЦИОННОЕ ядро (копия тела tf48_to_f32.sv) ============
    logic [M_BITS-1:0] m_bits;
    logic [E_BITS-1:0] e_bits;
    assign m_bits = s_axis_tdata[M_BITS-1:0];
    assign e_bits = s_axis_tdata[47:40];

    logic err_m, err_e;
    always_comb begin
        err_m = 1'b0;
        for (int i = 0; i < M_TRITS; i++)
            if (m_bits[i*2 +: 2] == TRIT_ERR) err_m = 1'b1;
        err_e = 1'b0;
        for (int i = 0; i < E_TRITS; i++)
            if (e_bits[i*2 +: 2] == TRIT_ERR) err_e = 1'b1;
    end

    logic signed [63:0] M;
    logic signed [15:0] de;
    always_comb begin
        M = 64'sd0;
        for (int i = M_TRITS-1; i >= 0; i--)
            M = M * 3 + $signed(trit_val(m_bits[i*2 +: 2]));
        de = 16'sd0;
        for (int i = E_TRITS-1; i >= 0; i--)
            de = de * 3 + $signed(trit_val(e_bits[i*2 +: 2]));
    end

    logic        nsign;
    logic [63:0] A;
    logic        is_zero;
    assign nsign   = (M < 0);
    assign A       = (M < 0) ? (-M[63:0]) : M[63:0];
    assign is_zero = (M == 0);

    localparam int WN = 192;
    logic [W-1:0] P3n [0:22];
    logic [W-1:0] P3d [0:58];
    genvar g;
    generate
        assign P3n[0] = {{(W-1){1'b0}}, 1'b1};
        assign P3d[0] = {{(W-1){1'b0}}, 1'b1};
        for (g = 1; g <= 58; g++) begin : gen_p3
            assign P3d[g] = P3d[g-1] * 3;
            if (g <= 22) assign P3n[g] = P3n[g-1] * 3;
        end
    endgenerate

    logic [W-1:0] N, D;
    logic [W-1:0] A_w;
    always_comb begin
        N = {W{1'b0}};
        D = {W{1'b0}};
        A_w = {{(W-64){1'b0}}, A};
        if (de >= 18) begin
            N = A_w * P3n[de - 18];
            D = 1;
        end else begin
            N = A_w;
            D = P3d[18 - de];
        end
    end

    function automatic logic vge(input int cc);
        logic [W-1:0] lhs, rhs;
        lhs = N;
        if (cc >= 0)
            rhs = D << cc;
        else begin
            lhs = N << (-cc);
            rhs = D;
        end
        vge = (lhs >= rhs);
    endfunction

    logic signed [15:0] e2;
    always_comb begin
        e2 = -16'sd1;
        for (int c = 64; c >= -95; c--) begin
            if (vge(c)) begin
                e2 = c;
                break;
            end
        end
    end

    logic signed [15:0] T;
    logic [W-1:0] num, den;
    assign T = 23 - e2[15:0];

    always_comb begin
        num = N;
        den = D;
        if (T >= 0)
            num = N << T[8:0];
        else
            den = D << (-T[8:0]);
    end

    // ============ пре-стадия: захват входа делителя + служебных флагов ============
    logic        p_valid;
    logic [W-1:0] p_num, p_den;
    logic        p_is_zero, p_nsign, p_err_m, p_err_e;
    logic signed [15:0] p_e2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_valid <= 1'b0; p_num <= '0; p_den <= '0;
            p_is_zero <= 1'b0; p_nsign <= 1'b0; p_err_m <= 1'b0; p_err_e <= 1'b0;
            p_e2 <= 16'sd0;
        end else begin
            p_valid  <= s_axis_tvalid;
            p_num    <= num;
            p_den    <= den;
            p_is_zero<= is_zero;
            p_nsign  <= nsign;
            p_err_m  <= err_m;
            p_err_e  <= err_e;
            p_e2     <= e2;
        end
    end

    // ============ byte-serial делитель 192/192 ============
    localparam int NS  = (192 + 8 - 1) / 8;   // 24 стадии деления
    logic        dv_valid;
    logic [191:0] dv_q;
    logic [191:0] dv_rem;
    tf48_div_pipe #(.N(192), .M(192), .QW(192), .BPB(8)) u_div (
        .clk(clk), .rst_n(rst_n),
        .i_valid(p_valid),
        .i_num(p_num), .i_den(p_den),
        .o_valid(dv_valid), .o_q(dv_q), .o_rem(dv_rem)
    );

    // ============ линия задержки служебных сигналов ============
    // Делитель: пред-стадия (1 такт) + NS стадий. Выход o_valid через NS+1 тактов
    // после p_valid; d_valid[NS] через 1+NS после s_axis_tvalid -> выравнивание.
    localparam int DL = NS;
    logic        d_valid [0:DL];
    logic        d_zero  [0:DL];
    logic        d_nsign [0:DL];
    logic        d_errm  [0:DL];
    logic        d_erre  [0:DL];
    logic signed [15:0] d_e2 [0:DL];
    logic [W-1:0] d_den [0:DL];      // знаменатель (для сравнения RNE в 2*rem>den)
    genvar dd;
    generate
        for (dd = 0; dd <= DL; dd++) begin : gen_dly
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    d_valid[dd] <= 1'b0;
                    d_zero[dd] <= 1'b0; d_nsign[dd] <= 1'b0;
                    d_errm[dd] <= 1'b0; d_erre[dd] <= 1'b0;
                    d_e2[dd] <= 16'sd0;
                    d_den[dd] <= '0;
                end else begin
                    if (dd == 0) begin
                        d_valid[0] <= p_valid;
                        d_zero[0]  <= p_is_zero;
                        d_nsign[0] <= p_nsign;
                        d_errm[0]  <= p_err_m;
                        d_erre[0]  <= p_err_e;
                        d_e2[0]    <= p_e2;
                        d_den[0]   <= p_den;
                    end else begin
                        d_valid[dd] <= d_valid[dd-1];
                        d_zero[dd]  <= d_zero[dd-1];
                        d_nsign[dd] <= d_nsign[dd-1];
                        d_errm[dd]  <= d_errm[dd-1];
                        d_erre[dd]  <= d_erre[dd-1];
                        d_e2[dd]    <= d_e2[dd-1];
                        d_den[dd]   <= d_den[dd-1];
                    end
                end
            end
        end
    endgenerate

    // ============ RNE на выходе делителя ============
    logic [W-1:0] m24;
    logic signed [15:0] e2n;
    always_comb begin
        m24 = dv_q;
        begin : rne
            logic [W-1:0] two_rem;
            logic [W-1:0] denw;
            denw     = d_den[DL];       // знаменатель, использованный в делении
            two_rem  = dv_rem << 1;
            if (two_rem > denw)
                m24 = dv_q + 1;
            else if (two_rem == denw) begin
                if (dv_q[0] == 1'b1) m24 = dv_q + 1;
            end
        end
        e2n = d_e2[DL];
        if (m24 >= (1 << 24)) begin
            m24 = m24 >> 1;
            e2n = e2n + 1;
        end
    end

    // ============ сборка float32 ============
    logic [7:0] e_b;
    assign e_b = e2n[15:0] + 127;

    logic [31:0] out_data;
    always_comb begin
        if (d_zero[DL]) begin
            out_data = 32'h0;
        end else if (d_errm[DL] || d_erre[DL]) begin
            out_data = 32'h7FC00000;
        end else if (e_b >= 255) begin
            out_data = {d_nsign[DL], 8'hFF, 23'h0};
        end else if (e_b <= 0) begin
            out_data = 32'h0;
        end else begin
            out_data = {d_nsign[DL], e_b, m24[22:0]};
        end
    end

    // ============ выходной регистровый каскад ============
    logic        out_v;
    logic [31:0] out_q;
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

endmodule