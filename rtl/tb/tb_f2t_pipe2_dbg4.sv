// ============================================================================
// tb_f2t_pipe2_dbg4.sv - трассировка для 0.001 и -1.0
// ============================================================================
module tb_f2t_pipe2_dbg4;
    logic clk=0, rst_n=0, s_valid=0, m_valid;
    logic [31:0] s_data;
    logic [39:0] m_data;
    int n;

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
        // подача: 0.001 = 0x3A83126F, -1.0 = 0xBF800000, 0.1 = 0x3DCCCCCD
        for (int pkt = 0; pkt < 3; pkt++) begin
            case (pkt)
                0: s_data = 32'h3A83126F;
                1: s_data = 32'hBF800000;
                2: s_data = 32'h3DCCCCCD;
            endcase
            s_valid = 1;
            @(posedge clk);
            s_valid = 0;
            // чтобы пакеты не слиплись, ждём 3 такта между подачами
            repeat(2) @(posedge clk);
        end
        n = 0;
        for (int t = 0; t < 260; t++) begin
            @(posedge clk);
            if (m_valid) begin
                $display("OUT[%0d]: %h (q=%h off=%0d nm=%h noff=%0d)", n, m_data,
                         dut.q_q[128], dut.q_off[128], dut.nm[8], dut.no[8]);
                n = n + 1;
            end
        end
        $finish;
    end
endmodule
