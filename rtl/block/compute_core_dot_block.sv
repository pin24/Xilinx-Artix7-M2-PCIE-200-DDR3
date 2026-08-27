// ============================================================================
// compute_core_dot_block.sv - dot-произведение N=16 на базе 1 MAC (tfmac)
// ============================================================================
// Вход: N x TFloat48 (data) + N x TFloat48 (weights), 48 бит каждый.
// dot = sum data[i]*weights[i]  (порядок: сначала N mul, затем попарное дерево add).
// Использует ОДИН tfmac последовательно (ресурсо-оптимально).
// ============================================================================
module compute_core_dot_block #(
    parameter int N = 16
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic [48*N-1:0]      data_in,
    input  logic [48*N-1:0]      weights,
    input  logic                 valid_in,
    output logic [47:0]          result_out,
    output logic                 valid_out
);
    // tfmac
    logic        m_valid_in, m_op;
    logic [47:0] m_a, m_b;
    logic        m_valid_out;
    logic [47:0] m_result;

    tfmac u_mac (
        .clk(clk), .rst_n(rst_n),
        .valid_in(m_valid_in), .op(m_op), .a(m_a), .b(m_b),
        .valid_out(m_valid_out), .result(m_result)
    );

    // буферы продуктов
    logic [47:0] prod [0:N-1];
    logic [47:0] tbuf [0:1][0:N-1];

    // FSM
    localparam int PH_IDLE = 0;
    localparam int PH_MUL  = 1;
    localparam int PH_TREE = 2;
    localparam int PH_DONE = 3;

    logic [1:0] phase;
    logic [4:0] mul_idx;      // 0..N-1
    logic [4:0] mul_done;     // сколько mul завершено
    logic [4:0] ca_i;         // счётчик сложений уровня
    logic [4:0] ar_i;         // получено сложений
    logic [2:0] t_lvl;
    logic [4:0] t_cnt;
    logic       t_dst;
    logic       m_busy;       // ожидание результата tfmac
    logic [47:0] dot_res;
    logic [47:0] result_out_reg;
    logic valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE;
            mul_idx <= 0; mul_done <= 0;
            ca_i <= 0; ar_i <= 0; t_lvl <= 0; t_cnt <= 0; t_dst <= 0;
            m_valid_in <= 0; m_op <= 0; m_a <= 0; m_b <= 0;
            dot_res <= 0; valid_q <= 0;
            for (int x = 0; x < N; x++) begin
                prod[x] <= 0;
                tbuf[0][x] <= 0; tbuf[1][x] <= 0;
            end
        end else begin
            valid_q <= 0;
            m_valid_in <= 0;
            case (phase)
                PH_IDLE: begin
                    if (valid_in) begin
                        phase <= PH_MUL;
                        mul_idx <= 0; mul_done <= 0; m_busy <= 0;
                    end
                end
                PH_MUL: begin
                    // подача пары mul_idx, ждём результат, затем следующая
                    if (!m_busy) begin
                        if (mul_idx < N) begin
                            m_valid_in <= 1;
                            m_op <= 0;
                            m_a <= data_in[48*mul_idx +: 48];
                            m_b <= weights[48*mul_idx +: 48];
                            mul_idx <= mul_idx + 1;
                            m_busy <= 1;
                        end
                    end
                    if (m_valid_out) begin
                        prod[mul_done] <= m_result;
                        mul_done <= mul_done + 1;
                        m_busy <= 0;
                    end
                    if (mul_done == N) begin
                        phase <= PH_TREE;
                        t_lvl <= 0; ca_i <= 0; ar_i <= 0;
                        t_cnt <= N/2; t_dst <= 0; m_busy <= 0;
                    end
                end
                PH_TREE: begin
                    // подача пары add, ждём результат, затем следующая
                    if (!m_busy) begin
                        if (ca_i < t_cnt) begin
                            m_valid_in <= 1;
                            m_op <= 1;
                            if (t_lvl == 0) begin
                                m_a <= prod[2*ca_i];
                                m_b <= prod[2*ca_i+1];
                            end else begin
                                m_a <= tbuf[1-t_dst][2*ca_i];
                                m_b <= tbuf[1-t_dst][2*ca_i+1];
                            end
                            ca_i <= ca_i + 1;
                            m_busy <= 1;
                        end
                    end
                    if (m_valid_out) begin
                        if (t_lvl == 3) begin
                            dot_res <= m_result;
                        end else begin
                            tbuf[t_dst][ar_i] <= m_result;
                        end
                        ar_i <= ar_i + 1;
                        m_busy <= 0;
                    end
                    if (ar_i == t_cnt) begin
                        if (t_lvl == 3) begin
                            phase <= PH_DONE;
                        end else begin
                            t_lvl <= t_lvl + 1;
                            t_dst <= 1 - t_dst;
                            ca_i <= 0;
                            ar_i <= 0;
                            t_cnt <= t_cnt >> 1;
                            m_busy <= 0;
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
