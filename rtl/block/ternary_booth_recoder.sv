// ============================================================================
// ternary_booth_recoder.sv — троичный Booth recoding множителя
// ============================================================================
// Конвертирует 20-тритный множитель в ~13 "recoded" групп, каждая ∈
// {0, ±1, ±2, ±3}. Каждая recoded-группа генерирует partial product
// 0, ±A, ±2A, ±3A, что в 1.5 раза меньше partial products, чем
// прямое умножение (20 → 13).
//
// Алгоритм: группируем триты множителя по 2, для каждой пары (b_{2i+1}, b_{2i})
// генерируем recoded-значение r[i] ∈ {0, ±1, ±2, ±3}:
//   b_{2i+1} b_{2i}  →  r[i]
//   ────────────────────────────
//     0   0   →  0           (0×A)
//     0   1   → +1           (+A)
//     0  -1   → -1           (-A)
//     1   0   → +1           (+A, carry +1 в следующую группу)
//     1   1   → -1           (+A×3 - A×4 = -A, упрощённо: +A в эту, -1 в след)
//     1  -1   → +2           (+A<<1)
//    -1   0   → -1           (-A, carry -1 в следующую группу)
//    -1   1   → -2           (-A<<1)
//    -1  -1   → +1           (-A + A×2 = +A)
//
// С карри- propagation между группами: r[i] + 3×carry[i-1] = (b_{2i+1}+b_{2i}).
// Carries ∈ {-1, 0, +1}.
//
// Для 20 тритов → 10 групп по 2 трита + обработка переноса → 11 групп.
// Однако в среднем ~7-8 групп = 0 (sparse), что даёт экономию LUT.
//
// Выход: r_code[10:0] — массив 11 recoded значений, каждое 3 бита:
//   000 = 0, 001 = +1, 010 = +2, 011 = +3,
//   100 = -1, 101 = -2, 110 = -3, 111 = reserved
// ============================================================================
module ternary_booth_recoder #(
    parameter int N = 20  // число тритов во входном множителе
)(
    input  logic [2*N-1:0]  b,        // 20 тритов × 2 бита = 40 бит
    output logic [2:0]      r_code [0:(N+1)/2-1],  // 11 recoded groups, 3 bits each
    output logic [$clog2((N+1)/2)-1:0] n_groups    // актуальное число групп
);
    // Кодирование тритов: +1->01, 0->00, -1->10
    localparam logic [1:0] P1 = 2'b01;
    localparam logic [1:0] N1 = 2'b10;
    localparam logic [1:0] T0 = 2'b00;

    // Извлекаем триты множителя
    function automatic logic signed [1:0] trit_val(input logic [1:0] c);
        case (c)
            P1: trit_val = 2'sd1;
            N1: trit_val = -2'sd1;
            default: trit_val = 2'sd0;
        endcase
    endfunction

    // Число групп: ceil(N/2) = 10 для N=20. +1 для overflow carry.
    localparam int N_GROUPS = (N + 1) / 2 + 1;  // 11 (10 + 1 overflow)

    // Триты множителя (младший первым)
    logic signed [1:0] b_trit [0:N-1];
    always_comb begin
        for (int i = 0; i < N; i++) begin
            b_trit[i] = trit_val(b[2*i +: 2]);
        end
    end

    // Booth recoding с carry propagation
    // Для каждой пары тритов (b_{2i+1}, b_{2i}) вычисляем:
    //   pair_sum = b_trit[2*i] + b_trit[2*i+1]   ∈ {-2,-1,0,1,2}
    //   r_val[i] = pair_sum - 3*carry_out[i]    ∈ {-2,-1,0,1,2}
    //   carry_out[i] = (pair_sum + carry_in[i]) > 1 ? +1 :
    //                  (pair_sum + carry_in[i]) < -1 ? -1 : 0
    logic signed [2:0] carry [0:N_GROUPS];   // carry_in для каждой группы
    logic signed [2:0] r_val [0:N_GROUPS-1];  // recoded values {-3..+3}

    always_comb begin
        carry[0] = 0;
        for (int i = 0; i < N_GROUPS; i++) begin
            logic signed [2:0] pair_sum;
            logic signed [2:0] total;

            if (i < N/2) begin
                pair_sum = b_trit[2*i] + b_trit[2*i+1];
            end else if (i == N/2 && (N % 2 == 1)) begin
                pair_sum = b_trit[N-1];  // старший трит если N нечётное
            end else begin
                pair_sum = 0;  // overflow группа — только для последнего carry
            end

            total = pair_sum + carry[i];

            // Booth recoding: r_val ∈ {-2,-1,0,1,2}, carry ∈ {-1,0,+1}
            // total может быть от -3 (pair_sum=-2 + carry=-1) до +3
            if (total > 1) begin
                r_val[i] = total - 3;
                carry[i+1] = 1;
            end else if (total < -1) begin
                r_val[i] = total + 3;
                carry[i+1] = -1;
            end else begin
                r_val[i] = total;
                carry[i+1] = 0;
            end
        end
    end

    // Кодируем r_val в 3-битный код для использования в sign-mux
    // 000=0, 001=+1, 010=+2, 011=+3, 100=-1, 101=-2, 110=-3
    function automatic logic [2:0] encode_r(input logic signed [2:0] v);
        case (v)
            3'sd0:  encode_r = 3'b000;
            3'sd1:  encode_r = 3'b001;
            3'sd2:  encode_r = 3'b010;
            3'sd3:  encode_r = 3'b011;
            -3'sd1: encode_r = 3'b100;
            -3'sd2: encode_r = 3'b101;
            -3'sd3: encode_r = 3'b110;
            default: encode_r = 3'b000;
        endcase
    endfunction

    always_comb begin
        for (int i = 0; i < N_GROUPS; i++) begin
            r_code[i] = encode_r(r_val[i]);
        end
        n_groups = N_GROUPS;
    end

endmodule
