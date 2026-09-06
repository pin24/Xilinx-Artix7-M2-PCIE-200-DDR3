// ============================================================================
// tb_tfmul_kbd.sv — self-checking тест tfmul_kbd (ВЕРСИЯ 2, BUG-039)
// ============================================================================
// Golden-модель: прямое целочисленное умножение мантисс (longint, точное) +
// преобразование в 40 сбалансированных тритов. Проверяются prod, e, neg.
//
// Направленные кейсы:
//   - все 16 комбинаций крайних половин (a_hi/a_lo = ±29524) — принудительно
//   покрывают s_a, s_b ∈ {-1,0,+1} и s_a*s_b = ±1 (перенос 11-го трита сумм,
//   который в BUG-039 выбрасывался);
//   - нули, ±1, max×min, знаковые комбинации, разные экспоненты.
// Случайные: 3000 векторов ($urandom).
//
// Запуск (xsim): xvlog tfmul_kbd.sv tb_tfmul_kbd.sv && xsim tb_tfmul_kbd -R
// Ожидание: "ALL <N> TESTS PASSED", err_cnt = 0.
// ============================================================================
module tb_tfmul_kbd;
    logic clk = 0, rst_n = 0;
    logic valid_in = 0;
    logic [47:0] a, b;
    logic valid_out;
    logic [79:0] prod;
    logic [7:0]  e;
    logic        neg;

    tfmul_kbd dut (
        .clk(clk), .rst_n(rst_n),
        .valid_in(valid_in), .a(a), .b(b),
        .valid_out(valid_out), .prod(prod), .e(e), .neg(neg)
    );

    always #5 clk = ~clk;

    // ---------------- golden-модель ----------------
    function automatic longint signed mant_val(input logic [39:0] m);
        longint signed v;
        logic [1:0] c;
        v = 0;
        for (int i = 19; i >= 0; i--) begin
            c = m[2*i +: 2];
            v = v * 3 + ((c == 2'b01) ? 7'sd1 : (c == 2'b10) ? -7'sd1 : 7'sd0);
        end
        return v;
    endfunction

    function automatic int signed exp_val_g(input logic [7:0] x);
        int signed v;
        logic [1:0] c;
        v = 0;
        for (int i = 3; i >= 0; i--) begin
            c = x[2*i +: 2];
            v = v * 3 + ((c == 2'b01) ? 1 : (c == 2'b10) ? -1 : 0);
        end
        return v;
    endfunction

    // целое -> 40 сбалансированных тритов (упаковка, как выход RTL)
    function automatic logic [79:0] int_to_prod40(input longint signed value);
        logic [79:0] acc;
        longint signed x, q;
        int signed r;
        acc = '0;
        x = value;
        for (int t = 0; t < 40; t++) begin
            q = x / 3;              // SV: усечение к нулю
            r = x - 3 * q;          // остаток со знаком делимого
            if (r > 1)       begin q = q + 1; r = r - 3; end
            else if (r < -1) begin q = q - 1; r = r + 3; end
            case (r)
                1:  acc[2*t +: 2] = 2'b01;
                -1: acc[2*t +: 2] = 2'b10;
                default: acc[2*t +: 2] = 2'b00;
            endcase
            x = q;
        end
        // x обязан стать 0: |a*b| <= ((3^20-1)/2)^2 < 3^40/2
        return acc;
    endfunction

    // ---------------- счётчики ----------------
    int n_tests = 0;
    int err_cnt = 0;

    task automatic check_outputs(input logic [47:0] ta, input logic [47:0] tbv, input int idx);
        longint signed am, bm, exact;
        logic [79:0] exp_prod;
        logic [7:0]  exp_e;
        logic        exp_neg;
        begin
            am = mant_val(ta[39:0]);
            bm = mant_val(tbv[39:0]);
            exact = am * bm;
            exp_prod = int_to_prod40(exact);
            exp_e = exp_val_g(ta[47:40]) + exp_val_g(tbv[47:40]) - 18;
            exp_neg = (exact < 0);
            if (prod !== exp_prod) begin
                $display("FAIL[%0d] prod: a_m=%0d b_m=%0d exact=%0d", idx, am, bm, exact);
                $display("        got=%h exp=%h", prod, exp_prod);
                err_cnt++;
            end
            if (e !== exp_e) begin
                $display("FAIL[%0d] e: got=%0d exp=%0d (a_m=%0d b_m=%0d)", idx, $signed(e), exp_e, am, bm);
                err_cnt++;
            end
            if (neg !== exp_neg) begin
                $display("FAIL[%0d] neg: got=%b exp=%b (exact=%0d)", idx, neg, exp_neg, exact);
                err_cnt++;
            end
            n_tests++;
        end
    endtask

    task automatic run_case(input logic [47:0] ta, input logic [47:0] tbv, input int idx);
        begin
            @(negedge clk);
            valid_in = 1;
            a = ta;
            b = tbv;
            @(posedge clk);
            #1;
            if (valid_out !== 1'b1) begin
                $display("FAIL[%0d]: valid_out=0 (латентность DUT != 1 такт)", idx);
                err_cnt++;
                n_tests++;
            end else begin
                check_outputs(ta, tbv, idx);
            end
            @(negedge clk);
            valid_in = 0;
        end
    endtask

    // константные мантиссы: все 20 тритов = c
    function automatic logic [39:0] fill_mant(input logic [1:0] c);
        logic [39:0] m;
        for (int i = 0; i < 20; i++) m[2*i +: 2] = c;
        return m;
    endfunction

    // 10 тритов hi + 10 тритов lo (иначе принудительный перенос s)
    function automatic logic [39:0] halves_mant(input logic [1:0] hi_c, input logic [1:0] lo_c);
        logic [39:0] m;
        for (int i = 0; i < 10; i++) begin
            m[2*i +: 2]        = lo_c;   // триты 0..9  (a_lo)
            m[2*(i+10) +: 2]   = hi_c;   // триты 10..19 (a_hi)
        end
        return m;
    endfunction

    logic [39:0] m_all_p, m_all_n, m_hp_ln, m_hn_lp;
    logic [39:0] am, bm;

    initial begin
        rst_n = 0;
        a = '0; b = '0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        m_all_p = fill_mant(2'b01);   // +29524 (все +1)
        m_all_n = fill_mant(2'b10);   // -29524 (все -1)
        m_hp_ln = halves_mant(2'b01, 2'b10);  // hi=+max, lo=-max -> сумма 0
        m_hn_lp = halves_mant(2'b10, 2'b01);  // hi=-max, lo=+max -> сумма 0

        // --- направленные: 16 комбинаций крайних половин (s_a,s_b = -1/0/+1) ---
        begin : directed
            logic [39:0] half_variants [0:3];
            half_variants[0] = m_all_p;            // hi=+max lo=+max -> s=+1
            half_variants[1] = m_all_n;            // hi=-max lo=-max -> s=-1
            half_variants[2] = m_hp_ln;            // hi=+max lo=-max -> s=0
            half_variants[3] = m_hn_lp;            // hi=-max lo=+max -> s=0
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++)
                    run_case({8'h00, half_variants[i]}, {8'h00, half_variants[j]}, 1000 + i * 4 + j);
        end

        // --- простые и крайние ---
        run_case({8'h00, 40'd0}, {8'h00, 40'd0}, 0);                       // 0*0
        run_case({8'h00, fill_mant(2'b01) & (40'b1)}, {8'h00, fill_mant(2'b01) & (40'b1)}, 1); // 1*1
        run_case({8'h00, 40'b01}, {8'h00, 40'b10}, 2);                     // 1*(-1)
        run_case({8'h00, m_all_p}, {8'h00, m_all_n}, 3);                   // max*min
        run_case({8'h00, m_all_n}, {8'h00, m_all_n}, 4);                   // min*min
        run_case({8'h55, m_all_p}, {8'hAA, m_all_p}, 5);                   // с ненулевыми экспонентами

        // --- случайные: 3000 векторов ---
        begin : random_tests
            logic [1:0] c;
            for (int k = 0; k < 3000; k++) begin
                for (int i = 0; i < 20; i++) begin
                    c = $urandom_range(0, 2) == 0 ? 2'b00 : ($urandom_range(0, 1) ? 2'b01 : 2'b10);
                    am[2*i +: 2] = c;
                    c = $urandom_range(0, 2) == 0 ? 2'b00 : ($urandom_range(0, 1) ? 2'b01 : 2'b10);
                    bm[2*i +: 2] = c;
                end
                run_case({$urandom, am}, {$urandom, bm}, k);
            end
        end

        if (err_cnt == 0)
            $display("ALL %0d TESTS PASSED", n_tests);
        else
            $display("FAILED: %0d errors / %0d tests", err_cnt, n_tests);
        $finish;
    end

    // watchdog
    initial begin
        #1_000_000;
        $display("TIMEOUT: тест не завершился");
        $finish;
    end
endmodule
