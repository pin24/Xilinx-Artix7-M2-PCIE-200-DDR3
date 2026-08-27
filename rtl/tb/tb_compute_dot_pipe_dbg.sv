// ============================================================================
// tb_compute_dot_pipe_dbg.sv - отладка конвейерного dot
// ============================================================================
module tb_compute_dot_pipe_dbg;
    localparam int N = 16;
    logic clk = 0, rst_n = 0;
    logic [32*N-1:0] data_in, weights;
    logic valid_in = 0;
    logic [31:0] result_out;
    logic valid_out, err_out;

    int fd_in, fd_out, status, r;
    logic [31:0] din [0:2*N-1];

    compute_core_dot_pipe #(.N(N)) dut (
        .clk(clk), .rst_n(rst_n),
        .data_in(data_in), .weights(weights), .valid_in(valid_in),
        .result_out(result_out), .valid_out(valid_out), .err_out(err_out)
    );

    always #5 clk = ~clk;

    initial begin
        #2000000;
        $display("TIMEOUT phase=%0d", dut.phase);
        $fclose(fd_in); $fclose(fd_out);
        $finish;
    end

    initial begin
        fd_in = $fopen("sim/ccdp_in.hex", "r");
        fd_out = $fopen("sim/ccdp_out.hex", "w");
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        r = 0;
        // обработаем только 1 случай
        while (!$feof(fd_in) && r < 1) begin
            for (int k = 0; k < 2*N; k++) begin
                status = $fscanf(fd_in, "%h", din[k]);
                if (status != 1) begin
                    $fclose(fd_in); $fclose(fd_out);
                    $finish;
                end
            end
            for (int i = 0; i < N; i++) begin
                data_in[32*i +: 32] = din[i];
                weights[32*i +: 32] = din[N+i];
            end
            valid_in = 1;
            @(posedge clk);
            valid_in = 0;
            // трассируем фазы
            for (int t = 0; t < 2000; t++) begin
                @(posedge clk);
                if (dut.phase == 1 && dut.f2t_valid_out)
                    $display("F2T[%0d]: %h", dut.cr_i, dut.f2t_data_out);
                if (dut.phase == 2 && dut.mul_valid_out)
                    $display("MUL[%0d]: %h", dut.pr_i, dut.mul_out);
                if (dut.phase == 3 && dut.add_valid_out)
                    $display("ADD lvl=%0d ar=%0d: %h", dut.t_lvl, dut.ar_i, dut.add_out);
                if (dut.valid_out) begin
                    $display("DONE: result=%h dot_res=%h err=%b", dut.result_out, dut.dot_res, dut.err_out);
                    break;
                end
            end
            @(posedge clk);
            r = r + 1;
        end
        $fclose(fd_in); $fclose(fd_out);
        $finish;
    end
endmodule
