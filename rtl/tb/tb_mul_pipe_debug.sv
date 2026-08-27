// ============================================================================
// tb_mul_pipe_debug.sv - отладка конвейерного умножения (3.0 * 5.0 = 15.0)
// ============================================================================
module tb_mul_pipe_debug;
    logic clk = 0, rst_n = 0;
    logic s_axis_tvalid = 0;
    logic [39:0] s_axis_a, s_axis_b;
    logic m_axis_tvalid;
    logic [39:0] m_axis_tdata;

    tf40_mul_pipe dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_a(s_axis_a), .s_axis_b(s_axis_b),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tdata(m_axis_tdata)
    );
    always #5 clk = ~clk;

    int cycle;
    initial begin
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        // 3.0 = 0x1000000199, 5.0 = ?
        // 3 пары подряд
        s_axis_a = 40'h115a151591;   // 93.57
        s_axis_b = 40'h68520a9590;   // 46.29  (res 0x6095091595)
        s_axis_tvalid = 1;
        @(posedge clk);
        s_axis_a = 40'h1000000199;   // 3.0
        s_axis_b = 40'h6800000199;   // 5.0   (res 0x6800000192)
        @(posedge clk);
        s_axis_a = 40'h2000000199;   // -3.0
        s_axis_b = 40'h1000000199;   // 3.0   (res -9 = 0x2000000189?)
        @(posedge clk);
        s_axis_tvalid = 0;
        cycle = 0;
        repeat(50) begin
            @(posedge clk);
            cycle = cycle + 1;
            if (m_axis_tvalid)
                $display("cycle %0d: RESULT=%h", cycle, m_axis_tdata);
            // печать промежуточных на ключевых стадиях
            if (cycle == 2) $display("  prod=%0d e_sum=%0d", dut.prod, dut.e_sum);
            if (cycle == 15) $display("  after div: dv=%0d de=%0d", dut.dv[13], dut.de[13]);
            if (cycle == 26) begin
                $display("  cycle26: norm8=%0d ne8=%0d", dut.nm[8], dut.ne[8]);
                $display("  cycle26: tnm=%0d tc15_lo=%b tc15_hi=%b", dut.tnm, dut.tc[15][0], dut.tc[15][14]);
            end
            if (cycle == 39) begin
                $display("  cycle39 tt: tnm=%0d tc={%b %b %b %b %b | ... | %b} | tm15=%0d tv15=%0d",
                         dut.tnm, dut.tc[15][14],dut.tc[15][13],dut.tc[15][12],dut.tc[15][11],dut.tc[15][10],
                         dut.tc[15][0], dut.tm[15], dut.tv[15]);
            end
            if (cycle == 30) $display("  tc15_lo=%b tc15_hi=%b", dut.tc[15][0], dut.tc[15][14]);
        end
        $finish;
    end
endmodule
