// ============================================================================
// tfadd_raw.sv - adder для НЕНОРМАЛИЗОВАННЫХ продуктов TFloat48
// ============================================================================
// Вход: два продукта (prod 40 тритов, e, neg) из tfmul_raw.
// value = (-1)^neg * |prod| * 3^(e-18).
//   выравнивание: меньшая мантисса /3^(de) (round-half-up), e_sum = max
//   сложение мантисс (42 трита)
//   нормализация результата к [3^18, 3^19)
// Выход: нормализованный TFloat48 (48 бит).
// ============================================================================
module tfadd_raw (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [79:0] a_prod,
    input  logic signed [7:0]  a_e,
    input  logic        a_neg,
    input  logic [79:0] b_prod,
    input  logic signed [7:0]  b_e,
    input  logic        b_neg,
    output logic        valid_out,
    output logic [47:0] result
);
    localparam logic [1:0] P1 = 2'b01;
    localparam logic [1:0] N1 = 2'b10;
    localparam int W = 42;

    function automatic logic signed [2:0] trit_val2(input logic [1:0] c);
        case (c)
            P1: trit_val2 = 3'sd1;
            N1: trit_val2 = -3'sd1;
            default: trit_val2 = 3'sd0;
        endcase
    endfunction

    function automatic logic [1:0] int2trit2(input logic signed [2:0] v);
        case (v)
            3'sd1: int2trit2 = P1;
            -3'sd1: int2trit2 = N1;
            default: int2trit2 = 2'b00;
        endcase
    endfunction

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

    function automatic logic [39:0] msign_apply40(input logic [39:0] mag, input logic neg);
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
        msign_apply40 = out;
    endfunction

    // ---- комбинационные сигналы (от регистров m_big/m_small/sum) ----
    logic [2*W-1:0] m_big, m_small;
    logic [2*W-1:0] sum;

    // round-half-up /3 для m_small (знаковая) -> 42 трита
    logic [2*W-1:0] rhu_next;
    always_comb begin
        rhu_next = 0;
        begin
            logic sign_neg;
            logic [2*W-1:0] mag;
            sign_neg = 1'b0;
            for (int t = W-1; t >= 0; t--)
                if (m_small[2*t +: 2] != 2'b00) begin
                    sign_neg = (m_small[2*t +: 2] == N1);
                    break;
                end
            mag = m_small;
            if (sign_neg) begin
                for (int t = 0; t < W; t++) begin
                    logic [1:0] inv;
                    inv = (m_small[2*t +: 2] == P1) ? N1 :
                          (m_small[2*t +: 2] == N1) ? P1 : 2'b00;
                    mag[2*t +: 2] = inv;
                end
            end
            begin
                logic [2*W-1:0] mp1;
                logic [1:0] carry;
                logic [2*W-1:0] fd;
                mp1 = mag;
                carry = P1;
                for (int t = 0; t < W && carry != 2'b00; t++) begin
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
                fd = 0;
                for (int t = 0; t < W-1; t++)
                    fd[2*t +: 2] = mp1[2*(t+1) +: 2];
                fd[2*(W-1) +: 2] = 2'b00;
                if (mp1[1:0] == N1) begin
                    carry = N1;
                    for (int t = 0; t < W && carry != 2'b00; t++) begin
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
                rhu_next = fd;
                if (sign_neg) begin
                    for (int t = 0; t < W; t++) begin
                        logic [1:0] inv;
                        inv = (fd[2*t +: 2] == P1) ? N1 :
                              (fd[2*t +: 2] == N1) ? P1 : 2'b00;
                        rhu_next[2*t +: 2] = inv;
                    end
                end
            end
        end
    end

    // поразрядное сложение m_big + m_small (42 трита)
    logic [2*W-1:0] add_mant;
    logic sum_sign;
    always_comb begin
        begin
            logic signed [2:0] carry;
            carry = 3'sd0;
            for (int t = 0; t < W; t++) begin
                logic signed [2:0] sv;
                logic [1:0] out_t;
                sv = trit_val2(m_big[2*t +: 2]) + trit_val2(m_small[2*t +: 2]) + carry;
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
                add_mant[2*t +: 2] = out_t;
            end
        end
        sum_sign = 1'b0;
        for (int t = W-1; t >= 0; t--)
            if (add_mant[2*t +: 2] != 2'b00) begin
                sum_sign = (add_mant[2*t +: 2] == N1);
                break;
            end
    end

    // |sum| и знак
    logic sum_neg_r;
    logic [2*W-1:0] sum_abs;
    always_comb begin
        sum_neg_r = 1'b0;
        for (int t = W-1; t >= 0; t--)
            if (sum[2*t +: 2] != 2'b00) begin
                sum_neg_r = (sum[2*t +: 2] == N1);
                break;
            end
        sum_abs = sum;
        if (sum_neg_r) begin
            for (int t = 0; t < W; t++) begin
                logic [1:0] inv;
                inv = (sum[2*t +: 2] == P1) ? N1 :
                      (sum[2*t +: 2] == N1) ? P1 : 2'b00;
                sum_abs[2*t +: 2] = inv;
            end
        end
    end

    logic [2*W-1:0] fd3_abs;
    always_comb begin
        fd3_abs = 0;
        for (int t = 0; t < W-1; t++)
            fd3_abs[2*t +: 2] = sum_abs[2*(t+1) +: 2];
        fd3_abs[2*(W-1) +: 2] = 2'b00;
        if (sum_abs[1:0] == N1) begin
            logic [1:0] carry;
            carry = N1;
            for (int t = 0; t < W && carry != 2'b00; t++) begin
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

    logic [2*W-1:0] mul3_abs;
    always_comb begin
        mul3_abs = 0;
        for (int t = 0; t < W-1; t++)
            mul3_abs[2*(t+1) +: 2] = sum_abs[2*t +: 2];
        mul3_abs[1:0] = 2'b00;
    end

    // знаковые варианты fd3_abs/mul3_abs (знак из sum_neg_r)
    logic [2*W-1:0] fd3_s, mul3_s;
    always_comb begin
        fd3_s = fd3_abs;
        mul3_s = mul3_abs;
        if (sum_neg_r) begin
            for (int t = 0; t < W; t++) begin
                logic [1:0] inv_f, inv_m;
                inv_f = (fd3_abs[2*t +: 2] == P1) ? N1 :
                        (fd3_abs[2*t +: 2] == N1) ? P1 : 2'b00;
                inv_m = (mul3_abs[2*t +: 2] == P1) ? N1 :
                        (mul3_abs[2*t +: 2] == N1) ? P1 : 2'b00;
                fd3_s[2*t +: 2] = inv_f;
                mul3_s[2*t +: 2] = inv_m;
            end
        end
    end

    logic signed [63:0] val_abs;
    always_comb begin
        val_abs = 64'sd0;
        for (int t = W-1; t >= 0; t--)
            val_abs = val_abs * 3 + trit_val2(sum_abs[2*t +: 2]);
    end
    logic val_ge_p19, val_lt_p18, val_zero;
    assign val_ge_p19 = (val_abs >= 64'sd1162261467);
    assign val_lt_p18 = (val_abs < 64'sd387420489);
    assign val_zero = (val_abs == 64'sd0);

    // ---- FSM ----
    localparam int PH_IDLE = 0;
    localparam int PH_INIT = 1;
    localparam int PH_ALGN = 2;
    localparam int PH_ADD  = 3;
    localparam int PH_NORM = 4;
    localparam int PH_DONE = 5;

    logic [2:0] phase;
    logic [5:0] cnt;
    logic signed [7:0] m_big_e, m_small_e;
    logic signed [7:0] e_sum;
    logic [47:0] result_q;
    logic valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE;
            cnt <= 0; m_big <= 0; m_small <= 0; e_sum <= 0;
            m_big_e <= 0; m_small_e <= 0;
            sum <= 0; result_q <= 0; valid_q <= 0;
        end else begin
            valid_q <= 0;
            case (phase)
                PH_IDLE: begin
                    if (valid_in) begin
                        if (a_e > b_e) begin
                            m_big <= {2'b00, a_prod};
                            m_small <= {2'b00, b_prod};
                            m_big_e <= a_e;
                            m_small_e <= b_e;
                            cnt <= a_e - b_e;
                        end else begin
                            m_big <= {2'b00, b_prod};
                            m_small <= {2'b00, a_prod};
                            m_big_e <= b_e;
                            m_small_e <= a_e;
                            cnt <= b_e - a_e;
                        end
                        phase <= PH_INIT;
                    end
                end
                PH_INIT: begin
                    e_sum <= m_big_e;
                    if (cnt > 22) cnt <= 22;
                    phase <= PH_ALGN;
                end
                PH_ALGN: begin
                    if (cnt > 0) begin
                        m_small <= rhu_next;
                        cnt <= cnt - 1;
                    end else begin
                        phase <= PH_ADD;
                    end
                end
                PH_ADD: begin
                    sum <= add_mant;
                    phase <= PH_NORM;
                end
                PH_NORM: begin
                    if (val_zero) begin
                        phase <= PH_DONE;
                    end else if (e_sum > 8'sd40) begin
                        phase <= PH_DONE;
                    end else if (val_ge_p19) begin
                        sum <= fd3_s;
                        e_sum <= e_sum + 1;
                    end else if (val_lt_p18 && e_sum > -8'sd40) begin
                        sum <= mul3_s;
                        e_sum <= e_sum - 1;
                    end else begin
                        phase <= PH_DONE;
                    end
                end
                PH_DONE: begin
                    if (val_zero || e_sum < -8'sd40) begin
                        result_q <= 48'h0;
                    end else if (e_sum > 8'sd40) begin
                        result_q <= {8'hFF, 40'hFFFFFFFFFF};
                    end else begin
                        result_q <= {exp_code(e_sum[7:0]),
                                     msign_apply40(sum_abs[39:0], sum_neg_r)};
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
