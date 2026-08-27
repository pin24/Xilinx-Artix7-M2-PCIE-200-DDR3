// ============================================================================
// tb_compute_core.sv - сквозной тестбенч compute_core (N=4)
// Вход: 4 x f32 (data) + 4 x f32 (weights), выход: f32 dot
// Ожидаем valid_out=1 для чтения результата (правильная синхронизация).
// ============================================================================
module tb_compute_core;
    localparam int N = 4;
    logic clk = 0, rst_n = 0;
    logic [32*N-1:0] data_in, weights;
    logic valid_in = 0;
    logic [31:0] result_out;
    logic valid_out, err_out;

    int fd_in, fd_out, status, r;
    logic [31:0] din [0:2*N-1];

    compute_core #(.N(N)) dut (
        .clk(clk), .rst_n(rst_n),
        .data_in(data_in), .weights(weights), .valid_in(valid_in),
        .result_out(result_out), .valid_out(valid_out), .err_out(err_out)
    );

    always #5 clk = ~clk;

    task wait_valid();
        begin
            wait (valid_out == 1);
            $fwrite(fd_out, "%h\n", result_out);
        end
    endtask

    initial begin
        fd_in = $fopen("sim/cc_in.hex", "r");
        fd_out = $fopen("sim/cc_out.hex", "w");
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
            @(posedge clk);      // стабилизация комбинационной логики
            valid_in = 1;
            @(posedge clk);      // захват результата в регистр
            valid_in = 0;
            wait_valid();        // ждём результат (valid_out=1)
            r = r + 1;
        end
    end
endmodule
