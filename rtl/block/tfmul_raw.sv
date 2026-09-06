// ============================================================================
// tfmul_raw.sv — параллельный умножитель TFloat48 (carry-save pipeline)
// ============================================================================
// Аккумуляция partial product через carry-save: per-column parallel,
// carry_next[t] идёт в carry_r[t] на следующем такте (1 такт, не цепочка).
// Глубина: ~15 LUT/колонку (3×tv + 3-входовой сумматор + div3 + enc)
// Вместо 40-тритной carry chain (263 уровня, BUG-037).
// Финальная сборка: sum_r + carry_r, 2 трита/такт, 20 тактов.
// ============================================================================
module tfmul_raw (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [47:0] a,
    input  logic [47:0] b,
    output logic        valid_out,
    output logic [79:0] prod,
    output logic [7:0]  e,
    output logic        neg
);
    localparam logic [1:0] P1 = 2'b01, N1 = 2'b10;

    function logic signed [2:0] tv(input logic [1:0] c);
        case (c) P1: return 3'sd1; N1: return -3'sd1; default: return 3'sd0; endcase
    endfunction
    function logic [1:0] i2t(input logic signed [2:0] v);
        case (v) 3'sd1: return 2'b01; -3'sd1: return 2'b10; default: return 2'b00; endcase
    endfunction
    function logic signed [7:0] exp_val(input logic [7:0] x);
        logic signed [7:0] v = 8'sd0;
        for (int i = 3; i >= 0; i--) v = v * 3 + tv(x[2*i +: 2]);
        return v;
    endfunction

    localparam int PH_IDLE = 0, PH_INIT = 1, PH_MUL = 2, PH_FIN = 3, PH_DONE = 4;
    logic [2:0] phase;
    logic [5:0] cnt, fcnt;
    logic [79:0] sum_r, carry_r, fin_r;
    logic signed [2:0] fin_carry;
    logic [1:0] last_trit;
    logic signed [7:0] e_r;
    logic [39:0] a_mr, b_mr;
    logic [7:0] a_er, b_er;
    logic [15:0] partial_q;
    logic signed [6:0] shift_q;

    logic [7:0] am_b[0:4], bm_b[0:4];
    always_comb begin
        for (int i = 0; i < 5; i++) begin am_b[i] = a_mr[8*i+:8]; bm_b[i] = b_mr[8*i+:8]; end
    end
    logic [2:0] mul_i, mul_j;
    assign mul_i = cnt / 5;
    assign mul_j = cnt % 5;
    logic [15:0] partial;
    tbyte_mul u_mul(.a(am_b[mul_i]), .b(bm_b[mul_j]), .prod(partial));
    logic signed [6:0] shift_cur;
    assign shift_cur = (mul_i + mul_j) * 4;

    // ---- carry-save: per-column, НЕТ carry chain ----
    // Сумма 3 тритов: tot = sum_r[t] + carry_r[t] + partial[t] (∈ [-3,3])
    // sum_next[t] = tot mod 3 (balanced), carry_next[t+1] = tot div 3
    // Перенос уезжает на 1 столбец ВЫШЕ и попадает в carry_r[t+1] на след. такте.
    logic [79:0] sum_n, carry_n;
    always_comb begin
        for (int t = 0; t < 40; t++) begin
            logic [1:0] pv = 2'b00;
            if (t >= shift_q && t < shift_q + 8)
                pv = partial_q[2*(t-shift_q)+:2];
            logic signed [3:0] tot = tv(sum_r[2*t+:2]) + tv(carry_r[2*t+:2]) + tv(pv);
            logic signed [2:0] q = tot / 3;
            logic signed [2:0] r = tot - 3*q;
            if (r > 1) begin q = q+1; r = r-3; end else if (r < -1) begin q = q-1; r = r+3; end
            sum_n[2*t+:2] = i2t(r);
            if (t < 39)
                carry_n[2*(t+1)+:2] = i2t(q);
        end
        carry_n[1:0] = 2'b00;  // перенос в столбец 0 нет
    end

    // ---- финальная сборка: 2 трита/такт ----
    logic [79:0] fin_n;
    logic signed [2:0] fin_carry_n;
    logic [1:0] last_n;
    always_comb begin
        fin_n = fin_r;
        fin_carry_n = fin_carry;
        last_n = last_trit;
        for (int k = 0; k < 2; k++) begin
            int t = 2*fcnt + k;
            if (t < 40) begin
                logic signed [3:0] tot = fin_carry_n + tv(sum_r[2*t+:2]) + tv(carry_r[2*t+:2]);
                logic signed [2:0] q = tot / 3;
                logic signed [2:0] r = tot - 3*q;
                if (r > 1) begin q = q+1; r = r-3; end else if (r < -1) begin q = q-1; r = r+3; end
                fin_n[2*t+:2] = i2t(r);
                fin_carry_n = q;
                if (r != 0) last_n = i2t(r);
            end
        end
    end

    logic valid_q, neg_q;
    logic [79:0] prod_q;
    logic [7:0] e_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE; cnt <= 0; fcnt <= 0;
            sum_r <= 0; carry_r <= 0; fin_r <= 0;
            fin_carry <= 0; last_trit <= 0;
            partial_q <= 0; e_r <= 0;
            a_mr <= 0; b_mr <= 0; a_er <= 0; b_er <= 0;
            valid_q <= 0; prod_q <= 0; e_q <= 0; neg_q <= 0;
        end else begin
            valid_q <= 0;
            case (phase)
                PH_IDLE: if (valid_in) begin
                    a_mr <= a[39:0]; b_mr <= b[39:0];
                    a_er <= a[47:40]; b_er <= b[47:40];
                    phase <= PH_INIT;
                end
                PH_INIT: begin
                    cnt <= 0; fcnt <= 0; sum_r <= 0; carry_r <= 0; fin_r <= 0;
                    fin_carry <= 0; last_trit <= 0;
                    e_r <= exp_val(a_er) + exp_val(b_er) - 8'sd18;
                    phase <= PH_MUL;
                end
                PH_MUL: begin
                    sum_r <= sum_n; carry_r <= carry_n;
                    partial_q <= partial; shift_q <= shift_cur;
                    if (cnt == 25) begin
                        phase <= PH_FIN;
                        fcnt <= 0; fin_carry <= 0; last_trit <= 0;
                    end else cnt <= cnt + 1;
                end
                PH_FIN: begin
                    fin_r <= fin_n; fin_carry <= fin_carry_n; last_trit <= last_n;
                    if (fcnt == 19) phase <= PH_DONE;
                    else fcnt <= fcnt + 1;
                end
                PH_DONE: begin
                    neg_q <= (last_trit == N1); prod_q <= fin_r;
                    e_q <= e_r; valid_q <= 1; phase <= PH_IDLE;
                end
            endcase
        end
    end

    assign prod = prod_q; assign e = e_q; assign neg = neg_q; assign valid_out = valid_q;
endmodule