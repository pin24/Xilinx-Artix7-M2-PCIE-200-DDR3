// ============================================================================
// tfmul_raw.sv - параллельный умножитель TFloat48 БЕЗ нормализации
// ============================================================================
// Умножение: 25 тактов аккумуляции через 1 tbyte_mul.
// Выход: НЕНОРМАЛИЗОВАННЫЙ продукт:
//   prod (40 тритов, до ~3^38), e = ea+eb-18, знак отдельно.
// Нормализация выполняется на дереве сложений (см. tfadd_raw).
// ============================================================================
module tfmul_raw (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [47:0] a,           // {E(8), M(40)}
    input  logic [47:0] b,
    output logic        valid_out,
    output logic [79:0] prod,        // 40 тритов (трит t = [2t+1:2t])
    output logic [7:0]  e,           // экспонента продукта (signed)
    output logic        neg          // знак продукта
);
    localparam logic [1:0] P1 = 2'b01;
    localparam logic [1:0] N1 = 2'b10;

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
        logic signed [2:0] tv;
        v = 8'sd0;
        for (int i = 3; i >= 0; i--) begin
            tv = trit_val2(x[2*i +: 2]);
            v = v * 3'sd3 + tv;
        end
        exp_val = v;
    endfunction

    localparam int PH_IDLE = 0;
    localparam int PH_INIT = 1;
    localparam int PH_MUL  = 2;
    localparam int PH_DONE = 3;

    logic [1:0] phase;
    logic [5:0] cnt;
    logic [79:0] prod_r;
    logic signed [7:0] e_r;
    logic [39:0] a_mr, b_mr;
    logic [7:0]  a_er, b_er;

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
        prod_next = prod_r;
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
                sv = trit_val2(prod_r[2*t +: 2]) + trit_val2(pv) + carry;
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

    logic valid_q, neg_q;
    logic [79:0] prod_q;
    logic [7:0]  e_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE;
            cnt <= 0; prod_r <= 0; e_r <= 0;
            valid_q <= 0; prod_q <= 0; e_q <= 0; neg_q <= 0;
            a_mr <= 0; b_mr <= 0; a_er <= 0; b_er <= 0;
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
                    prod_r <= 0;
                    e_r <= exp_val(a_er) + exp_val(b_er) - 8'sd18;
                end
                PH_MUL: begin
                    prod_r <= prod_next;
                    if (cnt == 24) begin
                        neg_q <= prod_next_neg;
                        prod_q <= prod_next;
                        e_q <= e_r;
                        valid_q <= 1;
                        phase <= PH_IDLE;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end
            endcase
        end
    end

    assign valid_out = valid_q;
    assign prod = prod_q;
    assign e = e_q;
    assign neg = neg_q;

endmodule
