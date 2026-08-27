// ============================================================================
// tb_f2t_pipe2_dbg8.sv - правильная трассировка построения D для 0.001
// ============================================================================
module tb_f2t_pipe2_dbg8;
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
        // 0.001 = 0x3A83126F
        s_valid = 1;
        s_data = 32'h3A83126F;
        @(posedge clk);  // T=0: S0 захват
        s_valid = 0;
        @(posedge clk);  // T=1: S1 захват
        $display("S1 val_q=%h p3=%h", dut.s1_val_q, dut.s1_p3);
        for (int s = 0; s <= 61; s++) begin
            @(posedge clk);  // T=2+s: d_[s]
            if (s == 0 || s == 5 || s == 10 || s == 30 || s == 52 || s == 53 || s == 61)
                $display("DB%0d vq=%h D=%h off=%0d up=%b", s, dut.d_vq[s], dut.d_D[s], dut.d_off[s], dut.d_up[s]);
        end
        // div стадии
        @(posedge clk);  // T=64: q_[0]
        $display("Q0 X=%h D=%h", dut.q_X[0], dut.q_D[0]);
        for (int s = 1; s <= 128; s++) begin
            @(posedge clk);  // T=64+s: q_[s]
            if (s == 128)
                $display("Q128 q=%h off=%0d", dut.q_q[128], dut.q_off[128]);
        end
        @(posedge clk);  // T=193: nm[0]
        for (int s = 1; s <= 8; s++) begin
            @(posedge clk);
            if (s == 8)
                $display("NM8 nm=%h noff=%0d", dut.nm[8], dut.no[8]);
        end
        $finish;
    end
endmodule
