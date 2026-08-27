// debug f2t_pipe: 1.0
module tb_f2tp_dbg;
    logic clk=0, rst_n=0, s_valid=0, m_valid;
    logic [31:0] s_data;
    logic [39:0] m_data;
    f32_to_tf40_pipe dut (.clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_valid), .s_axis_tdata(s_data),
        .m_axis_tvalid(m_valid), .m_axis_tdata(m_data));
    always #5 clk = ~clk;
    int cnt = 0;
    initial begin
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        // подать 1.0
        s_valid = 1; s_data = 32'h3f800000;
        @(posedge clk);
        s_valid = 0;
        repeat(10) @(posedge clk);
        $display("p_val=%0d v[13]=%0d e3s[13]=%0d", dut.p_val, dut.v[13], dut.e3s[13]);
        repeat(50) @(posedge clk);
        $display("nm[N]=%0d ne[N]=%0d", dut.nm[40], dut.ne[40]);
        $display("fm[8]=%0d fv=%0d fz=%0d", dut.fm[8], dut.fv[8], dut.fz[8]);
        $display("m_valid=%0d m_data=%h", m_valid, m_data);
        $finish;
    end
endmodule
