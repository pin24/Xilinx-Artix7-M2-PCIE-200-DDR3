// ============================================================================
// tb_tbyte_mul.sv - тестбенч умножения байтов
// Читает векторы (a, b) -> (prod 16 бит)
// ============================================================================
module tb_tbyte_mul;
    logic [7:0] a, b;
    logic [15:0] prod;

    tbyte_mul dut (.a(a), .b(b), .prod(prod));

    int fd_in, fd_out, status, r;
    logic [7:0] ra, rb;

    initial begin
        fd_in = $fopen("sim/tbyte_mul_in.hex", "r");
        fd_out = $fopen("sim/tbyte_mul_out.hex", "w");
        if (fd_in == 0) begin
            $display("ERROR: cannot open input");
            $finish;
        end
        r = 0;
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h %h\n", ra, rb);
            if (status == 2) begin
                a = ra; b = rb;
                #1;
                $fwrite(fd_out, "%h\n", prod);
                r = r + 1;
            end
        end
        $fclose(fd_in); $fclose(fd_out);
        $display("Processed %0d vectors", r);
        $finish;
    end
endmodule
