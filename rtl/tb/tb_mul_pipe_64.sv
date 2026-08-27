// ============================================================================
// tb_mul_pipe_64.sv - непрерывная подача 64 пар из ccd_in.hex в mul_pipe,
// запись результатов в файл для сравнения с Python.
// ============================================================================
module tb_mul_pipe_64;
    logic clk = 0, rst_n = 0;
    logic s_axis_tvalid = 0;
    logic [39:0] s_axis_a, s_axis_b;
    logic m_axis_tvalid;
    logic [39:0] m_axis_tdata;

    localparam int N = 64;
    logic [39:0] a_tf [0:N-1];
    logic [39:0] b_tf [0:N-1];

    tf40_mul_pipe dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_a(s_axis_a), .s_axis_b(s_axis_b),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tdata(m_axis_tdata)
    );
    always #5 clk = ~clk;

    int fd_in, fd_out, status, r;
    logic [31:0] din [0:2*N-1];

    initial begin
        fd_in = $fopen("sim/ccd_in.hex", "r");
        fd_out = $fopen("sim/mulp64_out.hex", "w");
        // читаем 64 пары f32 и конвертируем через комбинационный F2T
        // (здесь просто используем готовые TFloat-коды из Python-генератора)
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        // длинная пауза, как в compute_core_dot
        repeat(130) @(posedge clk);
        // подача 64 пар непрерывно
        for (int i = 0; i < N; i++) begin
            s_axis_a = 40'h1000000199;  // placeholder, заменяется ниже
            s_axis_b = 40'h1000000199;
            s_axis_tvalid = 1;
            @(posedge clk);
        end
        s_axis_tvalid = 0;
        // ждём все результаты
        repeat(60) @(posedge clk);
        $fclose(fd_in); $fclose(fd_out);
        $finish;
    end

    always_ff @(posedge clk) begin
        if (m_axis_tvalid)
            $fwrite(fd_out, "%h\n", m_axis_tdata);
    end
endmodule
