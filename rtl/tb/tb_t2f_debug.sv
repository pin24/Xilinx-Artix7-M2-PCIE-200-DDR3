// ============================================================================
// tb_t2f_debug.sv - отладочный тестбенч T2F
// ============================================================================
module tb_t2f_debug;
    logic [39:0] tf40;
    logic [31:0] f32;
    tf40_to_f32 dut (.tf40(tf40), .f32(f32));

    initial begin
        // 1.0
        tf40 = 40'h1000000198;
        #10;
        $display("tf40=1.0 f32=%h", f32);
        $display("  M=%0d Mabs=%0d e=%0d e2=%0d", dut.M, dut.Mabs, dut.e, dut.e2);
        $display("  sh2=%0d val3=%h val3n=%h", dut.sh2, dut.val3, dut.val3n);
        $display("  m2=%h mn=%h mant24=%h e2out=%0d sign=%0d", dut.m2, dut.mn, dut.mant24, dut.e2out, dut.sign);
        $display("  out_norm=%h", dut.out_norm);
        // 3.0
        tf40 = 40'h1000000199;
        #10;
        $display("tf40=3.0 f32=%h", f32);
        $display("  M=%0d e=%0d e2=%0d m2=%h mn=%h", dut.M, dut.e, dut.e2, dut.m2, dut.mn);
        $finish;
    end
endmodule
