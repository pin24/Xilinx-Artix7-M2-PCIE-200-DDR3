// ============================================================================
// tb_tfadd_equiv.sv — A/B-эквивалентность barrel tfadd_raw vs golden serial
// ============================================================================
// Сравнивает побитно результаты:
//   tfadd_raw     (новая, фиксированные 6 тактов, BUG-040 исправлен)
//   tfadd_raw_ref (serial-копия до барреля, |Δe| <= 63 — референс-зона)
// Ожидания:
//   * |Δe| <= 63: результаты ОБЯЗАНЫ совпадать бит-в-бит (латентность может
//     отличаться — сравнение по событиям valid_out).
//   * |Δe| >= 64: зона BUG-040 — serial работает на мусорном cnt; расхождения
//     учитываются отдельно (DE64_DIFF), НЕ являются провалом теста.
//   * латентность новой версии обязана быть ровно 6 тактов на каждой
//     транзакции (LAT_ERR = 0).
// Запуск (стена): xvlog -sv tfadd_raw.sv tfadd_raw_ref.sv tb_tfadd_equiv.sv
//                 xelab tb_tfadd_equiv -debug typical && xsim ... -runall
// ============================================================================
module tb_tfadd_equiv;
    logic clk = 0, rst_n = 0;
    logic valid_in = 0;
    logic [79:0] a_prod, b_prod;
    logic signed [7:0] a_e, b_e;

    logic        valid_out_n, valid_out_r;
    logic [47:0] result_n, result_r;

    tfadd_raw     dut_new (.clk(clk), .rst_n(rst_n), .valid_in(valid_in),
                           .a_prod(a_prod), .a_e(a_e), .a_neg(1'b0),
                           .b_prod(b_prod), .b_e(b_e), .b_neg(1'b0),
                           .valid_out(valid_out_n), .result(result_n));
    tfadd_raw_ref dut_ref (.clk(clk), .rst_n(rst_n), .valid_in(valid_in),
                           .a_prod(a_prod), .a_e(a_e), .a_neg(1'b0),
                           .b_prod(b_prod), .b_e(b_e), .b_neg(1'b0),
                           .valid_out(valid_out_r), .result(result_r));

    always #5 clk = ~clk;

    int pass = 0, fail = 0, de64_diff = 0, de64_same = 0, lat_err = 0;

    function automatic logic [79:0] tneg40(input logic [79:0] x);
        for (int t = 0; t < 40; t++) begin
            case (x[2*t +: 2])
                2'b01:   tneg40[2*t +: 2] = 2'b10;
                2'b10:   tneg40[2*t +: 2] = 2'b01;
                default: tneg40[2*t +: 2] = 2'b00;
            endcase
        end
    endfunction

    task automatic run_one(input logic [79:0] ap, input logic signed [7:0] ae,
                           input logic [79:0] bp, input logic signed [7:0] be,
                           input string tag);
        int lat_n, lat_r, lat_n_seen;
        logic got_n, got_r;
        logic [47:0] res_n, res_r;
        int de;
        @(negedge clk);
        a_prod = ap; a_e = ae; b_prod = bp; b_e = be;
        valid_in = 1;
        @(posedge clk);          // фронт захвата
        @(negedge clk);
        valid_in = 0;
        lat_n = 0; lat_r = 0; got_n = 0; got_r = 0;
        while (!(got_n && got_r) && lat_n < 400 && lat_r < 400) begin
            @(posedge clk);
            lat_n++; lat_r++;
            if (!got_n && valid_out_n) begin got_n = 1; res_n = result_n; lat_n_seen = lat_n; end
            if (!got_r && valid_out_r) begin got_r = 1; res_r = result_r; end
        end
        if (!(got_n && got_r)) begin
            $display("[TIMEOUT] %s: got_n=%0b got_r=%0b ae=%0d be=%0d", tag, got_n, got_r, ae, be);
            fail++;
            return;
        end
        if (lat_n_seen != 6) begin
            $display("[LAT] %s: latency=%0d (ожидалось 6)", tag, lat_n_seen);
            lat_err++;
        end
        de = (ae > be) ? (ae - be) : (be - ae);
        if (res_n === res_r) begin
            pass++;
            if (de >= 64) de64_same++;
        end else if (de >= 64) begin
            // зона BUG-040: serial на мусорном cnt — расхождение ожидаемо
            de64_diff++;
        end else begin
            $display("[DIFF] %s de=%0d ae=%0d be=%0d ap=%h bp=%h: new=%h ref=%h",
                     tag, de, ae, be, ap, bp, res_n, res_r);
            fail++;
        end
    endtask

    logic [79:0] ra, rb;
    logic signed [7:0] re_a, re_b;
    int de, beb;

    // кламп be в 8-битный диапазон (как в proof_tfadd_barrel.py: max(-98, min(62, be)))

    initial begin
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---- направленные ----
        run_one(80'h1 << 36, 8'sd0, 80'h1 << 36, 8'sd0, "1+1");            // 1+1=2
        run_one(80'h0, 8'sd0, 80'h0, 8'sd0, "zero");
        run_one(80'h1 << 36, 8'sd0, tneg40(80'h1 << 36), 8'sd0, "cancel"); // 1 + (-1)
        run_one({40{2'b01}}, 8'sd62, {40{2'b10}}, -8'sd98, "extremes160"); // de=160 (BUG-040 зона)
        for (int d = 0; d <= 23; d++) begin
            run_one(80'h1 << 36, 8'sd30, 80'h1 << 36, 8'sd30 - 8'(d), "de-edge");
        end
        for (int d = 24; d <= 63; d += 3) begin
            run_one(80'h1 << 36, 8'sd62, 80'h1 << 36, 8'sd62 - 8'(d), "de-mid");
        end
        for (int d = 64; d <= 160; d += 8) begin
            run_one(80'h1 << 36, 8'sd62, 80'h1 << 36, 8'sd62 - 8'(d), "de64");
        end

        // ---- случайные: продукты (e ∈ [-98,62], |Δe| <= 63) ----
        repeat (3000) begin
            ra = {$urandom, $urandom}; rb = {$urandom, $urandom};
            re_a = 8'($urandom % 161) - 8'sd98;
            de = $urandom % 64;
            beb = re_a + (($urandom % 2) ? de : -de);
            if (beb < -98) beb = -98;
            if (beb > 62)  beb = 62;
            re_b = 8'(beb);
            run_one(ra, re_a, rb, re_b, "rnd-prod");
        end
        // ---- случайные: TFloat48-уровень (e ∈ [-40,40]) ----
        repeat (2000) begin
            ra = {$urandom, $urandom}; rb = {$urandom, $urandom};
            re_a = 8'($urandom % 81) - 8'sd40;
            de = $urandom % 64;
            beb = re_a + (($urandom % 2) ? de : -de);
            if (beb < -40) beb = -40;
            if (beb > 40)  beb = 40;
            re_b = 8'(beb);
            run_one(ra, re_a, rb, re_b, "rnd-tf48");
        end
        // ---- случайные: зона BUG-040 (|Δe| >= 64) ----
        repeat (1000) begin
            ra = {$urandom, $urandom}; rb = {$urandom, $urandom};
            re_a = 8'($urandom % 161) - 8'sd98;
            de = 64 + $urandom % 97;
            beb = re_a + (($urandom % 2) ? de : -de);
            if (beb < -98) beb = -98;
            if (beb > 62)  beb = 62;
            re_b = 8'(beb);
            run_one(ra, re_a, rb, re_b, "rnd-de64");
        end

        $display("=================================================");
        $display("EQUIV: pass=%0d fail=%0d lat_err=%0d", pass, fail, lat_err);
        $display("BUG-040 zone (de>=64): diff=%0d same=%0d", de64_diff, de64_same);
        if (fail == 0 && lat_err == 0 && de64_diff > 0)
            $display("ALL EQUIV PASS");
        else
            $display("EQUIV FAILED");
        $finish;
    end
endmodule
