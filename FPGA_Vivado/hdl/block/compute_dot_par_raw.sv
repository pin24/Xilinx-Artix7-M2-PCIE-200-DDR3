// ============================================================================
// compute_dot_par_raw.sv - ПАРАЛЛЕЛЬНЫЙ dot: NUM_MAC tfmul_raw + дерево tfadd_raw
// ============================================================================
// Умножители БЕЗ нормализации (дешёвые, ~2k LUT), нормализация только на
// дереве сложений (1 tfadd_raw).
// Вход: NUM_MAC пар TFloat48 (data + weights).
// Выход: TFloat48 (нормализованный), валиден.
// ============================================================================
module compute_dot_par_raw #(
    parameter int NUM_MAC = 32
)(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic [48*NUM_MAC-1:0]      data_in,
    input  logic [48*NUM_MAC-1:0]      weights,
    input  logic                       valid_in,
    output logic [47:0]                result_out,
    output logic                       valid_out
);

    // --- NUM_MAC параллельных умножителей (без норм) ---
    logic [NUM_MAC-1:0]  m_valid_in;
    logic [NUM_MAC-1:0]  m_valid_out;
    logic [79:0]         m_prod [0:NUM_MAC-1];
    logic [7:0]          m_e    [0:NUM_MAC-1];
    logic                m_neg  [0:NUM_MAC-1];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_MAC; gi++) begin : gen_mac
            tfmul_raw u_mul (
                .clk(clk), .rst_n(rst_n),
                .valid_in(m_valid_in[gi]),
                .a(data_in[48*gi +: 48]), .b(weights[48*gi +: 48]),
                .valid_out(m_valid_out[gi]),
                .prod(m_prod[gi]), .e(m_e[gi]), .neg(m_neg[gi])
            );
        end
    endgenerate

    // --- один adder (ненормализованных продуктов) для дерева ---
    logic        ad_valid_in, ad_valid_out;
    logic [79:0] ad_a, ad_b;
    logic [7:0]  ad_ea, ad_eb;
    logic        ad_na, ad_nb;
    logic [47:0] ad_res;
    tfadd_raw u_add (
        .clk(clk), .rst_n(rst_n),
        .valid_in(ad_valid_in),
        .a_prod(ad_a), .a_e(ad_ea), .a_neg(ad_na),
        .b_prod(ad_b), .b_e(ad_eb), .b_neg(ad_nb),
        .valid_out(ad_valid_out), .result(ad_res)
    );

    // буферы продуктов (ненормализованные) и результатов дерева (TFloat48)
    logic [79:0] prod [0:NUM_MAC-1];
    logic [7:0]  pe   [0:NUM_MAC-1];
    logic        pneg [0:NUM_MAC-1];
    logic [47:0] tbuf [0:1][0:NUM_MAC-1];
    logic [7:0]  ca_i;
    logic        t_dst;

    function automatic logic signed [2:0] trit_val_ab(input logic [1:0] c);
        case (c)
            2'b01: trit_val_ab = 3'sd1;
            2'b10: trit_val_ab = -3'sd1;
            default: trit_val_ab = 3'sd0;
        endcase
    endfunction

    // распаковка tbuf (уровни > 0): TFloat48 -> (prod, e, neg) для tfadd_raw
    logic [79:0] unp_prod_a, unp_prod_b;
    logic signed [7:0] unp_e_a, unp_e_b;
    logic        unp_neg_a, unp_neg_b;
    always_comb begin
        begin
            logic [47:0] va, vb;
            logic signed [7:0] tmp;
            va = tbuf[1-t_dst][2*ca_i];
            vb = tbuf[1-t_dst][2*ca_i+1];
            unp_prod_a = {40'h0, va[39:0]};
            unp_prod_b = {40'h0, vb[39:0]};
            tmp = 8'sd0;
            for (int i = 3; i >= 0; i--)
                tmp = tmp * 3 + trit_val_ab(va[40 + 2*i +: 2]);
            unp_e_a = tmp;
            tmp = 8'sd0;
            for (int i = 3; i >= 0; i--)
                tmp = tmp * 3 + trit_val_ab(vb[40 + 2*i +: 2]);
            unp_e_b = tmp;
            unp_neg_a = 1'b0;
            for (int t = 19; t >= 0; t--)
                if (va[2*t +: 2] != 2'b00) begin
                    unp_neg_a = (va[2*t +: 2] == 2'b10);
                    break;
                end
            unp_neg_b = 1'b0;
            for (int t = 19; t >= 0; t--)
                if (vb[2*t +: 2] != 2'b00) begin
                    unp_neg_b = (vb[2*t +: 2] == 2'b10);
                    break;
                end
        end
    end

    localparam int PH_IDLE = 0;
    localparam int PH_MUL  = 1;
    localparam int PH_TREE = 2;
    localparam int PH_DONE = 3;
    localparam int NUM_LEVELS = $clog2(NUM_MAC);

    logic [1:0] phase;
    logic [7:0] mul_done;
    logic [7:0] ar_i, t_lvl, t_cnt;
    logic       ad_busy;
    logic [47:0] dot_res, result_out_reg;
    logic valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE;
            mul_done <= 0;
            ca_i <= 0; ar_i <= 0; t_lvl <= 0; t_cnt <= 0; t_dst <= 0;
            ad_busy <= 0;
            ad_valid_in <= 0; ad_a <= 0; ad_b <= 0; ad_ea <= 0; ad_eb <= 0;
            ad_na <= 0; ad_nb <= 0;
            dot_res <= 0; result_out_reg <= 0; valid_q <= 0;
            for (int x = 0; x < NUM_MAC; x++) begin
                m_valid_in[x] <= 0;
                prod[x] <= 0; pe[x] <= 0; pneg[x] <= 0;
                tbuf[0][x] <= 0; tbuf[1][x] <= 0;
            end
        end else begin
            valid_q <= 0;
            ad_valid_in <= 0;
            for (int x = 0; x < NUM_MAC; x++) m_valid_in[x] <= 0;
            case (phase)
                PH_IDLE: begin
                    if (valid_in) begin
                        phase <= PH_MUL;
                        mul_done <= 0;
                        for (int x = 0; x < NUM_MAC; x++)
                            m_valid_in[x] <= 1;
                    end
                end
                PH_MUL: begin
                    for (int x = 0; x < NUM_MAC; x++) begin
                        if (m_valid_out[x]) begin
                            prod[x] <= m_prod[x];
                            pe[x] <= m_e[x];
                            pneg[x] <= m_neg[x];
                        end
                    end
                    begin
                        logic [7:0] done_cnt;
                        done_cnt = 0;
                        for (int x = 0; x < NUM_MAC; x++)
                            if (m_valid_out[x]) done_cnt = done_cnt + 1;
                        if (done_cnt != 0)
                            mul_done <= mul_done + done_cnt;
                        if (mul_done + done_cnt >= NUM_MAC) begin
                            phase <= PH_TREE;
                            t_lvl <= 0; ca_i <= 0; ar_i <= 0;
                            t_cnt <= NUM_MAC/2; t_dst <= 0; ad_busy <= 0;
                        end
                    end
                end
                PH_TREE: begin
                    if (!ad_busy) begin
                        if (ca_i < t_cnt) begin
                            ad_valid_in <= 1;
                            if (t_lvl == 0) begin
                                ad_a <= prod[2*ca_i];
                                ad_b <= prod[2*ca_i+1];
                                ad_ea <= pe[2*ca_i];
                                ad_eb <= pe[2*ca_i+1];
                                ad_na <= pneg[2*ca_i];
                                ad_nb <= pneg[2*ca_i+1];
                            end else begin
                                // результаты уровня - нормализованные TFloat48
                                ad_a <= unp_prod_a;
                                ad_b <= unp_prod_b;
                                ad_ea <= unp_e_a;
                                ad_eb <= unp_e_b;
                                ad_na <= unp_neg_a;
                                ad_nb <= unp_neg_b;
                            end
                            ca_i <= ca_i + 1;
                            ad_busy <= 1;
                        end
                    end
                    if (ad_valid_out) begin
                        if (t_lvl == NUM_LEVELS-1) begin
                            dot_res <= ad_res;
                        end else begin
                            tbuf[t_dst][ar_i] <= ad_res;
                        end
                        ar_i <= ar_i + 1;
                        ad_busy <= 0;
                    end
                    if (ar_i == t_cnt) begin
                        if (t_lvl == NUM_LEVELS-1) begin
                            phase <= PH_DONE;
                        end else begin
                            t_lvl <= t_lvl + 1;
                            t_dst <= 1 - t_dst;
                            ca_i <= 0; ar_i <= 0;
                            t_cnt <= t_cnt >> 1;
                            ad_busy <= 0;
                        end
                    end
                end
                PH_DONE: begin
                    result_out_reg <= dot_res;
                    valid_q <= 1;
                    phase <= PH_IDLE;
                end
            endcase
        end
    end

    assign result_out = result_out_reg;
    assign valid_out = valid_q;

endmodule
