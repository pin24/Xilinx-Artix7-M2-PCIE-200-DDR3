// ============================================================================
// tb_f2t_pipe.sv - тестбенч конвейерного F2T
// ============================================================================
module tb_f2t_pipe;
    logic clk=0, rst_n=0, s_valid=0, m_valid;
    logic [31:0] s_data;
    logic [39:0] m_data;

    int fd_in, fd_out, status, r;
    logic [31:0] din;

    f32_to_tf40_pipe dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_valid), .s_axis_tdata(s_data),
        .m_axis_tvalid(m_valid), .m_axis_tdata(m_data)
    );

    always #5 clk = ~clk;

    initial begin
        fd_in = $fopen("sim/f2tp_in.hex", "r");
        fd_out = $fopen("sim/f2tp_out.hex", "w");
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        r = 0;
        // подаём входы, собираем выходы через m_valid
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h\n", din);
            if (status == 1) begin
                s_valid = 1;
                s_data = din;
            end else begin
                s_valid = 0;
            end
            @(posedge clk);
            if (m_valid) begin
                $fwrite(fd_out, "%h\n", m_data);
                r = r + 1;
            end
        end
        // доиграть хвост конвейера
        for (int i = 0; i < 100; i++) begin
            s_valid = 0;
            @(posedge clk);
            if (m_valid) begin
                $fwrite(fd_out, "%h\n", m_data);
                r = r + 1;
            end
        end
        $fclose(fd_in); $fclose(fd_out);
        $display("Output %0d values", r);
        $finish;
    end
endmodule
