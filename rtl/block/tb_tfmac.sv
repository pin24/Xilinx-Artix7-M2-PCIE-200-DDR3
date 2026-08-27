// ============================================================================
// tb_tfmac.sv - тестбенч MAC (mul/add)
// Читает: op a b  -> результат
// ============================================================================
module tb_tfmac;
    logic clk = 0, rst_n = 0;
    logic valid_in = 0, op;
    logic [47:0] a, b;
    logic valid_out;
    logic [47:0] result;

    tfmac dut (
        .clk(clk), .rst_n(rst_n),
        .valid_in(valid_in), .op(op), .a(a), .b(b),
        .valid_out(valid_out), .result(result)
    );

    always #5 clk = ~clk;

    int fd_in, fd_out, status, r;
    logic [47:0] ra, rb;
    logic [7:0] rop;

    initial begin
        fd_in = $fopen("sim/tfmac_in.hex", "r");
        fd_out = $fopen("sim/tfmac_out.hex", "w");
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        r = 0;
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h %h %h\n", rop, ra, rb);
            if (status == 3) begin
                op = rop[0];
                a = ra; b = rb;
                valid_in = 1;
                @(posedge clk);
                valid_in = 0;
                wait (valid_out == 1);
                $fwrite(fd_out, "%h\n", result);
                @(posedge clk);
                r = r + 1;
            end
        end
        $fclose(fd_in); $fclose(fd_out);
        $display("Processed %0d vectors", r);
        $finish;
    end

    initial begin
        #500000;
        $display("TIMEOUT phase=%0d", dut.phase);
        $fclose(fd_in); $fclose(fd_out);
        $finish;
    end
endmodule
