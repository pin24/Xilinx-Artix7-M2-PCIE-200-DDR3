
module tb_rtl_vs_arith48;
    parameter int NUM_MAC = 32;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;
    logic [48*NUM_MAC-1:0] data_in, weights;
    logic valid_in = 0;
    logic [47:0] result_out;
    logic valid_out;
    compute_dot_par_raw #(.NUM_MAC(NUM_MAC)) u (.clk(clk), .rst_n(rst_n),
        .data_in(data_in), .weights(weights), .valid_in(valid_in),
        .result_out(result_out), .valid_out(valid_out));
    integer f, g, k, ncase, npair;
    logic [47:0] w;
    initial begin
        #20 rst_n <= 1;
        #20;
        f = $fopen("/home/z/my-project/repo/main/rtl/block/sim/rtl48_in.hex", "r");
        g = $fopen("/home/z/my-project/repo/main/rtl/block/sim/rtl48_out.hex", "w");
        ncase = 0;
        while (!$feof(f)) begin
            // один случай = NUM_MAC пар
            npair = 0;
            for (k = 0; k < NUM_MAC; k = k + 1) begin
                if ($fscanf(f, "%h", w) != 1) break;
                data_in[48*k +: 48] <= w;
                $fscanf(f, "%h", w);
                weights[48*k +: 48] <= w;
                npair = npair + 1;
            end
            if (npair < NUM_MAC) break;   // конец файла
            @(posedge clk);
            valid_in <= 1;
            @(posedge clk);
            valid_in <= 0;
            wait (valid_out);
            @(posedge clk);
            $fwrite(g, "%012h\n", result_out);
            ncase = ncase + 1;
            #20;
        end
        $fclose(f); $fclose(g);
        $display("processed %0d cases", ncase);
        $finish;
    end
endmodule
