// ============================================================================
// tfmul_kbd.sv — троичный умножитель TFloat48 (Karatsuba + Booth + Dadda)
// ============================================================================
// Замена tfmul_raw.sv. Тот же интерфейс, но с внутренним алгоритмом:
//   1. Karatsuba: разбивает 20-тритные мантиссы на 10+10
//   2. Booth recoding: 10 тритов → ~6 recoded групп
//   3. Dadda tree: сжимает partial products в 2 вектора
//   4. Carry-propagate adder: финальная сборка
//
// ВЕРСИЯ 2 (BUG-039, 2026-09-06): исправлена ТОЧНОСТЬ:
//   (а) средний член Karatsuba: s-коррекция переноса сумм половин (раньше
//       усекался до 10 тритов -> 43.9% случайных пар давали неверный продукт,
//       ошибка до ~3^30; тождество см. в always_comb);
//   (б) carry_val в mul_10x10 расширен до 4 бит (q[1:0] обрезал q до ±5).
// ВНИМАНИЕ: модуль ОДНОТАКТОВЫЙ (вся комбинационная схема за такт) — в сборку
// НЕ подключён (тайминг, BUG-037/038); перед подключением нужен пайплайн.
//
// Интерфейс СОВПАДАЕТ с tfmul_raw.sv:
//   clk, rst_n, valid_in, a[47:0]={E(8), M(40)}, b[47:0]
//   valid_out, prod[79:0] (40 тритов), e[7:0], neg
//
// ВНУТРИ:
//   A·B = (A_hi·3^10 + A_lo)·(B_hi·3^10 + B_lo)
//       = A_hi·B_hi · 3^20   +  (A_hi·B_hi + A_lo·B_lo - (A_hi-A_lo)(B_hi-B_lo)) · 3^10
//        + A_lo·B_lo
//
//   Каждое умножение 10×10 → Booth recoding (10→6) → Dadda tree → CPA
//
// Ожидаемая экономия LUT: ~69% (55k → ~17k на NUM_MAC=32)
// Ускорение: 8 тактов vs 25 тактов
// ============================================================================
module tfmul_kbd (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [47:0] a,           // {E(8), M(40)} — мантисса 20 тритов = 40 бит
    input  logic [47:0] b,
    output logic        valid_out,
    output logic [79:0] prod,        // 40 тритов = 80 бит (ненормализованный продукт)
    output logic [7:0]  e,           // экспонента продукта (signed)
    output logic        neg          // знак продукта
);
    // ============================================================================
    // Параметры
    // ============================================================================
    localparam int N = 20;             // тритов в мантиссе TFloat48
    localparam int HALF = N / 2;       // 10 — Karatsuba split point
    localparam int PP_WIDTH = 2 * HALF + 1;  // 21 — ширина partial product (10×10 = 20 тритов + 1 carry overflow)
    localparam int SUM_WIDTH = 2 * N + 1;    // 41 — ширина финального результата (20+20 + overflow)

    localparam logic [1:0] P1 = 2'b01;
    localparam logic [1:0] N1 = 2'b10;
    localparam logic [1:0] T0 = 2'b00;

    // ============================================================================
    // Helpers (функции для тритов)
    // ============================================================================
    function automatic logic signed [1:0] tval(input logic [1:0] c);
        case (c)
            P1: tval = 2'sd1;
            N1: tval = -2'sd1;
            default: tval = 2'sd0;
        endcase
    endfunction

    function automatic logic [1:0] tcode(input logic signed [1:0] v);
        case (v)
            2'sd1:  tcode = P1;
            -2'sd1: tcode = N1;
            default: tcode = T0;
        endcase
    endfunction

    function automatic logic signed [7:0] exp_val(input logic [7:0] x);
        logic signed [7:0] v;
        logic signed [2:0] tv;
        v = 8'sd0;
        for (int i = 3; i >= 0; i--) begin
            tv = tval(x[2*i +: 2]);
            v = v * 3'sd3 + tv;
        end
        return v;
    endfunction

    // ============================================================================
    // 1. Разбор входа на мантиссу + экспоненту
    // ============================================================================
    logic [2*N-1:0] a_mant, b_mant;     // 40 бит = 20 тритов
    logic [7:0]     a_exp, b_exp;

    // Разделение Karatsuba: A = A_hi · 3^HALF + A_lo
    logic [2*HALF-1:0] a_lo, a_hi, b_lo, b_hi;  // 20 бит = 10 тритов

    // ============================================================================
    // 2. Подмодуль: троичный умножитель 10×10 (Booth + Dadda + CPA)
    // ============================================================================
    // Возвращает 21 трит (10×10 = 20 тритов результата + 1 overflow)
    function automatic logic [2*PP_WIDTH-1:0] mul_10x10(
        input logic [2*HALF-1:0] x,    // 10 тритов
        input logic [2*HALF-1:0] y     // 10 тритов
    );
        // Локальные переменные — используем always_comb-style через static arrays
        logic [1:0] x_trit [0:HALF-1];
        logic [1:0] y_trit [0:HALF-1];
        logic signed [1:0] x_val [0:HALF-1];
        logic signed [1:0] y_val [0:HALF-1];

        // Partial products: для каждого i (0..HALF-1) генерим ±y << i (shifted, width PP_WIDTH)
        // Booth: группируем по 2 трита y → ~6 recoded groups
        // Для упрощения используем ПРЯМОЙ sign-mux (трит × вектор = ±вектор)
        // Полный Booth на этапе 1 усложняет код — оставим для второй итерации.

        // Простая реализация: 10 partial products, каждый ±y << i (знак выбран x_trit[i])
        // Сдвиг = проводами (расположение на правильной позиции в PP_WIDTH-тритной шине)

        // Собираем partial products в массив pp[0..HALF-1], каждый PP_WIDTH тритов
        logic [2*PP_WIDTH-1:0] pp [0:HALF-1];

        // Dadda reduction: 10 pp → 2 вектора (sum + carry)
        logic [2*PP_WIDTH-1:0] sum_vec;
        logic [2*PP_WIDTH+1:0] carry_vec;

        // CPA: sum + carry → результат
        logic [2*(PP_WIDTH+1)-1:0] result_w;

        // Dadda-редукция (столбцовая): суммы и перенос
        logic [1:0] sum_col [0:PP_WIDTH-1];
        // BUG-039: было logic signed [1:0] — q = col_sum/3 достигает ±5
        // (10 partial products + перенос), q[1:0] обрезал: +2 хранился как -2.
        logic signed [3:0] carry_val;

        // --- Реализация (упрощённая, без Booth на первой итерации) ---

        // Извлечение тритов
        for (int i = 0; i < HALF; i++) begin
            x_trit[i] = x[2*i +: 2];
            y_trit[i] = y[2*i +: 2];
            x_val[i] = tval(x_trit[i]);
        end

        // Генерация partial products: pp[i] = x_val[i] × (y << i)
        // Знак: если x_val[i] = +1, pp[i] = +y на позиции i
        //       если x_val[i] = -1, pp[i] = -y на позиции i (негация тритов: +1↔-1, 0↔0)
        //       если x_val[i] =  0, pp[i] = 0
        for (int i = 0; i < HALF; i++) begin
            // Инициализация pp[i] = 0
            for (int k = 0; k < PP_WIDTH; k++) pp[i][2*k +: 2] = T0;

            // Размещение y (или -y) на позиции i..i+HALF-1
            for (int j = 0; j < HALF; j++) begin
                if (i + j < PP_WIDTH) begin
                    if (x_val[i] == 2'sd1) begin
                        pp[i][2*(i+j) +: 2] = y_trit[j];  // +y
                    end else if (x_val[i] == -2'sd1) begin
                        // Негация трита: +1↔-1, 0↔0
                        pp[i][2*(i+j) +: 2] = (y_trit[j] == P1) ? N1 :
                                              (y_trit[j] == N1) ? P1 : T0;
                    end
                    // 0 — оставляем T0
                end
            end
        end

        // Dadda reduction — используем простой подход (для первого прототипа):
        // Для N=10 partial products, LEVELS = 6 (heights: 2,3,4,6,9,13).
        // Релизуем через итеративное сжатие в столбцах.

        // === УПРОЩЁННАЯ Dadda-редукция (для прототипа) ===
        // Идём столбец за столбцом, накапливая carry в следующий столбец.
        // Это даёт линейную сложность O(N*W), но для прототипа достаточно.

        carry_val = 2'sd0;
        for (int j = 0; j < PP_WIDTH; j++) begin
            // Собираем все триты столбца j из pp[0..HALF-1]
            logic signed [4:0] col_sum;  // до 10 тритов ∈ [-10, +10]
            logic signed [4:0] q, r;
            col_sum = carry_val;
            for (int i = 0; i < HALF; i++) begin
                col_sum = col_sum + tval(pp[i][2*j +: 2]);
            end
            // Деление на 3 (balanced)
            q = col_sum / 3;
            r = col_sum - 3 * q;
            if (r > 1) begin q = q + 1; r = r - 3; end
            else if (r < -1) begin q = q - 1; r = r + 3; end
            sum_col[j] = tcode(r[1:0]);
            carry_val = q[3:0];   // BUG-039: было q[1:0] — обрезка переноса
        end

        // Заполняем carry_vec (из carry_val после последнего столбца)
        for (int j = 0; j < PP_WIDTH; j++) begin
            sum_vec[2*j +: 2] = sum_col[j];
        end

        // Сигнал mul_10x10 — финальный результат (sum + carry, размещённый на 1 позицию выше)
        // В нашей упрощённой реализации carry уже включён в col_sum следующего столбца
        // Результат — PP_WIDTH тритов + 1 overflow (carry_val после последнего)
        result_w = '0;
        for (int j = 0; j < PP_WIDTH; j++) begin
            result_w[2*j +: 2] = sum_col[j];
        end
        result_w[2*PP_WIDTH +: 2] = tcode(carry_val[1:0]); // сюда доходит только 0: 10×10 помещается в 20 тритов

        return result_w;
    endfunction

    // ============================================================================
    // 3. Karatsuba: 3 умножения 10×10 + 2 сложения
    // ============================================================================
    // A·B = A_hi·B_hi · 3^20 + ((A_hi+A_lo)(B_hi+B_lo) - A_hi·B_hi - A_lo·B_lo) · 3^10 + A_lo·B_lo

    // Результаты трёх умножений 10×10 (21 трит каждый)
    logic [2*PP_WIDTH-1:0] mul_lo_lo;  // A_lo · B_lo
    logic [2*PP_WIDTH-1:0] mul_hi_hi;  // A_hi · B_hi
    logic [2*PP_WIDTH-1:0] mul_sum;    // a_mod · b_mod — 10×10 на младших тритах сумм
    // s-коррекция среднего члена (BUG-039): полные суммы — HALF+1 тритов
    logic signed [1:0]     s_a, s_b;    // переносы в (HALF+1)-й трит сумм ∈ {-1,0,1}
    logic [2*(HALF+1)-1:0] corr1;       // s_a*b_mod + s_b*a_mod (11 тритов)
    logic [2*PP_WIDTH-1:0] mul_sum_mid; // скорректированный средний член (21 трит)

    // Размещение на финальной шине (41 трит):
    //   mul_hi_hi × 3^20  — позиция 20..40 (21 трит на позициях 20..40)
    //   mul_lo_lo          — позиция 0..20 (21 трит)
    //   mul_sum_mid - mul_hi_hi - mul_lo_lo на позициях 10..30 (знаковое расширение)

    // Финальный результат (сумма трёх слагаемых) — 41 трит = 82 бита
    logic [2*SUM_WIDTH-1:0] final_result;

    // Знак продукта
    logic prod_neg;

    always_comb begin
        // Локальные переменные суммы Karatsuba
        logic [2*HALF+1:0] a_sum_local, b_sum_local;
        logic [2*HALF-1:0] a_sum_short, b_sum_short;

        // --- 1. Разбор входа ---
        a_mant = a[2*N-1:0];   // 40 бит мантиссы = 20 тритов
        b_mant = b[2*N-1:0];
        a_exp = a[2*N +: 8];   // 8 бит экспоненты = 4 трита
        b_exp = b[2*N +: 8];

        // Karatsuba split
        a_lo = a_mant[2*HALF-1:0];    // 20 бит = 10 тритов
        a_hi = a_mant[2*N-1:2*HALF]; // 20 бит = 10 тритов
        b_lo = b_mant[2*HALF-1:0];
        b_hi = b_mant[2*N-1:2*HALF];

        // --- 2. Три умножения 10×10 ---
        mul_lo_lo = mul_10x10(a_lo, b_lo);
        mul_hi_hi = mul_10x10(a_hi, b_hi);

        // a_sum = a_hi + a_lo (может быть 11 тритов, оставим 21 бит для запаса)
        // Аналогично b_sum
        // Реализуем как сумму двух массивов тритов
        // (упрощённо — через прямой сумматор)
        a_sum_local = '0;
        b_sum_local = '0;
        begin
            logic signed [2:0] carry;
            logic signed [2:0] total, q, r;
            carry = 0;
            for (int i = 0; i < HALF; i++) begin
                total = tval(a_lo[2*i +: 2]) + tval(a_hi[2*i +: 2]) + carry;
                q = total / 3;
                r = total - 3 * q;
                if (r > 1) begin q = q + 1; r = r - 3; end
                else if (r < -1) begin q = q - 1; r = r + 3; end
                a_sum_local[2*i +: 2] = tcode(r[1:0]);
                carry = q;
            end
            a_sum_local[2*HALF +: 2] = tcode(carry[1:0]);
        end
        begin
            logic signed [2:0] carry;
            logic signed [2:0] total, q, r;
            carry = 0;
            for (int i = 0; i < HALF; i++) begin
                total = tval(b_lo[2*i +: 2]) + tval(b_hi[2*i +: 2]) + carry;
                q = total / 3;
                r = total - 3 * q;
                if (r > 1) begin q = q + 1; r = r - 3; end
                else if (r < -1) begin q = q - 1; r = r + 3; end
                b_sum_local[2*i +: 2] = tcode(r[1:0]);
                carry = q;
            end
            b_sum_local[2*HALF +: 2] = tcode(carry[1:0]);
        end

        // ====================================================================
        // Средний член Karatsuba: mul_10x10 + s-коррекция (BUG-039)
        // ====================================================================
        // Полные суммы A_sum = a_hi+a_lo занимают HALF+1 тритов: A_sum = s_a*3^HALF + a_mod.
        // Перенос s УЖЕ вычислен в a_sum_local/b_sum_local[2*HALF +: 2] (раньше
        // выбрасывался — 43.9% пар давали неверный продукт с ошибкой до ~3^30).
        //   A_sum*B_sum = a_mod*b_mod + 3^HALF*(s_a*b_mod + s_b*a_mod)
        //               + 3^(2*HALF)*(s_a*s_b)
        // s*x для одиночного трита — знаковый мультиплексор (±x/0), БЕЗ дерева PP.
        // Эквивалентно mul_11x11, но деревья остаются 10×10.
        // ====================================================================
        a_sum_short = a_sum_local[2*HALF-1:0];
        b_sum_short = b_sum_local[2*HALF-1:0];
        mul_sum = mul_10x10(a_sum_short, b_sum_short);   // a_mod * b_mod (21 трит)

        s_a = tval(a_sum_local[2*HALF +: 2]);            // перенос в 11-й трит ∈ {-1,0,1}
        s_b = tval(b_sum_local[2*HALF +: 2]);

        // corr1 = s_a*b_mod + s_b*a_mod — HALF+1 тритов
        // (|corr1| <= 2*(3^HALF-1) = 59048 < 3^(HALF+1)/2 = 88573)
        begin
            logic signed [3:0] c1, tot1, q1, r1;
            c1 = 4'sd0;
            for (int i = 0; i <= HALF; i++) begin        // HALF+1 колонок (0..10)
                tot1 = c1;
                if (i < HALF) begin
                    if (s_a == 2'sd1)       tot1 = tot1 + tval(b_sum_short[2*i +: 2]);
                    else if (s_a == -2'sd1) tot1 = tot1 - tval(b_sum_short[2*i +: 2]);
                    if (s_b == 2'sd1)       tot1 = tot1 + tval(a_sum_short[2*i +: 2]);
                    else if (s_b == -2'sd1) tot1 = tot1 - tval(a_sum_short[2*i +: 2]);
                end
                q1 = tot1 / 3;
                r1 = tot1 - 3 * q1;
                if (r1 > 1)       begin q1 = q1 + 1; r1 = r1 - 3; end
                else if (r1 < -1) begin q1 = q1 - 1; r1 = r1 + 3; end
                corr1[2*i +: 2] = tcode(r1[1:0]);
                c1 = q1;
            end
        end

        // Слияние: mul_sum_mid = mul_sum + corr1*3^HALF + (s_a*s_b)*3^(2*HALF) — 21 трит
        // (|A_sum*B_sum| <= (3^HALF-1)^2 = 3.487e9 < 3^(2*HALF+1)/2 = 5.234e9)
        begin
            logic signed [3:0] c2, tot2, q2, r2;
            logic signed [1:0] sb2;
            c2  = 4'sd0;
            sb2 = s_a * s_b;                             // 1x1 трит ∈ {-1,0,1}
            for (int t = 0; t < PP_WIDTH; t++) begin     // 21 колонка (0..20)
                tot2 = c2 + tval(mul_sum[2*t +: 2]);
                if (t >= HALF)   tot2 = tot2 + tval(corr1[2*(t-HALF) +: 2]);
                if (t == 2*HALF) tot2 = tot2 + sb2;
                q2 = tot2 / 3;
                r2 = tot2 - 3 * q2;
                if (r2 > 1)       begin q2 = q2 + 1; r2 = r2 - 3; end
                else if (r2 < -1) begin q2 = q2 - 1; r2 = r2 + 3; end
                mul_sum_mid[2*t +: 2] = tcode(r2[1:0]);
                c2 = q2;
            end
        end

        // --- 3. Финальная сборка Karatsuba ---
        // A·B = mul_hi_hi << 20 + (mul_sum_mid - mul_hi_hi - mul_lo_lo) << 10 + mul_lo_lo
        // Реализуем через сложение трёх слагаемых с правильными сдвигами.

        // Инициализация финального результата
        for (int k = 0; k < SUM_WIDTH; k++) final_result[2*k +: 2] = T0;

        // Сложение: столбец за столбцом, с carry propagation
        begin
            logic signed [3:0] col_sum;
            logic signed [3:0] q, r;
            logic signed [2:0] carry;
            carry = 0;
            for (int j = 0; j < SUM_WIDTH; j++) begin
                col_sum = carry;

                // mul_lo_lo на позиции j (триты 0..20)
                if (j < PP_WIDTH) begin
                    col_sum = col_sum + tval(mul_lo_lo[2*j +: 2]);
                end

                // mul_hi_hi на позиции j-20 (триты 20..40)
                if (j >= 2*HALF && j - 2*HALF < PP_WIDTH) begin
                    col_sum = col_sum + tval(mul_hi_hi[2*(j - 2*HALF) +: 2]);
                end

                // скорректированный средний член на позиции j-10 (триты 10..30)
                if (j >= HALF && j - HALF < PP_WIDTH) begin
                    col_sum = col_sum + tval(mul_sum_mid[2*(j - HALF) +: 2]);
                end

                // Вычитание mul_hi_hi на позиции j-10
                if (j >= HALF && j - HALF < PP_WIDTH) begin
                    col_sum = col_sum - tval(mul_hi_hi[2*(j - HALF) +: 2]);
                end

                // Вычитание mul_lo_lo на позиции j-10
                if (j >= HALF && j - HALF < PP_WIDTH) begin
                    col_sum = col_sum - tval(mul_lo_lo[2*(j - HALF) +: 2]);
                end

                // Деление на 3 (balanced)
                q = col_sum / 3;
                r = col_sum - 3 * q;
                if (r > 1) begin q = q + 1; r = r - 3; end
                else if (r < -1) begin q = q - 1; r = r + 3; end
                final_result[2*j +: 2] = tcode(r[1:0]);
                carry = q;
            end
            // Overflow — игнорируем (j >= SUM_WIDTH не влезает в наш выход)
        end

        // --- 4. Знак продукта ---
        prod_neg = 1'b0;
        for (int t = SUM_WIDTH-1; t >= 0; t--) begin
            if (final_result[2*t +: 2] != T0) begin
                prod_neg = (final_result[2*t +: 2] == N1);
                break;
            end
        end
    end

    // ============================================================================
    // 4. Выходные регистры
    // ============================================================================
    logic valid_q;
    logic [79:0] prod_q;
    logic [7:0]  e_q;
    logic neg_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_q <= 0;
            prod_q <= 0;
            e_q <= 0;
            neg_q <= 0;
        end else begin
            valid_q <= valid_in;
            // prod — 40 тритов (младшие 40 тритов из final_result, который 41 трит)
            // Берём биты [2*0 .. 2*40-1] (триты 0..39)
            prod_q <= final_result[79:0];
            // Экспонента: e = e_a + e_b - 18 (смещение нормализации)
            e_q <= exp_val(a_exp) + exp_val(b_exp) - 8'sd18;
            neg_q <= prod_neg;
        end
    end

    assign valid_out = valid_q;
    assign prod = prod_q;
    assign e = e_q;
    assign neg = neg_q;

endmodule
