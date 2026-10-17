// ============================================================================
// tf48_div_pipe.sv - pipelined byte-serial restoring divider (беззнаковый)
// ============================================================================
// Вычисляет q = num / den, rem = num % den для беззнаковых целых.
// Алгоритм: классическое восстанавливающее (restoring) длинное деление
// бит-за-битом от MSB к LSB, НО свёрнуто в конвейер ПО БАЙТАМ: каждая
// стадия обрабатывает BPB бит частного подряд (для den/=0).
//
// Таймингово-безопасно: НЕТ единой 193-битной комбинационной делительной
// цепи; вместо этого NS = ceil(N/BPB) независимых зарегистрированных стадий,
// каждая из которых делает одно (на самом деле BPB) сравнение+вычитание.
// Каждый такт в конвейер входит новая пара (num,den); на выходе 1 результат
// за такт (throughput 1/cycle), латентность = NS + 1 тактов.
//
// Полностью эквивалентен комбинационному `num / den` (тринкированное
// беззнаковое деление) — используется для сериализации широких делителей
// в конвертерах fp32<->tf48 (N=M=193 для F2T, N=M=192 для T2F).
// ============================================================================

module tf48_div_pipe #(
    parameter int N   = 193,   // ширина числителя (бит)
    parameter int M   = 193,   // ширина знаменателя (бит)
    parameter int QW  = 193,   // ширина частного (= N обычно)
    parameter int BPB = 8      // бит частного на стадию ("байт-сериализация")
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        i_valid,
    input  logic [N-1:0] i_num,
    input  logic [M-1:0] i_den,
    output logic        o_valid,
    output logic [QW-1:0] o_q,
    output logic [M-1:0] o_rem
);
    localparam int NS  = (N + BPB - 1) / BPB;   // число стадий

    // ---- пред-стадия: захват входа, защита den==0 -> 1 ----
    logic        p_valid;
    logic [N-1:0] p_num;
    logic [M-1:0] p_den;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_valid <= 1'b0;
            p_num   <= '0;
            p_den   <= '0;
        end else begin
            p_valid <= i_valid;
            p_num   <= i_num;
            p_den   <= (i_den == '0) ? {{(M-1){1'b0}}, 1'b1} : i_den;
        end
    end

    // ---- конвейер стадий (индексы 0..NS-1) ----
    logic         rV  [0:NS-1];
    logic [N-1:0] rNum [0:NS-1];
    logic [M-1:0] rDen [0:NS-1];
    logic [M:0]   rR  [0:NS-1];   // рабочий остаток (M+1 бит: до 2*den-1)
    logic [N-1:0] rQ  [0:NS-1];   // накапливаемое частное

    genvar s;
    generate
        for (s = 0; s < NS; s++) begin : gen_st
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rV[s]   <= 1'b0;
                    rNum[s] <= '0;
                    rDen[s] <= '0;
                    rR[s]   <= '0;
                    rQ[s]   <= '0;
                end else begin
                    if (s == 0) begin
                        rV[0]   <= p_valid;
                        rNum[0] <= p_num;
                        rDen[0] <= p_den;
                    end else begin
                        rV[s]   <= rV[s-1];
                        rNum[s] <= rNum[s-1];
                        rDen[s] <= rDen[s-1];
                    end
                    begin
                        logic [M:0]   Rd;
                        logic [N-1:0] Qd;
                        logic [M:0]   denw;
                        if (s == 0) begin
                            Rd  = '0;
                            Qd  = '0;
                            denw = {1'b0, p_den};
                        end else begin
                            Rd  = rR[s-1];
                            Qd  = rQ[s-1];
                            denw = {1'b0, rDen[s-1]};
                        end
                        for (int j = 0; j < BPB; j++) begin
                            int g = (N - 1) - s * BPB - j;   // глобальный индекс бита
                            if (g >= 0) begin
                                logic bitv;
                                logic [M:0] Rd2;
                                if (s == 0) bitv = p_num[g];
                                else         bitv = rNum[s-1][g];
                                Rd2  = (Rd << 1) | {M{1'b0}} | {1'b0, bitv};
                                if (Rd2 >= denw) begin
                                    Rd2 = Rd2 - denw;
                                    Qd[g] = 1'b1;
                                end else begin
                                    Qd[g] = 1'b0;
                                end
                                Rd = Rd2;
                            end
                        end
                        rR[s] <= Rd;
                        rQ[s] <= Qd;
                    end
                end
            end
        end
    endgenerate

    // ---- выход: последняя стадия ----
    assign o_valid = rV[NS - 1];
    assign o_q     = rQ[NS - 1][QW-1:0];
    assign o_rem   = rR[NS - 1][M-1:0];

endmodule