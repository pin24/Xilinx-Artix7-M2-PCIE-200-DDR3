// ============================================================================
// tb_f2t_pipe2_dbg5.sv - трассировка построения D для одного 0.001
// ============================================================================
module tb_f2t_pipe2_dbg5;
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
        // 0.001 = 0x3A83126F, подали на такте T=0 (после 3 reset тактов)
        s_valid = 1;
        s_data = 32'h3A83126F;
        @(posedge clk);  // T=0: S0 захватывает
        s_valid = 0;
        $display("S0 val_q=%h", dut.s0_val_q);
        @(posedge clk);  // T=1: S1
        $display("S1 p3=%h val_q=%h", dut.s1_p3, dut.s1_val_q);
        @(posedge clk);  // T=2: DB[0]
        $display("DB0 vq=%h D=%h off=%0d up=%b", dut.d_vq[0], dut.d_D[0], dut.d_off[0], dut.d_up[0]);
        for (int s = 1; s <= 61; s++) begin
            @(posedge clk);  // T=2+s: DB[s]
            if (s == 5 || s == 10 || s == 20 || s == 40 || s == 60 || s == 61)
                $display("DB%0d vq=%h D=%h off=%0d", s, dut.d_vq[s], dut.d_D[s], dut.d_off[s]);
        end
        $finish;
    end
endmodule
