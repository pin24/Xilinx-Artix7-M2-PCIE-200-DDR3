// ============================================================================
// tb_f2t_pipe2_dbg.sv - отладка конвейерного F2T на 1-м значении (1.0)
// ============================================================================
module tb_f2t_pipe2_dbg;
    logic clk=0, rst_n=0, s_valid=0, m_valid;
    logic [31:0] s_data;
    logic [39:0] m_data;

    f32_to_tf40_pipe2 dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_valid), .s_axis_tdata(s_data),
        .m_axis_tvalid(m_valid), .m_axis_tdata(m_data)
    );

    always #5 clk = ~clk;

    int fd_in, status, r;
    logic [31:0] din;
    logic [127:0] last_D;
    logic [127:0] last_q;
    logic [7:0] last_off;
    logic [127:0] last_nm;

    initial begin
        fd_in = $fopen("sim/f2t2_in.hex", "r");
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        r = 0;
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h\n", din);
            if (status == 1) begin
                s_valid = 1; s_data = din;
            end else s_valid = 0;
            @(posedge clk);
            last_D  = dut.d_D[61];
            last_q  = dut.q_q[128];
            last_off = dut.q_off[128];
            last_nm = dut.nm[8];
            if (m_valid && r < 3) begin
                $display("DBG %0d: out=%h D=%h off=%0d q=%h nm=%h", r, m_data, last_D, last_off, last_q, last_nm);
                r = r + 1;
            end
        end
        for (int i = 0; i < 240; i++) begin
            s_valid = 0;
            @(posedge clk);
            last_D  = dut.d_D[61];
            last_q  = dut.q_q[128];
            last_off = dut.q_off[128];
            last_nm = dut.nm[8];
            if (m_valid && r < 5) begin
                $display("DBG %0d: out=%h D=%h off=%0d q=%h nm=%h", r, m_data, last_D, last_off, last_q, last_nm);
                r = r + 1;
            end
        end
        $fclose(fd_in);
        $finish;
    end
endmodule
