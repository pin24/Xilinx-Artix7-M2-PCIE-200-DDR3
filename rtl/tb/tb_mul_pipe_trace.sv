// ============================================================================
// tb_mul_pipe_trace.sv - трассировка всех стадий конвейера tf40_mul_pipe
// Подаёт ОДНУ пару (без перекрытия) и печатает внутренние сигналы по тактам.
// ============================================================================
module tb_mul_pipe_trace;
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
        // пары: (a,b), ожидание res
        run_one(40'h1000000199, 40'h6800000199, 40'h6800000192);  // 3.0*5.0
        run_one(40'h115a151591, 40'h68520a9590, 40'h6095091595);  // 93.57*46.29
        run_one(40'h2000000199, 40'h1000000199, 40'h2000000192);  // -3.0*3.0
        run_one(40'h6666666585, 40'h6666666585, 40'h6868686984);  // 0.25*0.25
        $finish;
    end

    task run_one(input logic [39:0] a, b, exp);
        s_axis_a = a; s_axis_b = b; s_axis_tvalid = 1;
        @(posedge clk);
        s_axis_tvalid = 0;
        c = 0;
        repeat(55) begin
            @(posedge clk);
            c = c + 1;
            if (c <= 16 || c >= 22)
                $display("[t=%0d] dv13=%0d de13=%0d | nm8=%0d ne8=%0d | te15=%0d terr15=%0d tsign15=%0d tzero15=%0d tv15=%0d | out_v=%0d out=%h (exp=%h)",
                    c,
                    dut.dv[13], dut.de[13], dut.nm[8], dut.ne[8],
                    dut.te[15], dut.terr[15], dut.tsign[15], dut.tzero[15], dut.tv[15],
                    m_axis_tvalid, m_axis_tdata, exp);
        end
    endtask
endmodule
