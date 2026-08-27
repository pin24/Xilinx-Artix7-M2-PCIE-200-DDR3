// ============================================================================
// tb_f2t_debug.sv - отладочный тестбенч: дамп промежуточных сигналов для 1.0
// ============================================================================

module tb_f2t_debug;
    logic [31:0] f32;
    logic [39:0] tf40;

    // подключимся к внутренним сигналам DUT
    f32_to_tf40 dut (.f32(f32), .tf40(tf40));

    initial begin
        // 1.0
        f32 = 32'h3f800000;  // float32 1.0
        #10;
        $display("f32=1.0 tf40=%h", tf40);
        // внутренние
        $display("val_q=%h", dut.val_q);
        $display("value_p3=%h", dut.value_p3);
        $display("pow3[60]=%h pow3[61]=%h", dut.pow3_for_e[60], dut.pow3_for_e[61]);
        $display("pow3[0]=%h pow3[121]=%h", dut.pow3_for_e[0], dut.pow3_for_e[121]);
        $display("e3_off=%0d e3=%0d", dut.e3_off, dut.e3);
        $display("M_raw=%h M=%h e3n=%0d", dut.M_raw, dut.M, dut.e3n);
        $display("m_trits=%h e_trits=%h", dut.m_trits, dut.e_trits);

        // 0.5
        f32 = 32'h3f000000;
        #10;
        $display("f32=0.5 tf40=%h", tf40);
        $display("  e3_off=%0d M=%h", dut.e3_off, dut.M);

        // 3.0
        f32 = 32'h40400000;
        #10;
        $display("f32=3.0 tf40=%h", tf40);
        $display("  e2=%0d mant=%h shift=%0d shamt=%0d val_q=%h", dut.e2, dut.mant, dut.shift, dut.shamt, dut.val_q);
        $display("  value_p3=%h e3_off=%0d M=%h", dut.value_p3, dut.e3_off, dut.M);

        // 0.1
        f32 = 32'h3dcccccd;
        #10;
        $display("f32=0.1 tf40=%h", tf40);
        $display("  e3_off=%0d M=%h", dut.e3_off, dut.M);

        $finish;
    end
endmodule
