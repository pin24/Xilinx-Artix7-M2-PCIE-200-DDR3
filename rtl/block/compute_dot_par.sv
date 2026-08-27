// ============================================================================
// compute_dot_par.sv - ПАРАЛЛЕЛЬНЫЙ dot: NUM_MAC умножителей + дерево add
// ============================================================================
// Вход: NUM_MAC пар TFloat48 (data + weights), 48 бит каждый.
// Все NUM_MAC умножителей (tfmul) работают параллельно (~25+ тактов).
// Затем попарное дерево сложений через ОДИН tfmac (add), последовательно.
// Итог: dot ~ 25 + log2(NUM_MAC) операций add последовательно.
// ============================================================================
module compute_dot_par #(
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

    // --- NUM_MAC параллельных умножителей ---
    // входы: комбинационные от data_in/weights (tfmul захватывает на такте valid_in)
    logic [NUM_MAC-1:0]  m_valid_in;
    logic [NUM_MAC-1:0]  m_valid_out;
    logic [47:0]         m_res [0:NUM_MAC-1];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_MAC; gi++) begin : gen_mac
            tfmul u_mul (
                .clk(clk), .rst_n(rst_n),
                .valid_in(m_valid_in[gi]),
                .a(data_in[48*gi +: 48]), .b(weights[48*gi +: 48]),
                .valid_out(m_valid_out[gi]),
                .result(m_res[gi])
            );
        end
    endgenerate

    // --- один adder (tfmac в режиме add) для дерева ---
    logic        ad_valid_in, ad_valid_out;
    logic        ad_op;
    logic [47:0] ad_a, ad_b, ad_res;
    tfmac u_add (
        .clk(clk), .rst_n(rst_n),
        .valid_in(ad_valid_in), .op(ad_op), .a(ad_a), .b(ad_b),
        .valid_out(ad_valid_out), .result(ad_res)
    );

    // буферы продуктов
    logic [47:0] prod [0:NUM_MAC-1];
    logic [47:0] tbuf [0:1][0:NUM_MAC-1];

    localparam int PH_IDLE = 0;
    localparam int PH_MUL  = 1;
    localparam int PH_TREE = 2;
    localparam int PH_DONE = 3;
    localparam int NUM_LEVELS = $clog2(NUM_MAC);

    logic [1:0] phase;
    logic [5:0] mul_done;     // сколько умножителей завершено
    logic [5:0] ca_i;
    logic [5:0] ar_i;
    logic [5:0] t_lvl;
    logic [5:0] t_cnt;
    logic       t_dst;
    logic       ad_busy;
    logic [47:0] dot_res;
    logic [47:0] result_out_reg;
    logic valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE;
            mul_done <= 0;
            ca_i <= 0; ar_i <= 0; t_lvl <= 0; t_cnt <= 0; t_dst <= 0;
            ad_busy <= 0;
            ad_valid_in <= 0; ad_op <= 1; ad_a <= 0; ad_b <= 0;
            dot_res <= 0; result_out_reg <= 0; valid_q <= 0;
            for (int x = 0; x < NUM_MAC; x++) begin
                m_valid_in[x] <= 0;
                prod[x] <= 0;
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
                        // подаём все NUM_MAC пар одновременно
                        for (int x = 0; x < NUM_MAC; x++)
                            m_valid_in[x] <= 1;
                    end
                end
                PH_MUL: begin
                    // приём результатов по мере готовности (накопительный счётчик)
                    for (int x = 0; x < NUM_MAC; x++)
                        if (m_valid_out[x])
                            prod[x] <= m_res[x];
                    begin
                        logic [5:0] done_cnt;
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
                            ad_op <= 1;
                            if (t_lvl == 0) begin
                                ad_a <= prod[2*ca_i];
                                ad_b <= prod[2*ca_i+1];
                            end else begin
                                ad_a <= tbuf[1-t_dst][2*ca_i];
                                ad_b <= tbuf[1-t_dst][2*ca_i+1];
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
                            ca_i <= 0;
                            ar_i <= 0;
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
