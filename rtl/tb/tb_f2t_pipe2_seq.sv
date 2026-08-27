// ============================================================================
// tb_f2t_pipe2_seq.sv - подача 32 значений из ccdp_in подряд, печать хвоста
// ============================================================================
module tb_f2t_pipe2_seq;
    logic clk=0, rst_n=0, s_valid=0, m_valid;
    logic [31:0] s_data;
    logic [39:0] m_data;
    int cnt;
    int fd;
    int status;
    logic [31:0] d [0:31];

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
        fd = $fopen("sim/ccdp_in.hex", "r");
        for (int i = 0; i < 32; i++)
            status = $fscanf(fd, "%h", d[i]);
        $fclose(fd);
        for (int i = 0; i < 32; i++) begin
            s_valid = 1;
            s_data = d[i];
            @(posedge clk);
        end
        s_valid = 0;
        cnt = 0;
        for (int t = 0; t < 240; t++) begin
            @(posedge clk);
            if (m_valid) begin
                if (cnt >= 27)
                    $display("OUT[%0d]: %h", cnt, m_data);
                cnt = cnt + 1;
            end
        end
        $display("всего выходов: %0d", cnt);
        $finish;
    end
endmodule
