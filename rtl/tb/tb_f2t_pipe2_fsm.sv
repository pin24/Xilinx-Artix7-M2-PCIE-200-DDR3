// ============================================================================
// tb_f2t_pipe2_fsm.sv - F2T с FSM-подачей (неблокирующей), как в compute_core
// ============================================================================
module tb_f2t_pipe2_fsm;
    logic clk=0, rst_n=0;
    logic s_valid;
    logic [31:0] s_data;
    logic [39:0] m_data;
    logic m_valid;
    int cnt;

    f32_to_tf40_pipe2 dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_valid), .s_axis_tdata(s_data),
        .m_axis_tvalid(m_valid), .m_axis_tdata(m_data)
    );

    logic [31:0] din [0:31];
    int fd, status;
    int cv_i;   // счётчик подачи (неблокирующий, как в compute_core)
    logic [31:0] din_reg;  // неблокирующий вход
    logic valid_reg;

    always #5 clk = ~clk;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cv_i <= 0;
            valid_reg <= 0;
            din_reg <= 0;
        end else begin
            // как PH_IDLE + PH_CONV в compute_core
            if (cv_i == 0) begin
                valid_reg <= 1;
                din_reg <= din[0];
                cv_i <= 1;
            end else if (cv_i < 32) begin
                valid_reg <= 1;
                din_reg <= din[cv_i];
                cv_i <= cv_i + 1;
            end else begin
                valid_reg <= 0;
            end
        end
    end
    assign s_valid = valid_reg;
    assign s_data = din_reg;

    initial begin
        fd = $fopen("sim/ccdp_in.hex", "r");
        for (int i = 0; i < 32; i++)
            status = $fscanf(fd, "%h", din[i]);
        $fclose(fd);
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        cnt = 0;
        for (int t = 0; t < 300; t++) begin
            @(posedge clk);
            if (m_valid) begin
                if (cnt >= 27)
                    $display("OUT[%0d]: %h", cnt, m_data);
                cnt = cnt + 1;
            end
        end
        $display("всего: %0d", cnt);
        $finish;
    end
endmodule
