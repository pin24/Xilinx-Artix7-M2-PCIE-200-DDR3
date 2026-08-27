// ============================================================================
// tb_tf40_mul_pipe.sv - тестбенч конвейерного умножения
// Читает пары (a,b), подаёт в конвейер, ждёт результат.
// ============================================================================
module tb_tf40_mul_pipe;
    logic clk = 0, rst_n = 0;
    logic s_axis_tvalid = 0;
    logic [39:0] s_axis_a, s_axis_b;
    logic m_axis_tvalid;
    logic [39:0] m_axis_tdata;

    int fd_in, fd_out, status, r;
    logic [39:0] ra, rb;
    logic result_ready;

    tf40_mul_pipe dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_a(s_axis_a), .s_axis_b(s_axis_b),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tdata(m_axis_tdata)
    );

    always #5 clk = ~clk;

    initial begin
        fd_in = $fopen("sim/mulp_in.hex", "r");
        fd_out = $fopen("sim/mulp_out.hex", "w");
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        r = 0;
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h %h\n", ra, rb);
            if (status == 2) begin
                s_axis_a = ra; s_axis_b = rb;
                s_axis_tvalid = 1;
                @(posedge clk);
                s_axis_tvalid = 0;
                r = r + 1;
            end
        end
        // дождаться всех результатов (латентность ~37)
        wait (r > 0 && $feof(fd_in));
        // после подачи всех - ждём flush
        repeat(50) @(posedge clk);
        $fclose(fd_in); $fclose(fd_out);
        $display("Fed %0d pairs", r);
        $finish;
    end

    // запись результатов по мере готовности
    always_ff @(posedge clk) begin
        if (m_axis_tvalid)
            $fwrite(fd_out, "%h\n", m_axis_tdata);
    end

endmodule
