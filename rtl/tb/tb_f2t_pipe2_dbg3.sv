// ============================================================================
// tb_f2t_pipe2_dbg3.sv - трассировка div стадий для 1.0
// ============================================================================
module tb_f2t_pipe2_dbg3;
    logic clk=0, rst_n=0, s_valid=0, m_valid;
    logic [31:0] s_data;
    logic [39:0] m_data;

    f32_to_tf40_pipe2 dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_valid), .s_axis_tdata(s_data),
        .m_axis_tvalid(m_valid), .m_axis_tdata(m_data)
    );

    always #5 clk = ~clk;

    initial begin
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        s_valid = 1;
        s_data = 32'h3f800000;
        @(posedge clk);
        s_valid = 0;
        // пакет входит в div на стадии 0 примерно на такте 1+1+61 = 63 (после S0,S1,DB61)
        // q_X[0] готов на такте ~65. Наблюдаем q_X/q_rem/q_q на разных стадиях.
        for (int t = 0; t < 200; t++) begin
            @(posedge clk);
            if (t == 66)
                $display("DV0: X=%h D=%h", dut.q_X[0], dut.q_D[0]);
            if (t == 67)
                $display("DV1: X=%h D=%h rem=%h q=%h", dut.q_X[1], dut.q_D[1], dut.q_rem[1], dut.q_q[1]);
            if (t == 68)
                $display("DV2: X=%h rem=%h q=%h", dut.q_X[2], dut.q_rem[2], dut.q_q[2]);
            if (t == 90)
                $display("DV24: rem=%h q=%h", dut.q_rem[24], dut.q_q[24]);
            if (t == 140)
                $display("DV74: rem=%h q=%h", dut.q_rem[74], dut.q_q[74]);
            if (t == 193)
                $display("DV128: q=%h off=%0d", dut.q_q[128], dut.q_off[128]);
            if (t == 202)
                $display("NM8: nm=%h off=%0d", dut.nm[8], dut.no[8]);
            if (m_valid) begin
                $display("OUT: %h", m_data);
            end
        end
        $finish;
    end
endmodule
