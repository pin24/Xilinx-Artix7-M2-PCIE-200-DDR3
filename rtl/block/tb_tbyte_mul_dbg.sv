// ============================================================================
// tb_tbyte_mul_dbg.sv - отладка tbyte_mul на a=39 b=d8
// ============================================================================
module tb_tbyte_mul_dbg;
    logic [7:0] a = 8'h39, b = 8'hd8;
    logic [15:0] prod;

    tbyte_mul dut (.a(a), .b(b), .prod(prod));

    initial begin
        #1;
        $display("a=%h b=%h prod=%h", a, b, prod);
        for (int i = 0; i < 4; i++)
            $display("pt[%0d] = %0d %0d %0d %0d", i, dut.pt[i][0], dut.pt[i][1], dut.pt[i][2], dut.pt[i][3]);
        for (int k = 0; k < 8; k++)
            $display("coeff[%0d]=%0d carry[%0d]=%0d", k, dut.coeff[k], k, dut.carry[k]);
        $display("carry[8]=%0d", dut.carry[8]);
        // отладочные s/q/r
        for (int k = 0; k < 8; k++)
            $display("k=%0d s=%0d q=%0d r=%0d", k, dut.s_show[k], dut.q_show[k], dut.r_show[k]);
        for (int k = 0; k < 8; k++)
            $display("trit[%0d]=%b", k, prod[2*k +: 2]);
        $finish;
    end
endmodule
