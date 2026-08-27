// ============================================================================
// tb_f2t_pipe2_dbg2.sv - трассировка построения D для одного пакета (1.0)
// ============================================================================
module tb_f2t_pipe2_dbg2;
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
        // подача 1.0 = 0x3f800000
        s_valid = 1;
        s_data = 32'h3f800000;
        @(posedge clk);
        s_valid = 0;
        $display("S0: val_q=%h sign=%b", dut.s0_val_q, dut.s0_sign);
        // наблюдаем стадии построения D, когда пакет проходит
        for (int t = 0; t < 75; t++) begin
            @(posedge clk);
            if (t == 1)
                $display("S1: val_q=%h p3=%h", dut.s1_val_q, dut.s1_p3);
            if (t == 3)
                $display("DB0: vq=%h D=%h off=%0d up=%b", dut.d_vq[0], dut.d_D[0], dut.d_off[0], dut.d_up[0]);
            if (t == 8)
                $display("DB5: vq=%h D=%h off=%0d", dut.d_vq[5], dut.d_D[5], dut.d_off[5]);
            if (t == 30)
                $display("DB27: vq=%h D=%h off=%0d", dut.d_vq[27], dut.d_D[27], dut.d_off[27]);
            if (t == 60)
                $display("DB57: vq=%h D=%h off=%0d", dut.d_vq[57], dut.d_D[57], dut.d_off[57]);
            if (t == 63)
                $display("DB61: vq=%h D=%h off=%0d p3=%h", dut.d_vq[61], dut.d_D[61], dut.d_off[61], dut.d_p3[61]);
        end
        $finish;
    end
endmodule
