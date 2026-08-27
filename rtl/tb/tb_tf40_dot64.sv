// ============================================================================
// tb_tf40_dot64.sv - тестбенч векторного ядра N=64
// Формат входа: 64 a-значений + 64 b-значений (по 40 бит) в строке
// Формат выхода: a[0] a[1] ... a[63] b[0] ... b[63] result
// Упрощение: вход - 40 бит TFloat каждое, 128 чисел на строку.
// ============================================================================
module tb_tf40_dot64;
    localparam int N = 64;
    logic [39:0] a [0:N-1];
    logic [39:0] b [0:N-1];
    logic [39:0] result;
    logic err_out;

    int fd_in, fd_out, status, r;
    logic [39:0] v [0:2*N-1];

    tf40_dot #(.N(N)) dut (.a(a), .b(b), .result(result), .err_out(err_out));

    initial begin
        fd_in = $fopen("sim/dot64_in.hex", "r");
        fd_out = $fopen("sim/dot64_out.hex", "w");
        if (fd_in == 0) begin
            $display("ERROR: cannot open dot64_in.hex");
            $finish;
        end
        r = 0;
        while (!$feof(fd_in)) begin
            // читаем 128 hex-значений
            for (int k = 0; k < 2*N; k++) begin
                status = $fscanf(fd_in, "%h", v[k]);
                if (status != 1) begin
                    // конец файла
                    $fclose(fd_in); $fclose(fd_out);
                    $display("Processed %0d dot64 vectors", r);
                    $finish;
                end
            end
            for (int i = 0; i < N; i++) begin
                a[i] = v[i];
                b[i] = v[N+i];
            end
            #10;
            $fwrite(fd_out, "%h\n", result);
            r = r + 1;
        end
    end
endmodule
