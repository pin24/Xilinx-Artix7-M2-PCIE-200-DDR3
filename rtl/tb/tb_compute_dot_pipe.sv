// ============================================================================
// tb_compute_dot_pipe.sv - сквозной тестбенч конвейерного compute_core_dot_pipe
// ============================================================================
module tb_compute_dot_pipe;
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
        #3000000;
        $display("TIMEOUT: phase=%0d valid_out=%0d", dut.phase, valid_out);
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
        while (!$feof(fd_in)) begin
            for (int k = 0; k < 2*N; k++) begin
                status = $fscanf(fd_in, "%h", din[k]);
                if (status != 1) begin
                    $fclose(fd_in); $fclose(fd_out);
                    $display("Processed %0d cases", r);
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
            wait (valid_out == 1);
            $fwrite(fd_out, "%h\n", result_out);
            @(posedge clk);
            r = r + 1;
        end
    end
endmodule
