// ============================================================================
// tb_tf40_dot.sv - тестбенч векторного ядра (N=4)
// Читает строки: a0 a1 a2 a3 b0 b1 b2 b3 (по 40 бит TFloat)
// Выводит: a0..a3 b0..b3 result
// ============================================================================

module tb_tf40_dot;
    localparam int N = 4;
    logic [39:0] a [0:N-1];
    logic [39:0] b [0:N-1];
    logic [39:0] result;
    logic err_out;

    int fd_in, fd_out, status, r;
    logic [39:0] av [0:N-1];
    logic [39:0] bv [0:N-1];

    tf40_dot #(.N(N)) dut (.a(a), .b(b), .result(result), .err_out(err_out));

    initial begin
        fd_in = $fopen("sim/dot_in.hex", "r");
        fd_out = $fopen("sim/dot_out.hex", "w");
        if (fd_in == 0) begin
            $display("ERROR: cannot open dot_in.hex");
            $finish;
        end
        r = 0;
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h %h %h %h %h %h %h %h\n",
                             av[0], av[1], av[2], av[3],
                             bv[0], bv[1], bv[2], bv[3]);
            if (status == 8) begin
                for (int i = 0; i < N; i++) begin
                    a[i] = av[i];
                    b[i] = bv[i];
                end
                #10;
                $fwrite(fd_out, "%h %h %h %h %h %h %h %h %h\n",
                        av[0], av[1], av[2], av[3],
                        bv[0], bv[1], bv[2], bv[3], result);
                r = r + 1;
            end
        end
        $fclose(fd_in);
        $fclose(fd_out);
        $display("Processed %0d dot vectors", r);
        $finish;
    end
endmodule
