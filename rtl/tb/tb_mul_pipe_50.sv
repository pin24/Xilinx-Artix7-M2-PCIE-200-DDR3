// ============================================================================
// tb_mul_pipe_50.sv - НЕПРЕРЫВНАЯ подача 50 пар (длиннее латентности 41),
// чередующиеся значения. Проверка бага при заполненном конвейере.
// Пары чередуются: 3*5 (=6800000192) и 93.57*46.29 (=6095091595)
// ============================================================================
module tb_mul_pipe_50;
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

    int c, r;
    initial begin
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        repeat(130) @(posedge clk);
        // непрерывная подача 50 пар, чередование двух значений
        for (int i = 0; i < 50; i++) begin
            if (i % 2 == 0) begin
                s_axis_a = 40'h1000000199; s_axis_b = 40'h6800000199; // 3*5
            end else begin
                s_axis_a = 40'h115a151591; s_axis_b = 40'h68520a9590; // 93.57*46.29
            end
            s_axis_tvalid = 1;
            @(posedge clk);
        end
        s_axis_tvalid = 0;
        c = 0; r = 0;
        repeat(60) begin
            @(posedge clk);
            c = c + 1;
            $display("  [out T=%0d] vout=%0d res=%h", c, m_axis_tvalid, m_axis_tdata);
            if (m_axis_tvalid) r = r + 1;
        end
        $finish;
    end
endmodule
