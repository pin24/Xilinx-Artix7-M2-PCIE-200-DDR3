// ============================================================================
// tb_mul_pipe_pause.sv - подача 3 пар НЕПРЕРЫВНО ПОСЛЕ ДЛИННОЙ ПАУЗЫ
// (как в compute_core_dot: 130 тактов valid=0, затем valid=1,1,1).
// ============================================================================
module tb_mul_pipe_pause;
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

    int c;
    initial begin
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        // длинная пауза: 130 тактов valid=0
        repeat(130) @(posedge clk);
        s_axis_a = 40'h115a151591;   // 93.57
        s_axis_b = 40'h68520a9590;   // 46.29  (res 0x6095091595)
        s_axis_tvalid = 1;
        @(posedge clk);
        s_axis_a = 40'h1000000199;   // 3.0
        s_axis_b = 40'h6800000199;   // 5.0   (res 0x6800000192)
        @(posedge clk);
        s_axis_a = 40'h2000000199;   // -3.0
        s_axis_b = 40'h1000000199;   // 3.0   (res 0x2000000192)
        @(posedge clk);
        s_axis_tvalid = 0;
        c = 0;
        repeat(55) begin
            @(posedge clk);
            c = c + 1;
            if (m_axis_tvalid)
                $display("cycle %0d: RESULT=%h", c, m_axis_tdata);
        end
        $finish;
    end
endmodule
