// ============================================================================
// tb_tfmac_dbg.sv - отладка 5-го вектора (индекс 4)
// ============================================================================
module tb_tfmac_dbg;
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

    int fd, status, r;
    logic [7:0] rop;
    logic [47:0] ra, rb;

    initial begin
        fd = $fopen("sim/tfmac_in.hex", "r");
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        r = 0;
        while (!$feof(fd) && r < 1) begin
            status = $fscanf(fd, "%h %h %h\n", rop, ra, rb);
            if (status == 3) begin
                op = rop[0];
                a = ra; b = rb;
                $display("VEC[%0d] op=%0d a=%h b=%h", r, op, a, b);
                valid_in = 1;
                @(posedge clk);
                valid_in = 0;
                for (int t = 0; t < 200; t++) begin
                    @(posedge clk);
                    if (dut.phase == 5 && dut.msb_abs == 18)
                        $display("NORM final prod_abs=%h e=%0d msign=%0d",
                                 dut.prod_abs, dut.e, dut.msign);
                    if (dut.phase == 5 && dut.e == 3)
                        $display("NORM e=3 val_abs=%0d ge19=%0d lt18=%0d prod40=%h",
                                 dut.val_abs, dut.val_ge_p19, dut.val_lt_p18, dut.prod_abs[39:0]);
                    if (dut.phase == 5 && dut.e == 4)
                        $display("NORM e=4 val_abs=%0d ge19=%0d prod40=%h",
                                 dut.val_abs, dut.val_ge_p19, dut.prod_abs[39:0]);
                    if (valid_out) begin
                        $display("RESULT=%h", result);
                        break;
                    end
                end
                r = r + 1;
            end
        end
        $fclose(fd);
        $finish;
    end

    initial begin
        #1000000;
        $display("TIMEOUT phase=%0d", dut.phase);
        $finish;
    end
endmodule
