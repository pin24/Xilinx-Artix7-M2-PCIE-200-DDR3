// ============================================================================
// tb_tfadd_raw.sv - тест tfadd_raw: 1 + 1 = 2 (ненормализованные продукты)
// 1.0: M=3^18 (трит +1 на позиции 18), e=0, neg=0.
// ============================================================================
module tb_tfadd_raw;
    logic clk = 0, rst_n = 0;
    logic valid_in = 0;
    logic [79:0] a_prod, b_prod;
    logic [7:0]  a_e, b_e;
    logic        a_neg, b_neg;
    logic valid_out;
    logic [47:0] result;

    tfadd_raw dut (
        .clk(clk), .rst_n(rst_n),
        .valid_in(valid_in),
        .a_prod(a_prod), .a_e(a_e), .a_neg(a_neg),
        .b_prod(b_prod), .b_e(b_e), .b_neg(b_neg),
        .valid_out(valid_out), .result(result)
    );

    always #5 clk = ~clk;

    initial begin
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        // 1.0: M = 3^18 -> трит +1 на позиции 18 -> биты [37:36]=01
        a_prod = (80'h1 << 36);
        b_prod = (80'h1 << 36);
        a_e = 8'sd0; b_e = 8'sd0;
        a_neg = 0; b_neg = 0;
        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        for (int t = 0; t < 200; t++) begin
            @(posedge clk);
            if (dut.phase != 5)
                $display("T%0d phase=%0d cnt=%0d e=%0d", t, dut.phase, dut.cnt, dut.e_sum);
            if (dut.phase == 4)
                $display("NORM sum=%h e=%0d val=%0d", dut.sum, dut.e_sum, dut.val_abs);
            if (valid_out) begin
                $display("RESULT=%h", result);
                break;
            end
        end
        $finish;
    end
endmodule
