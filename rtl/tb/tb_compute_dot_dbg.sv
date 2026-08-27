// ============================================================================
// tb_compute_dot_dbg.sv - ?????????????? compute_core_dot (?????????? ???????????? ?? pbuf)
// ============================================================================
module tb_compute_dot_dbg;
    localparam int N = 64;
    localparam int PH_IDLE = 0, PH_CONV = 1, PH_MUL = 2, PH_MUL_LAST = 3, PH_TREE = 4, PH_DONE = 5;
    logic clk = 0, rst_n = 0;
    logic [32*N-1:0] data_in, weights;
    logic valid_in = 0;
    logic [31:0] result_out;
    logic valid_out, err_out;

    int fd_in, status;
    logic [31:0] din [0:2*N-1];

    compute_core_dot #(.N(N)) dut (
        .clk(clk), .rst_n(rst_n),
        .data_in(data_in), .weights(weights), .valid_in(valid_in),
        .result_out(result_out), .valid_out(valid_out), .err_out(err_out)
    );
    always #5 clk = ~clk;

    initial begin
        fd_in = $fopen("sim/ccd_in.hex", "r");
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        for (int k = 0; k < 2*N; k++) begin
            status = $fscanf(fd_in, "%h", din[k]);
        end
        for (int i = 0; i < N; i++) begin
            data_in[32*i +: 32] = din[i];
            weights[32*i +: 32] = din[N+i];
        end
        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        wait (valid_out == 1);
        $display("RESULT=%h", result_out);
        $finish;
    end

    // ???????????? ???????????????? ???????????????? FSM
    int pclk = 0;
    int cclk = 0;
    always_ff @(posedge clk) begin
        if (dut.phase == PH_CONV) begin
            cclk = cclk + 1;
            if (cclk <= 6)
                $display("  [conv T=%0d] ci=%0d f2t_in=%h f2t_out=%h a_tf[ci]=%h",
                         cclk, dut.ci, dut.f2t_in, dut.f2t_out,
                         (dut.ci < N) ? dut.a_tf[dut.ci] : 40'h0);
        end
        if (dut.phase == PH_MUL) begin
            pclk = pclk + 1;
            if (pclk == 1)
                $display("  [mul start] a_tf[0..3]=%h %h %h %h | b_tf[0..3]=%h %h %h %h",
                         dut.a_tf[0], dut.a_tf[1], dut.a_tf[2], dut.a_tf[3],
                         dut.b_tf[0], dut.b_tf[1], dut.b_tf[2], dut.b_tf[3]);
            if (pclk <= 4)
                $display("  [mul T=%0d] p_idx=%0d m_a=%h m_b=%h m_res=%h",
                         pclk, dut.p_idx, dut.m_a, dut.m_b, dut.m_res);
        end
        if (dut.phase == PH_TREE && dut.t_idx == 0) begin
            $display("  [lvl%0d start] t_dst=%0d add_a=%h add_b=%h add_r=%h | pbuf0[0..3]=%h %h %h %h pbuf1[0]=%h",
                     dut.t_lvl, dut.t_dst, dut.add_a, dut.add_b, dut.add_r,
                     dut.pbuf[0][0], dut.pbuf[0][1], dut.pbuf[0][2], dut.pbuf[0][3],
                     dut.pbuf[1][0]);
        end
        if (dut.phase == PH_TREE && dut.t_lvl == 0 && dut.t_idx == 1)
            $display("  [tree lvl0 i1] prod[0..3]=%h %h %h %h", dut.prod[0], dut.prod[1], dut.prod[2], dut.prod[3]);
        if (dut.phase == PH_DONE && dut.done_step == 0)
            $display("  [done] dot_res=%h", dut.dot_res);
    end
endmodule
