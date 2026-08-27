// ============================================================================
// tb_f32_to_tf40.sv - тестбенч конвертера F2T
// Сверка с Python-эталоном: читает векторы из файла, выводит результат,
// сравнение делается внешним скриптом (Python) по дампу.
// ============================================================================

module tb_f32_to_tf40;

    logic [31:0] f32;
    logic [39:0] tf40;
    logic [39:0] tf_expected;

    int fd_in, fd_out, status, num;
    integer r;

    f32_to_tf40 dut (.f32(f32), .tf40(tf40));

    initial begin
        // входные: 40-бит float32 в hex
        fd_in = $fopen("sim/f2t_in.hex", "r");
        fd_out = $fopen("sim/f2t_out.hex", "w");
        if (fd_in == 0) begin
            $display("ERROR: cannot open f2t_in.hex");
            $finish;
        end
        r = 0;
        while (!$feof(fd_in)) begin
            status = $fscanf(fd_in, "%h\n", f32);
            if (status == 1) begin
                #10;
                $fwrite(fd_out, "%h %h\n", f32, tf40);
                r = r + 1;
            end
        end
        $fclose(fd_in);
        $fclose(fd_out);
        $display("Processed %0d vectors", r);
        $finish;
    end

endmodule
