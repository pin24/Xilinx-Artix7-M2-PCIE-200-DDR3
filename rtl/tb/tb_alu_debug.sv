// ============================================================================
// tb_alu_debug.sv - отладка mul (2.5 * 0.1 = 0.25)
// ============================================================================
module tb_alu_debug;
    logic [1:0] op;
    logic [39:0] a, b;
    logic [39:0] result;
    logic err_out;
    tf40_alu dut (.op(op), .a(a), .b(b), .result(result), .err_out(err_out));

    initial begin
        a = 40'h4aaaaaa998; // 2.5
        b = 40'h4848484984; // 0.1
        op = 2'b10;
        #10;
        $display("mul 2.5*0.1: a=%h b=%h res=%h (exp 6666666585) err=%0d", a, b, result, err_out);
        $display("  Ma=%0d Mb=%0d ea=%0d eb=%0d", dut.Ma, dut.Mb, dut.ea, dut.eb);
        $display("  M_mul=%0d e_mul=%0d", dut.M_mul, dut.e_mul);
        $display("  Mn=%0d en=%0d ovf=%0d", dut.Mn, dut.en, dut.ovf);
        $display("  m_out=%h e_out=%h", dut.m_out, dut.e_out);
        $finish;
    end
endmodule
