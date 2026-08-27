// ============================================================================
// tb_f2t_pipe2_dbg7.sv - захват s0_val_q после posedge
// ============================================================================
module tb_f2t_pipe2_dbg7;
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
        s_data = 32'h3A83126F;
        @(posedge clk);
        $display("AFTER posedge: p_val_q=%h s0_val_q=%h s0_sign=%b", dut.p_val_q, dut.s0_val_q, dut.s0_sign);
        s_valid = 0;
        @(posedge clk);
        $display("NEXT: p_val_q=%h s0_val_q=%h s1_val_q=%h s1_p3=%h", dut.p_val_q, dut.s0_val_q, dut.s1_val_q, dut.s1_p3);
        $finish;
    end
endmodule
