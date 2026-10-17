// ============================================================================
// tb_tf48_to_f32_pipe.sv - тестбенч конвейерного T2F (tf48_to_f32_pipe)
// Читает sim/t2f48p_in.hex, пишет sim/t2f48p_out.hex. Вход/валидность на negedge.
// ============================================================================
module tb_tf48_to_f32_pipe;
    logic clk=0, rst_n=0, s_valid=0, m_valid;
    logic [47:0] s_data;
    logic [31:0] m_data;

    int fd_in, fd_out, status, r;
    logic [47:0] din;

    tf48_to_f32_pipe dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_valid), .s_axis_tdata(s_data),
        .m_axis_tvalid(m_valid), .m_axis_tdata(m_data)
    );

    always #5 clk = ~clk;

    logic       drive_valid_q;
    logic [47:0] drive_data_q;

    always_ff @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_valid <= 0;
            s_data  <= 0;
        end else begin
            s_valid <= drive_valid_q;
            s_data  <= drive_data_q;
        end
    end

    initial begin
        fd_in = $fopen("sim/t2f48p_in.hex", "r");
        fd_out = $fopen("sim/t2f48p_out.hex", "w");
        rst_n = 0; drive_valid_q = 0; drive_data_q = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        r = 0;
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h\n", din);
            if (status == 1) begin
                drive_valid_q = 1;
                drive_data_q  = din;
            end else begin
                drive_valid_q = 0;
            end
            @(posedge clk);
            if (m_valid) begin
                $fwrite(fd_out, "%h\n", m_data);
                r = r + 1;
            end
        end
        for (int i = 0; i < 400; i++) begin
            drive_valid_q = 0;
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