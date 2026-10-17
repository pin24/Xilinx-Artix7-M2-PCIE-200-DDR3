// ============================================================================
// tf48_to_f32.sv - конвертер TFloat48 -> IEEE float32 (T2F), БИТ-В-БИТ host
// ============================================================================
// value = M * 3^(e-18). Вход tf48 в конвенции ядра: [47:40]=e, [39:0]=M.
// Результат - float32 с RNE (round-to-nearest-even), как host
// TFloat.to_float() + struct.pack('f'). Эквивалент scripts/f2t48_proto.py t2f_int.
//
// Точный рациональный алгоритм:
//   M = decode(20 тритов), e = decode(4 тритов)  (любой 2-бит цод ==11 -> NaN)
//   A = |M|; value = A * 3^(e-18) = N/D:
//       e>=18: N=A*3^(e-18), D=1
//       e<18 : N=A,          D=3^(18-e)
//   e2 = floor(log2(value))           (точным сравнением value >= 2^c)
//   m24 = RNE( value * 2^(23-e2) )    (= RNE(N'/D') через remainder)
//   если m24 >= 2^24 -> m24>>=1, e2++
//   e_b = e2 + 127; e_b>=255 -> inf; e_b<=0 -> 0; иначе собрать float32.
// ============================================================================

module tf48_to_f32 (
    input  logic [47:0] tf48,
    output logic [31:0] f32
);
    import tf48_pkg::*;

    localparam int W = 192;   // ширина рациональной арифметики

    logic [M_BITS-1:0] m_bits;
    logic [E_BITS-1:0] e_bits;
    assign m_bits = tf48[M_BITS-1:0];    // [39:0]
    assign e_bits = tf48[47:40];         // [47:40]

    // --- ERR-детекция: любой 2-битный код == 11 -> NaN ---
    logic err_m, err_e;
    always_comb begin
        err_m = 1'b0;
        for (int i = 0; i < M_TRITS; i++)
            if (m_bits[i*2 +: 2] == TRIT_ERR) err_m = 1'b1;
        err_e = 1'b0;
        for (int i = 0; i < E_TRITS; i++)
            if (e_bits[i*2 +: 2] == TRIT_ERR) err_e = 1'b1;
    end

    // --- декодирование M (знаковое, старший трит первым) и e ---
    logic signed [63:0] M;
    logic signed [15:0] de;
    always_comb begin
        M = 64'sd0;
        for (int i = M_TRITS-1; i >= 0; i--)
            M = M * 3 + $signed(trit_val(m_bits[i*2 +: 2]));
        de = 16'sd0;
        for (int i = E_TRITS-1; i >= 0; i--)
            de = de * 3 + $signed(trit_val(e_bits[i*2 +: 2]));
    end

    logic        nsign;
    logic [63:0] A;
    logic        is_zero;
    assign nsign   = (M < 0);
    assign A       = (M < 0) ? (-M[63:0]) : M[63:0];
    assign is_zero = (M == 0);

    // --- таблицы 3^p ---
    logic [W-1:0] P3n [0:22];   // 3^p, p=0..22
    logic [W-1:0] P3d [0:58];   // 3^p, p=0..58
    genvar g;
    generate
        assign P3n[0] = {{(W-1){1'b0}}, 1'b1};
        assign P3d[0] = {{(W-1){1'b0}}, 1'b1};
        for (g = 1; g <= 58; g++) begin : gen_p3
            assign P3d[g] = P3d[g-1] * 3;
            if (g <= 22) assign P3n[g] = P3n[g-1] * 3;
        end
    endgenerate

    logic [W-1:0] N, D;
    logic [W-1:0] A_w;
    always_comb begin
        N = {W{1'b0}};
        D = {W{1'b0}};
        A_w = {{(W-64){1'b0}}, A};
        if (de >= 18) begin
            N = A_w * P3n[de - 18];       // A * 3^(e-18), idx [0,22]
            D = 1;
        end else begin
            N = A_w;
            D = P3d[18 - de];             // 3^(18-e), idx [1,58]
        end
    end

    // --- сравнение value(=N/D) >= 2^c  <=>  N >= D*2^c ---
    function automatic logic vge(input int cc);
        logic [W-1:0] lhs, rhs;
        lhs = N;
        if (cc >= 0)
            rhs = D << cc;
        else begin
            lhs = N << (-cc);            // N*2^|c| >= D
            rhs = D;
        end
        vge = (lhs >= rhs);
    endfunction

    // --- e2 = floor(log2(value)) ---
    logic signed [15:0] e2;
    always_comb begin
        e2 = -16'sd1;
        for (int c = 64; c >= -95; c--) begin
            if (vge(c)) begin
                e2 = c;
                break;
            end
        end
    end

    // --- m24 = RNE( value * 2^(23-e2) ) ---
    logic signed [15:0] T;
    logic [W-1:0] num, den;
    logic [W-1:0] q, rem;
    logic [W-1:0] m24;
    logic signed [15:0] e2n;

    assign T = 23 - e2[15:0];

    always_comb begin
        num = N;
        den = D;
        if (T >= 0)
            num = N << T[8:0];
        else
            den = D << (-T[8:0]);
        q   = num / (den == 0 ? 1 : den);
        rem = num % (den == 0 ? 1 : den);
    end

    always_comb begin
        m24 = q;
        // RNE: если rem > den/2 -> +1; rem == den/2 -> to-even
        begin : rne
            logic [W-1:0] two_rem;
            two_rem = rem << 1;
            if (two_rem > den)
                m24 = q + 1;
            else if (two_rem == den) begin
                if (q[0] == 1'b1) m24 = q + 1;   // нечётное -> вверх
            end
        end
        e2n = e2;
        if (m24 >= (1 << 24)) begin
            m24 = m24 >> 1;
            e2n = e2n + 1;
        end
    end

    // --- сборка float32 ---
    logic [7:0] e_b;
    assign e_b = e2n[15:0] + 127;

    always_comb begin
        if (is_zero) begin
            f32 = 32'h0;
        end else if (err_m || err_e) begin
            f32 = 32'h7FC00000;                 // NaN (как to_float() для err)
        end else if (e_b >= 255) begin
            f32 = {nsign, 8'hFF, 23'h0};        // inf
        end else if (e_b <= 0) begin
            f32 = 32'h0;                        // underflow -> 0
        end else begin
            f32 = {nsign, e_b, m24[22:0]};
        end
    end

endmodule