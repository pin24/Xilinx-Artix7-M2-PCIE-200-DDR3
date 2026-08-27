// ============================================================================
// tf40_dot.sv - векторное ядро: скалярное произведение TFloat40
// ============================================================================
// Считает sum(a[i]*b[i]) для i in [0,N). Попарное бинарное дерево
// mul + add (совпадает с Python-эталоном dot_ref).
//
// Структура: 7 уровней (покрывает N<=128). Каждый уровень - массив из N
// позиций; на уровне L активны первые ceil(N/2^L) позиций.
// ============================================================================

module tf40_dot #(
    parameter int N = 64
)(
    input  logic [39:0] a [0:N-1],
    input  logic [39:0] b [0:N-1],
    output logic [39:0] result,
    output logic        err_out
);
    import tfloat_pkg::*;

    // --- stage 0: N произведений ---
    logic [39:0] prod [0:N-1];

    genvar g;
    generate
        for (g = 0; g < N; g++) begin : gen_mul
            tf40_mul u_mul (.a(a[g]), .b(b[g]), .result(prod[g]), .err_out());
        end
    endgenerate

    // --- дерево сложений: 7 уровней, lvl[0]=prod ---
    localparam int LEVELS = 7;
    logic [39:0] lvl [0:LEVELS][0:N-1];

    generate
        for (g = 0; g < N; g++) begin : gen_lvl0
            assign lvl[0][g] = prod[g];
        end
    endgenerate

    genvar L, i2;
    generate
        for (L = 1; L <= LEVELS; L++) begin : gen_level
            // длина предыдущего уровня
            // W_prev = ceil(N / 2^(L-1)) - не может быть localparam в genvar-цикле,
            // поэтому вычисляем "живые" индексы через проверку.
            for (i2 = 0; i2 < N; i2++) begin : gen_pair
                // активен, если 2*i2+1 < ceil(N/2^(L-1))
                if (2*i2+1 < ((N + (1 << (L-1)) - 1) / (1 << (L-1)))) begin
                    tf40_add u_add (
                        .a(lvl[L-1][2*i2]), .b(lvl[L-1][2*i2+1]),
                        .result(lvl[L][i2]), .err_out());
                end else if (i2 < ((N + (1 << (L-1)) - 1) / (1 << (L-1)))) begin
                    // нечётный элемент: переносим
                    assign lvl[L][i2] = lvl[L-1][i2];
                end else begin
                    assign lvl[L][i2] = {TOTAL_TRITS{2'b00}};  // неактивно
                end
            end
        end
    endgenerate

    // результат на последнем активном уровне
    assign result = lvl[LEVELS][0];

    // err: любой prod/сумма с ошибкой
    logic err_any;
    always_comb begin
        err_any = 0;
        for (int i = 0; i < N; i++)
            if (prod[i] == {TOTAL_TRITS{2'b11}}) err_any = 1;
        for (int L = 1; L <= LEVELS; L++)
            for (int i = 0; i < N; i++)
                if (lvl[L][i] == {TOTAL_TRITS{2'b11}}) err_any = 1;
    end
    assign err_out = err_any;

endmodule
