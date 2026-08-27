// ============================================================================
// tb_mul_pipe_64c.sv - НЕПРЕРЫВНАЯ подача 64 пар (valid=1 каждый такт, без
// пауз) с печатью vout+res на каждый такт. Проверка синхронности valid/data.
// ============================================================================
module tb_mul_pipe_64c;
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

    int fd_in, status, r;
    logic [39:0] ra, rb;
    int c;

    initial begin
        fd_in = $fopen("sim/mulp64_in.hex", "r");
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        repeat(130) @(posedge clk);
        r = 0;
        // непрерывная подача: valid=1 каждый такт
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h %h\n", ra, rb);
            if (status == 2) begin
                s_axis_a = ra; s_axis_b = rb;
                s_axis_tvalid = 1;
                @(posedge clk);
                r = r + 1;
            end
        end
        s_axis_tvalid = 0;
        c = 0;
        repeat(55) begin
            @(posedge clk);
            c = c + 1;
            $display("  [out T=%0d] vout=%0d res=%h", c, m_axis_tvalid, m_axis_tdata);
        end
        $display("Fed %0d pairs", r);
        $finish;
    end
endmodule
