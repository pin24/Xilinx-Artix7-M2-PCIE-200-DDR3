// ============================================================================
// tb_tbyte_add.sv - тестбенч сложения байтов
// Читает векторы (a, b, cin) -> (sum, cout)
// ============================================================================
module tb_tbyte_add;
    logic [7:0] a, b, sum;
    logic [1:0] cin, cout;

    tbyte_add dut (.a(a), .b(b), .cin(cin), .sum(sum), .cout(cout));

    int fd_in, fd_out, status, r;
    logic [7:0] ra, rb;
    logic [1:0] rc;

    initial begin
        fd_in = $fopen("sim/tbyte_add_in.hex", "r");
        fd_out = $fopen("sim/tbyte_add_out.hex", "w");
        if (fd_in == 0) begin
            $display("ERROR: cannot open input");
            $finish;
        end
        r = 0;
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h %h %h\n", ra, rb, rc);
            if (status == 3) begin
                a = ra; b = rb; cin = rc;
                #1;
                $fwrite(fd_out, "%h %h\n", sum, cout);
                r = r + 1;
            end
        end
        $fclose(fd_in); $fclose(fd_out);
        $display("Processed %0d vectors", r);
        $finish;
    end
endmodule
