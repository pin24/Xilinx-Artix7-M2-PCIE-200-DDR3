// ============================================================================
// tb_tfmul_raw.sv - тест tfmul_raw: 2.0 * 3.0 = 6.0 (ненормализованный prod)
// 2.0: M=2*3^18 (трит +1 поз 19, +1 поз 18), e=0
// 3.0: M=3^19 (трит +1 поз 19), e=0
// prod = 2*3^18 * 3^19 = 6*3^37, e = 0+0-18 = -18
// ============================================================================
module tb_tfmul_raw;
    logic clk = 0, rst_n = 0;
    logic valid_in = 0;
    logic [47:0] a, b;
    logic valid_out;
    logic [79:0] prod;
    logic [7:0] e;
    logic neg;

    tfmul_raw dut (
        .clk(clk), .rst_n(rst_n),
        .valid_in(valid_in), .a(a), .b(b),
        .valid_out(valid_out), .prod(prod), .e(e), .neg(neg)
    );

    always #5 clk = ~clk;

    // 2.0: bits = (e_int<<40)|m_int = 0x6000000000, e_int=0 (E=00), M=0x6000000000
    // 3.0: bits = 0x11000000000, e_int=1 (E=01), M=0x1000000000
    initial begin
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        a = 48'h6000000000;
        b = 48'h11000000000;
        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        for (int t = 0; t < 60; t++) begin
            @(posedge clk);
            if (valid_out) begin
                $display("RESULT prod=%h e=%0d neg=%b", prod, $signed(e), neg);
                break;
            end
        end
        $finish;
    end
endmodule
