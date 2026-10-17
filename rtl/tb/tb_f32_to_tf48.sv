// ============================================================================
// tb_f32_to_tf48.sv - тестбенч конвертера F2T (float32 -> TFloat48)
// Читает sim/f2t48_in.hex (float32 биты), пишет sim/f2t48_out.hex (48-бит слово).
// Сравнение - внешним Python-скриптом (verify_rtl_f2t48.py).
// ============================================================================

module tb_f32_to_tf48;

    logic [31:0] f32;
    logic [47:0] tf48;

    int fd_in, fd_out, status, r;

    f32_to_tf48 dut (.f32(f32), .tf48(tf48));

    initial begin
        fd_in = $fopen("sim/f2t48_in.hex", "r");
        fd_out = $fopen("sim/f2t48_out.hex", "w");
        if (fd_in == 0) begin
            $display("ERROR: cannot open f2t48_in.hex");
            $finish;
        end
        r = 0;
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h\n", f32);
            if (status == 1) begin
                #10;
                $fwrite(fd_out, "%h %h\n", f32, tf48);
                r = r + 1;
            end
        end
        $fclose(fd_in);
        $fclose(fd_out);
        $display("Processed %0d vectors", r);
        $finish;
    end

endmodule