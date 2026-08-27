// ============================================================================
// tb_expval.sv - проверка exp_val и e-инициализации
// ============================================================================
module tb_expval;
    logic clk = 0, rst_n = 1;
    logic [47:0] a = 48'h0622662015a9;
    logic [47:0] b = 48'h01859864252a;
    logic [7:0] a_e, b_e;
    logic signed [7:0] ea, eb;
    logic signed [7:0] e_init;

    assign a_e = a[47:40];
    assign b_e = b[47:40];

    tfmac dut (
        .clk(clk), .rst_n(rst_n),
        .valid_in(1'b0), .op(1'b0), .a(a), .b(b),
        .valid_out(), .result()
    );

    initial begin
        #1;
        ea = dut.exp_val(a_e);
        eb = dut.exp_val(b_e);
        e_init = ea + eb - 8'sd18;
        $display("a_e=%h b_e=%h ea=%0d eb=%0d e_init=%0d", a_e, b_e, ea, eb, e_init);
        $finish;
    end
endmodule
