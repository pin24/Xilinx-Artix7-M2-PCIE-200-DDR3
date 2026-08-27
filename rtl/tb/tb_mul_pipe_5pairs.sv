// ============================================================================
// tb_mul_pipe_5pairs.sv - НЕПРЕРЫВНАЯ подача 5 пар (valid=1 каждый такт),
// проверка что valid и данные не расходятся при длинной непрерывной подаче.
// Пары: 93.57*46.29, 3*5, -3*3, 3*5, 93.57*46.29
// ============================================================================
module tb_mul_pipe_5pairs;
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
        // непрерывная подача 5 пар: valid=1 каждый такт
        s_axis_a = 40'h115a151591; s_axis_b = 40'h68520a9590; // 93.57*46.29 -> 6095091595
        s_axis_tvalid = 1;
        @(posedge clk);
        s_axis_a = 40'h1000000199; s_axis_b = 40'h6800000199; // 3*5 -> 6800000192
        @(posedge clk);
        s_axis_a = 40'h2000000199; s_axis_b = 40'h1000000199; // -3*3 -> 2000000192
        @(posedge clk);
        s_axis_a = 40'h1000000199; s_axis_b = 40'h6800000199; // 3*5 -> 6800000192
        @(posedge clk);
        s_axis_a = 40'h115a151591; s_axis_b = 40'h68520a9590; // 93.57*46.29 -> 6095091595
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
