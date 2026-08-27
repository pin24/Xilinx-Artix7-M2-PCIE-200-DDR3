// ============================================================================
// tb_tf40_to_f32.sv - тестбенч конвертера T2F
// Читает 40-битные TFloat (эталонные из Python), выводит float32.
// ============================================================================

module tb_tf40_to_f32;
    logic [39:0] tf40;
    logic [31:0] f32;

    int fd_in, fd_out, status, r;
    integer status_int;

    tf40_to_f32 dut (.tf40(tf40), .f32(f32));

    initial begin
        fd_in = $fopen("sim/t2f_in.hex", "r");
        fd_out = $fopen("sim/t2f_out.hex", "w");
        if (fd_in == 0) begin
            $display("ERROR: cannot open t2f_in.hex");
            $finish;
        end
        r = 0;
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h\n", tf40);
            if (status == 1) begin
                #10;
                $fwrite(fd_out, "%h %h\n", tf40, f32);
                r = r + 1;
            end
        end
        $fclose(fd_in);
        $fclose(fd_out);
        $display("Processed %0d vectors", r);
        $finish;
    end
endmodule
