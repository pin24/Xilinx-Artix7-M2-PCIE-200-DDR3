// ============================================================================
// tb_f2t_pipe2_dbg6.sv - проверка комбинационного разбора
// ============================================================================
module tb_f2t_pipe2_dbg6;
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
        // проверим комбинационный разбор для 0.001
        s_data = 32'h3A83126F;
        #1;
        $display("0.001: e2=%0d p_shift=%0d p_m24=%h p_val_q=%h",
                 dut.p_e2, dut.p_shift, dut.p_m24, dut.p_val_q);
        s_data = 32'hBF800000;  // -1.0
        #1;
        $display("-1.0: e2=%0d p_shift=%0d p_m24=%h p_val_q=%h",
                 dut.p_e2, dut.p_shift, dut.p_m24, dut.p_val_q);
        s_data = 32'h3F800000;  // 1.0
        #1;
        $display("1.0: e2=%0d p_shift=%0d p_m24=%h p_val_q=%h",
                 dut.p_e2, dut.p_shift, dut.p_m24, dut.p_val_q);
        $finish;
    end
endmodule
