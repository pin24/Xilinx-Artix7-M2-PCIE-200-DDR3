// ============================================================================
// tb_tf40_alu.sv - тестбенч арифметического ядра
// Читает пары (a, b), прогоняет add/sub/mul/div, выводит результаты.
// Формат входа: a_hex b_hex  (по 40 бит TFloat)
// Формат выхода: a b op_add op_sub op_mul op_div (по 40 бит)
// ============================================================================

module tb_tf40_alu;
    logic [1:0] op;
    logic [39:0] a, b;
    logic [39:0] result;
    logic err_out;

    int fd_in, fd_out, status, r;
    logic [39:0] ra, rb;

    tf40_alu dut (.op(op), .a(a), .b(b), .result(result), .err_out(err_out));

    initial begin
        fd_in = $fopen("sim/alu_in.hex", "r");
        fd_out = $fopen("sim/alu_out.hex", "w");
        if (fd_in == 0) begin
            $display("ERROR: cannot open alu_in.hex");
            $finish;
        end
        r = 0;
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h %h\n", ra, rb);
            if (status == 2) begin
                a = ra; b = rb;
                op = 2'b00; #10; $fwrite(fd_out, "%h %h %h ", ra, rb, result);
                op = 2'b01; #10; $fwrite(fd_out, "%h ", result);
                op = 2'b10; #10; $fwrite(fd_out, "%h ", result);
                op = 2'b11; #10; $fwrite(fd_out, "%h\n", result);
                r = r + 1;
            end
        end
        $fclose(fd_in);
        $fclose(fd_out);
        $display("Processed %0d pairs", r);
        $finish;
    end
endmodule
