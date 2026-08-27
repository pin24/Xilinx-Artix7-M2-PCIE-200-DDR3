// ============================================================================
// tfmac.sv - MAC-блок TFloat48 (M=20 тритов=5 байт, E=4 трита=1 байт)
// ============================================================================
// value = M * 3^(e-18), M in [3^18, 3^19), e = decode(E) (bias 40).
// 48 бит = 6 байт: byte[5]=E, byte[4..0]=M (byte0 = младшие триты).
//
// Ресурсо-оптимально: ОДИН tbyte_mul (переиспользуется), последовательная
// аккумуляция 25 частичных произведений, FSM-фазы.
//   mul: M = Ma*Mb/3^19 (норм.), e = ea+eb-18
//   add: выравнивание (round-half-up /3^k) + поразрядное сложение, норм.
// Нормализация: floor_div3 (сдвиг тритов + коррекция), пока |M|>=3^19;
//               *3 пока |M|<3^18.
// ============================================================================
module tfmac (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic        op,          // 0=mul, 1=add
    input  logic [47:0] a,           // {E(8), M(40)}
    input  logic [47:0] b,
    output logic        valid_out,
    output logic [47:0] result
);
    localparam logic [1:0] P1 = 2'b01;
    localparam logic [1:0] N1 = 2'b10;

    // --- декодирование ---
    logic [39:0] a_m, b_m;
    logic [7:0]  a_e, b_e;
    assign a_m = a[39:0];
    assign b_m = b[39:0];
    assign a_e = a[47:40];
    assign b_e = b[47:40];

    // трит -> значение
    function automatic logic signed [2:0] trit_val2(input logic [1:0] c);
        case (c)
            P1: trit_val2 = 3'sd1;
            N1: trit_val2 = -3'sd1;
            default: trit_val2 = 3'sd0;
        endcase
    endfunction

    // значение -> трит (код)
    function automatic logic [1:0] int2trit2(input logic signed [2:0] v);
        case (v)
            3'sd1: int2trit2 = P1;
            -3'sd1: int2trit2 = N1;
            default: int2trit2 = 2'b00;
        endcase
    endfunction

    // 4 трита экспоненты -> signed int
    function automatic logic signed [7:0] exp_val(input logic [7:0] x);
        logic signed [7:0] v;
        v = 8'sd0;
        for (int i = 3; i >= 0; i--)
            v = v * 3 + trit_val2(x[2*i +: 2]);
        exp_val = v;
    endfunction

    // signed int -> 4 трита экспоненты
    function automatic logic [7:0] exp_code(input logic signed [7:0] v);
        logic signed [7:0] x;
        logic [7:0] out;
        x = v;
        for (int i = 0; i < 4; i++) begin
            logic signed [7:0] q;
            logic signed [2:0] rv;
            logic [1:0] rcode;
            q = x / 3;
            rv = x - 3*q;
            if (rv == 2) begin rcode = 2'b10; q = q + 1; end
            else if (rv == -2) begin rcode = 2'b01; q = q - 1; end
            else if (rv == 1) rcode = 2'b01;
            else if (rv == -1) rcode = 2'b10;
            else rcode = 2'b00;
            out[2*i +: 2] = rcode;
            x = q;
        end
        exp_code = out;
    endfunction

    // применение знака к мантиссе (20 тритов): -x = инверсия тритов (без +1)
    function automatic logic [39:0] msign_apply(input logic [39:0] mag, input logic neg);
        logic [39:0] out;
        out = mag;
        if (neg) begin
            for (int t = 0; t < 20; t++) begin
                logic [1:0] inv;
                inv = (mag[2*t +: 2] == P1) ? N1 :
                      (mag[2*t +: 2] == N1) ? P1 : 2'b00;
                out[2*t +: 2] = inv;
            end
        end
        msign_apply = out;
    endfunction

    // --- FSM ---
    localparam int PH_IDLE = 0;
    localparam int PH_INIT = 1;
    localparam int PH_MUL  = 2;
    localparam int PH_ALGN = 3;   // выравнивание add
    localparam int PH_ADD  = 4;
    localparam int PH_NORM = 5;
    localparam int PH_DONE = 6;

    logic [2:0] phase;
    logic [5:0] cnt;          // счётчик
    logic [79:0] prod;        // 40 тритов (трит t = [2t+1:2t])
    logic signed [7:0] e;     // троичная экспонента
    logic [39:0] m_keep;      // мантисса "большей" экспоненты (add)
    logic [39:0] m_shift;     // мантисса для сдвига (add)
    logic [39:0] a_mr, b_mr;  // зарегистрированные мантиссы
    logic [7:0]  a_er, b_er;  // зарегистрированные экспоненты
    logic op_r;
    logic signed [7:0] e_final;
    logic [7:0] e_code;

    // частичное произведение (tbyte_mul)
    logic [15:0] partial;
    logic [1:0] am_byte0, am_byte1, am_byte2, am_byte3, am_byte4;
    logic [1:0] bm_byte0, bm_byte1, bm_byte2, bm_byte3, bm_byte4;
    logic [7:0] am_b [0:4];
    logic [7:0] bm_b [0:4];
    always_comb begin
        am_b[0] = a_m[7:0]; am_b[1] = a_m[15:8]; am_b[2] = a_m[23:16];
        am_b[3] = a_m[31:24]; am_b[4] = a_m[39:32];
        bm_b[0] = b_m[7:0]; bm_b[1] = b_m[15:8]; bm_b[2] = b_m[23:16];
        bm_b[3] = b_m[31:24]; bm_b[4] = b_m[39:32];
    end

    // i = cnt/5, j = cnt%5 (индексы байтов)
    logic [2:0] mul_i, mul_j;
    assign mul_i = cnt / 5;
    assign mul_j = cnt % 5;

    tbyte_mul u_mul (
        .a(am_b[mul_i]),
        .b(bm_b[mul_j]),
        .prod(partial)
    );

    // добавление 8 тритов partial на позицию 4*(i+j) трит
    logic [79:0] prod_next;
    logic [5:0] shift_t;
    always_comb begin
        shift_t = (mul_i + mul_j) * 4;
        prod_next = prod;
        begin
            logic signed [2:0] carry;
            carry = 3'sd0;
            for (int t = 0; t < 40; t++) begin
                logic [1:0] pv;
                logic signed [2:0] sv;
                logic [1:0] trit_v;
                logic [1:0] out_t;
                if (t >= shift_t && t < shift_t + 8)
                    pv = partial[2*(t - shift_t) +: 2];
                else
                    pv = 2'b00;
                sv = trit_val2(prod[2*t +: 2]) + trit_val2(pv) + carry;
                // balanced
                if (sv > 1) begin
                    carry = 3'sd1;
                    out_t = int2trit2(sv - 3);
                end else if (sv < -1) begin
                    carry = -3'sd1;
                    out_t = int2trit2(sv + 3);
                end else begin
                    carry = 3'sd0;
                    out_t = int2trit2(sv);
                end
                prod_next[2*t +: 2] = out_t;
            end
        end
    end

    // floor_div3 (40 тритов): сдвиг вниз + (-1 если младший трит == -1)
    logic [79:0] fd3_next;
    always_comb begin
        fd3_next = 80'h0;
        begin
            // сдвиг тритов вниз: fd3[t] = prod[t+1]
            for (int t = 0; t < 39; t++)
                fd3_next[2*t +: 2] = prod[2*(t+1) +: 2];
            fd3_next[78 +: 2] = 2'b00;
            // если младший трит == -1: вычесть 1 (добавить N1 с переносом)
            if (prod[1:0] == N1) begin
                logic [1:0] carry;
                carry = N1;
                for (int t = 0; t < 40 && carry != 2'b00; t++) begin
                    logic signed [2:0] sv;
                    sv = trit_val2(fd3_next[2*t +: 2]) + trit_val2(carry);
                    if (sv > 1) begin
                        fd3_next[2*t +: 2] = int2trit2(sv - 3);
                        carry = P1;
                    end else if (sv < -1) begin
                        fd3_next[2*t +: 2] = int2trit2(sv + 3);
                        carry = N1;
                    end else begin
                        fd3_next[2*t +: 2] = int2trit2(sv);
                        carry = 2'b00;
                    end
                end
            end
        end
    end

    // *3 (сдвиг вверх, младший трит 0)
    logic [79:0] mul3_next;
    always_comb begin
        mul3_next = 80'h0;
        for (int t = 0; t < 39; t++)
            mul3_next[2*(t+1) +: 2] = prod[2*t +: 2];
        mul3_next[1:0] = 2'b00;
    end

    // поразрядное сложение m_keep + m_shift (для add), результат 40 тритов
    logic [79:0] add_sum;
    always_comb begin
        begin
            logic signed [2:0] carry;
            carry = 3'sd0;
            for (int t = 0; t < 40; t++) begin
                logic signed [2:0] sv;
                logic [1:0] out_t;
                logic signed [2:0] av, bv;
                av = (t < 20) ? trit_val2(m_keep[2*t +: 2]) : 3'sd0;
                bv = (t < 20) ? trit_val2(m_shift[2*t +: 2]) : 3'sd0;
                sv = av + bv + carry;
                if (sv > 1) begin
                    carry = 3'sd1;
                    out_t = int2trit2(sv - 3);
                end else if (sv < -1) begin
                    carry = -3'sd1;
                    out_t = int2trit2(sv + 3);
                end else begin
                    carry = 3'sd0;
                    out_t = int2trit2(sv);
                end
                add_sum[2*t +: 2] = out_t;
            end
        end
    end

    // знак суммы add (по старшему значимому триту)
    logic add_neg;
    always_comb begin
        add_neg = 1'b0;
        for (int t = 39; t >= 0; t--)
            if (add_sum[2*t +: 2] != 2'b00) begin
                add_neg = (add_sum[2*t +: 2] == N1);
                break;
            end
    end

    // позиция старшего ненулевого трита (0..39, 63 если все 0) - для норм
    logic [5:0] msb;
    always_comb begin
        msb = 6'd63;
        for (int t = 39; t >= 0; t--)
            if (prod[2*t +: 2] != 2'b00) begin msb = t; break; end
    end

    // round-half-up /3 для выравнивания (младшие 40 тритов m_shift)
    logic [79:0] rhu_next;
    always_comb begin
        rhu_next = 80'h0;
        begin
            logic signed [2:0] carry;
            // round-half-up деление на 3: для x>=0: (x+1)/3; для x<0: -((-x+1)/3)
            // в тритах: прибавляем "половину" (сложно). Используем знак:
            // если число положительное: сдвиг + округление вверх при остатке
            // Упрощение (как эталон _shift_right_int k=1): 
            //   x>=0: (x+1)/3 floor;  x<0: -((-x+1)/3 floor)
            // Реализуем через floor_div3 с предварительным +1 (для >=0)
            // Определим знак по старшему значимому триту:
            logic sign_neg;
            logic [39:0] mag_next;
            sign_neg = 1'b0;
            for (int t = 19; t >= 0; t--)
                if (m_shift[2*t +: 2] != 2'b00) begin
                    sign_neg = (m_shift[2*t +: 2] == N1);
                    break;
                end
            // |x|: для balanced -x = инверсия тритов (без +1)
            mag_next = m_shift;
            if (sign_neg) begin
                for (int t = 0; t < 20; t++) begin
                    logic [1:0] inv;
                    inv = (m_shift[2*t +: 2] == P1) ? N1 :
                          (m_shift[2*t +: 2] == N1) ? P1 : 2'b00;
                    mag_next[2*t +: 2] = inv;
                end
            end
            // (mag+1)/3 floor: mag+1 затем floor_div3
            begin
                logic [79:0] mp1;
                logic [1:0] carry;
                logic [79:0] fd;
                mp1 = {40'h0, mag_next};
                carry = P1;
                for (int t = 0; t < 40 && carry != 2'b00; t++) begin
                    logic signed [2:0] sv;
                    sv = trit_val2(mp1[2*t +: 2]) + trit_val2(carry);
                    if (sv > 1) begin
                        mp1[2*t +: 2] = int2trit2(sv - 3);
                        carry = P1;
                    end else if (sv < -1) begin
                        mp1[2*t +: 2] = int2trit2(sv + 3);
                        carry = N1;
                    end else begin
                        mp1[2*t +: 2] = int2trit2(sv);
                        carry = 2'b00;
                    end
                end
                // floor_div3(mp1): сдвиг + коррекция
                fd = 80'h0;
                for (int t = 0; t < 39; t++)
                    fd[2*t +: 2] = mp1[2*(t+1) +: 2];
                fd[78 +: 2] = 2'b00;
                if (mp1[1:0] == N1) begin
                    carry = N1;
                    for (int t = 0; t < 40 && carry != 2'b00; t++) begin
                        logic signed [2:0] sv;
                        sv = trit_val2(fd[2*t +: 2]) + trit_val2(carry);
                        if (sv > 1) begin
                            fd[2*t +: 2] = int2trit2(sv - 3);
                            carry = P1;
                        end else if (sv < -1) begin
                            fd[2*t +: 2] = int2trit2(sv + 3);
                            carry = N1;
                        end else begin
                            fd[2*t +: 2] = int2trit2(sv);
                            carry = 2'b00;
                        end
                    end
                end
                // результат: sign_neg ? -(fd) : fd
                rhu_next = fd;
                if (sign_neg) begin
                    logic [1:0] c2;
                    for (int t = 0; t < 40; t++) begin
                        logic [1:0] inv;
                        inv = (fd[2*t +: 2] == P1) ? N1 :
                              (fd[2*t +: 2] == N1) ? P1 : 2'b00;
                        rhu_next[2*t +: 2] = inv;
                    end
                end
            end
        end
    end

    logic valid_q;
    logic [47:0] result_q;
    localparam logic [7:0] TOTAL_ERR8 = 8'hFF;
    localparam logic [39:0] TOTAL_ERR40 = 40'hFFFFFFFFFF;

    // знак prod (по старшему значимому триту)
    logic prod_neg;
    always_comb begin
        prod_neg = 1'b0;
        for (int t = 39; t >= 0; t--)
            if (prod[2*t +: 2] != 2'b00) begin
                prod_neg = (prod[2*t +: 2] == N1);
                break;
            end
    end

    // знак prod_next (аккумулированного произведения)
    logic prod_next_neg;
    always_comb begin
        prod_next_neg = 1'b0;
        for (int t = 39; t >= 0; t--)
            if (prod_next[2*t +: 2] != 2'b00) begin
                prod_next_neg = (prod_next[2*t +: 2] == N1);
                break;
            end
    end

    // |prod|: для balanced ternary -x = инверсия тритов (0->0, +-1 <-> -+1), без +1
    logic [79:0] prod_abs;
    always_comb begin
        prod_abs = prod;
        if (prod_neg) begin
            for (int t = 0; t < 40; t++) begin
                logic [1:0] inv;
                inv = (prod[2*t +: 2] == P1) ? N1 :
                      (prod[2*t +: 2] == N1) ? P1 : 2'b00;
                prod_abs[2*t +: 2] = inv;
            end
        end
    end

    // floor_div3 для ПОЛОЖИТЕЛЬНОГО (prod_abs): сдвиг + (-1 если младший == -1)
    logic [79:0] fd3_abs;
    always_comb begin
        fd3_abs = 80'h0;
        for (int t = 0; t < 39; t++)
            fd3_abs[2*t +: 2] = prod_abs[2*(t+1) +: 2];
        fd3_abs[78 +: 2] = 2'b00;
        if (prod_abs[1:0] == N1) begin
            logic [1:0] carry;
            carry = N1;
            for (int t = 0; t < 40 && carry != 2'b00; t++) begin
                logic signed [2:0] sv;
                sv = trit_val2(fd3_abs[2*t +: 2]) + trit_val2(carry);
                if (sv > 1) begin
                    fd3_abs[2*t +: 2] = int2trit2(sv - 3);
                    carry = P1;
                end else if (sv < -1) begin
                    fd3_abs[2*t +: 2] = int2trit2(sv + 3);
                    carry = N1;
                end else begin
                    fd3_abs[2*t +: 2] = int2trit2(sv);
                    carry = 2'b00;
                end
            end
        end
    end

    // *3 (сдвиг вверх, младший трит 0) для prod_abs
    logic [79:0] mul3_abs;
    always_comb begin
        mul3_abs = 80'h0;
        for (int t = 0; t < 39; t++)
            mul3_abs[2*(t+1) +: 2] = prod_abs[2*t +: 2];
        mul3_abs[1:0] = 2'b00;
    end

    // позиция старшего ненулевого трита prod_abs (63 если 0)
    logic [5:0] msb_abs;
    always_comb begin
        msb_abs = 6'd63;
        for (int t = 39; t >= 0; t--)
            if (prod_abs[2*t +: 2] != 2'b00) begin msb_abs = t; break; end
    end

    // значение prod_abs (signed 64 бит) для сравнения с 3^19/3^18
    logic signed [63:0] val_abs;
    always_comb begin
        val_abs = 64'sd0;
        for (int t = 39; t >= 0; t--)
            val_abs = val_abs * 3 + trit_val2(prod_abs[2*t +: 2]);
    end
    logic val_ge_p19, val_lt_p18, val_zero;
    assign val_ge_p19 = (val_abs >= 64'sd1162261467);   // 3^19
    assign val_lt_p18 = (val_abs < 64'sd387420489);      // 3^18
    assign val_zero = (val_abs == 64'sd0);

    logic msign;   // знак результата (захвачен при входе в NORM)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE;
            cnt <= 0; prod <= 0; e <= 0;
            m_keep <= 0; m_shift <= 0;
            valid_q <= 0; result_q <= 0;
            e_code <= 0; e_final <= 0;
            a_mr <= 0; b_mr <= 0; a_er <= 0; b_er <= 0; op_r <= 0;
            msign <= 0;
        end else begin
            valid_q <= 0;
            case (phase)
                PH_IDLE: begin
                    if (valid_in) begin
                        // захват входов (устраняет гонку continuous assign)
                        a_mr <= a[39:0];
                        b_mr <= b[39:0];
                        a_er <= a[47:40];
                        b_er <= b[47:40];
                        op_r <= op;
                        phase <= PH_INIT;
                    end
                end
                PH_INIT: begin
                    if (op_r == 0) begin
                        phase <= PH_MUL;
                        cnt <= 0;
                        prod <= 0;
                        e <= exp_val(a_er) + exp_val(b_er) - 8'sd18;
                    end else begin
                        // add: выравнивание
                        if (exp_val(a_er) > exp_val(b_er)) begin
                            m_keep <= a_mr;
                            m_shift <= b_mr;
                            e <= exp_val(a_er);
                            cnt <= exp_val(a_er) - exp_val(b_er);
                        end else begin
                            m_keep <= b_mr;
                            m_shift <= a_mr;
                            e <= exp_val(b_er);
                            cnt <= exp_val(b_er) - exp_val(a_er);
                        end
                        phase <= PH_ALGN;
                    end
                end
                PH_MUL: begin
                    prod <= prod_next;
                    if (cnt == 24) begin
                        msign <= prod_next_neg;
                        phase <= PH_NORM;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end
                PH_ALGN: begin
                    if (cnt > 0) begin
                        m_shift <= rhu_next[39:0];
                        cnt <= cnt - 1;
                    end else begin
                        phase <= PH_ADD;
                    end
                end
                PH_ADD: begin
                    prod <= add_sum;
                    msign <= add_neg;
                    phase <= PH_NORM;
                end
                PH_NORM: begin
                    if (val_zero) begin
                        // ноль
                        phase <= PH_DONE;
                    end else if (e > 8'sd40) begin
                        // overflow -> ERR (все триты 11)
                        phase <= PH_DONE;
                    end else if (val_ge_p19) begin
                        prod <= fd3_abs;
                        e <= e + 1;
                    end else if (val_lt_p18 && e > -8'sd40) begin
                        prod <= mul3_abs;
                        e <= e - 1;
                    end else begin
                        phase <= PH_DONE;
                    end
                end
                PH_DONE: begin
                    if (val_zero || e < -8'sd40) begin
                        result_q <= 48'h0;
                    end else if (e > 8'sd40) begin
                        result_q <= {TOTAL_ERR8, TOTAL_ERR40};
                    end else begin
                        result_q <= {exp_code(e[7:0]), msign_apply(prod_abs[39:0], msign)};
                    end
                    valid_q <= 1;
                    phase <= PH_IDLE;
                end
            endcase
        end
    end

    assign valid_out = valid_q;
    assign result = result_q;

endmodule
