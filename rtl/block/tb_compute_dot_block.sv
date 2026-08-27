// ============================================================================
// tb_compute_dot_block.sv - тестбенч compute_core_dot_block (N=16)
// ============================================================================
module tb_compute_dot_block;
    localparam int N = 16;
    logic clk = 0, rst_n = 0;
    logic [48*N-1:0] data_in, weights;
    logic valid_in = 0;
    logic [47:0] result_out;
    logic valid_out;

    compute_core_dot_block #(.N(N)) dut (
        .clk(clk), .rst_n(rst_n),
        .data_in(data_in), .weights(weights), .valid_in(valid_in),
        .result_out(result_out), .valid_out(valid_out)
    );

    always #5 clk = ~clk;

    int fd_in, fd_out, status, r;
    logic [47:0] din [0:2*N-1];

    initial begin
        fd_in = $fopen("sim/ccdb_in.hex", "r");
        fd_out = $fopen("sim/ccdb_out.hex", "w");
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
                data_in[48*i +: 48] = din[i];
                weights[48*i +: 48] = din[N+i];
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

    initial begin
        #3000000;
        $display("TIMEOUT phase=%0d", dut.phase);
        $fclose(fd_in); $fclose(fd_out);
        $finish;
    end
endmodule
