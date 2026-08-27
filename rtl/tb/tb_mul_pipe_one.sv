// ============================================================================
// tb_mul_pipe_one.sv - одна пара, посактовая печать выхода
// ============================================================================
module tb_mul_pipe_one;
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

    initial begin
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        // 1.0 * 1.0 -> 1.0 = 0x1000000198
        s_axis_a = 40'h1000000198;
        s_axis_b = 40'h1000000198;
        s_axis_tvalid = 1;
        @(posedge clk);
        s_axis_tvalid = 0;
        for (int t = 0; t < 55; t++) begin
            @(posedge clk);
            if (m_axis_tvalid)
                $display("T%0d: vout=1 out=%h", t, m_axis_tdata);
            if (t >= 30 && t <= 42)
                $display("  T%0d: tv=%b tc=%h%h te=%0d", t,
                         dut.tv[15], dut.tc[15][14], dut.tc[15][13], dut.te[15]);
        end
        $finish;
    end
endmodule
