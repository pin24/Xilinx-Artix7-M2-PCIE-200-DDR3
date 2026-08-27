// ============================================================================
// tb_compute_dot_pipe_dbg2.sv - посактовая трассировка add на уровне 0
// ============================================================================
module tb_compute_dot_pipe_dbg2;
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
        for (int k = 0; k < 2*N; k++)
            status = $fscanf(fd_in, "%h", din[k]);
        for (int i = 0; i < N; i++) begin
            data_in[32*i +: 32] = din[i];
            weights[32*i +: 32] = din[N+i];
        end
        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        for (int t = 0; t < 1500; t++) begin
            @(posedge clk);
            if (dut.phase == 3 && dut.t_lvl == 0)
                $display("T%0d ca=%0d vin=%b vout=%b ar=%0d out=%h a=%h b=%h",
                         t, dut.ca_i, dut.add_valid_in, dut.add_valid_out, dut.ar_i,
                         dut.add_out, dut.add_a, dut.add_b);
            if (dut.valid_out) begin
                $display("DONE: result=%h", dut.result_out);
                break;
            end
        end
        $fclose(fd_in); $fclose(fd_out);
        $finish;
    end
endmodule
