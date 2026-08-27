// ============================================================================
// tfmul.sv - параллельный умножитель TFloat48 (mul-only часть tfmac)
// ============================================================================
// value = M * 3^(e-18), M in [3^18, 3^19), e = decode(E) (bias 40).
// 48 бит = 6 байт: byte[5]=E, byte[4..0]=M (byte0 = младшие триты).
// Умножение: 25 тактов аккумуляции через 1 tbyte_mul + нормализация.
// Выход: нормализованный TFloat48 (как tfmac в режиме mul).
// ============================================================================
module tfmul (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [47:0] a,           // {E(8), M(40)}
    input  logic [47:0] b,
    output logic        valid_out,
    output logic [47:0] result
);
    localparam logic [1:0] P1 = 2'b01;
    localparam logic [1:0] N1 = 2'b10;

    logic [39:0] a_m, b_m;
    logic [7:0]  a_e, b_e;
    assign a_m = a[39:0];
    assign b_m = b[39:0];
    assign a_e = a[47:40];
    assign b_e = b[47:40];

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

    function automatic logic signed [7:0] exp_val(input logic [7:0] x);
        logic signed [7:0] v;
        v = 8'sd0;
        for (int i = 3; i >= 0; i--)
            v = v * 3 + trit_val2(x[2*i +: 2]);
        exp_val = v;
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

    localparam int PH_IDLE = 0;
    localparam int PH_INIT = 1;
    localparam int PH_MUL  = 2;
    localparam int PH_NORM = 3;
    localparam int PH_DONE = 4;

    logic [2:0] phase;
    logic [5:0] cnt;
    logic [79:0] prod;         // 40 тритов
    logic signed [7:0] e;
    logic [39:0] a_mr, b_mr;
    logic [7:0]  a_er, b_er;
    logic msign;

    logic [7:0] am_b [0:4];
    logic [7:0] bm_b [0:4];
    always_comb begin
        am_b[0] = a_mr[7:0]; am_b[1] = a_mr[15:8]; am_b[2] = a_mr[23:16];
        am_b[3] = a_mr[31:24]; am_b[4] = a_mr[39:32];
        bm_b[0] = b_mr[7:0]; bm_b[1] = b_mr[15:8]; bm_b[2] = b_mr[23:16];
        bm_b[3] = b_mr[31:24]; bm_b[4] = b_mr[39:32];
    end

    logic [2:0] mul_i, mul_j;
    assign mul_i = cnt / 5;
    assign mul_j = cnt % 5;

    logic [15:0] partial;
    tbyte_mul u_mul (
        .a(am_b[mul_i]),
        .b(bm_b[mul_j]),
        .prod(partial)
    );

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
                logic [1:0] out_t;
                if (t >= shift_t && t < shift_t + 8)
                    pv = partial[2*(t - shift_t) +: 2];
                else
                    pv = 2'b00;
                sv = trit_val2(prod[2*t +: 2]) + trit_val2(pv) + carry;
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

    logic prod_next_neg;
    always_comb begin
        prod_next_neg = 1'b0;
        for (int t = 39; t >= 0; t--)
            if (prod_next[2*t +: 2] != 2'b00) begin
                prod_next_neg = (prod_next[2*t +: 2] == N1);
                break;
            end
    end

    logic prod_neg;
    always_comb begin
        prod_neg = 1'b0;
        for (int t = 39; t >= 0; t--)
            if (prod[2*t +: 2] != 2'b00) begin
                prod_neg = (prod[2*t +: 2] == N1);
                break;
            end
    end

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

    logic [79:0] mul3_abs;
    always_comb begin
        mul3_abs = 80'h0;
        for (int t = 0; t < 39; t++)
            mul3_abs[2*(t+1) +: 2] = prod_abs[2*t +: 2];
        mul3_abs[1:0] = 2'b00;
    end

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

    logic valid_q;
    logic [47:0] result_q;
    localparam logic [7:0] TOTAL_ERR8 = 8'hFF;
    localparam logic [39:0] TOTAL_ERR40 = 40'hFFFFFFFFFF;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE;
            cnt <= 0; prod <= 0; e <= 0;
            valid_q <= 0; result_q <= 0;
            a_mr <= 0; b_mr <= 0; a_er <= 0; b_er <= 0; msign <= 0;
        end else begin
            valid_q <= 0;
            case (phase)
                PH_IDLE: begin
                    if (valid_in) begin
                        a_mr <= a[39:0];
                        b_mr <= b[39:0];
                        a_er <= a[47:40];
                        b_er <= b[47:40];
                        phase <= PH_INIT;
                    end
                end
                PH_INIT: begin
                    phase <= PH_MUL;
                    cnt <= 0;
                    prod <= 0;
                    e <= exp_val(a_er) + exp_val(b_er) - 8'sd18;
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
                PH_NORM: begin
                    if (val_zero) begin
                        phase <= PH_DONE;
                    end else if (e > 8'sd40) begin
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
