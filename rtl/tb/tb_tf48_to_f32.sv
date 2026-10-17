// ============================================================================
// tb_tf48_to_f32.sv - тестбенч конвертера T2F (TFloat48 -> float32)
// Читает sim/t2f48_in.hex (48-бит tf48, конвенция ядра), пишет sim/t2f48_out.hex.
// ============================================================================

module tb_tf48_to_f32;

    logic [47:0] tf48;
    logic [31:0] f32;

    int fd_in, fd_out, status, r;

    tf48_to_f32 dut (.tf48(tf48), .f32(f32));

    initial begin
        fd_in = $fopen("sim/t2f48_in.hex", "r");
        fd_out = $fopen("sim/t2f48_out.hex", "w");
        if (fd_in == 0) begin
            $display("ERROR: cannot open t2f48_in.hex");
            $finish;
        end
        r = 0;
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h\n", tf48);
            if (status == 1) begin
                #10;
                $fwrite(fd_out, "%h %h\n", tf48, f32);
                r = r + 1;
            end
        end
        $fclose(fd_in);
        $fclose(fd_out);
        $display("Processed %0d vectors", r);
        $finish;
    end

endmodule