// ============================================================================
// tb_compute_dot_pipe_dbg7.sv - трассировка захвата F2T в compute_core
// ============================================================================
module tb_compute_dot_pipe_dbg7;
    localparam int N = 16;
    logic clk = 0, rst_n = 0;
    logic [32*N-1:0] data_in, weights;
    logic valid_in = 0;
    logic [31:0] result_out;
    logic valid_out, err_out;

    int fd_in, status;
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
        $finish;
    end

    initial begin
        fd_in = $fopen("sim/ccdp_in.hex", "r");
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        for (int k = 0; k < 2*N; k++)
            status = $fscanf(fd_in, "%h", din[k]);
        for (int i = 0; i < N; i++) begin
            data_in[32*i +: 32] = din[i];
            weights[32*i +: 32] = din[N+i];
        end
        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        for (int t = 0; t < 320; t++) begin
            @(posedge clk);
            if (dut.phase == 1 && dut.f2t_valid_in)
                $display("FEED cv=%0d din=%h", dut.cv_i, dut.f2t_data_in);
            if (dut.f2t_valid_out)
                $display("  RCV cr=%0d out=%h", dut.cr_i, dut.f2t_data_out);
            if (dut.phase == 2)
                break;
        end
        $finish;
    end
endmodule
