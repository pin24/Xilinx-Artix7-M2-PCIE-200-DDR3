// ============================================================================
// tb_tbyte_add_dbg.sv - отладка add на входе e7 ee 01
// ============================================================================
module tb_tbyte_add_dbg;
    logic [7:0] a = 8'he7, b = 8'hee, sum;
    logic [1:0] cin = 2'b01, cout;

    tbyte_add dut (.a(a), .b(b), .cin(cin), .sum(sum), .cout(cout));

    initial begin
        #1;
        $display("a=%h b=%h cin=%b", a, b, cin);
        $display("at=%b%b%b%b", dut.at[3], dut.at[2], dut.at[1], dut.at[0]);
        $display("bt=%b%b%b%b", dut.bt[3], dut.bt[2], dut.bt[1], dut.bt[0]);
        $display("carry=%b%b%b%b%b", dut.carry[4], dut.carry[3], dut.carry[2], dut.carry[1], dut.carry[0]);
        $display("sum=%h cout=%b", sum, cout);
        $finish;
    end
endmodule
