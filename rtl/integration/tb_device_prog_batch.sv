// tb_device_prog_batch.sv — проверка батчевого GEMM (n_batch в uw[3][63:56]).
// Юнит: n_in=2, n_out=3, pass=1, src=data, n_batch=2, tag=0x33.
// Ожидаемая последовательность (B×n_out = 6 задач):
//   b0 n0: a=data_base,   w=W+0*nin*8, r=Y+(0*3+0)*8
//   b0 n1: a=data_base,   w=W+1*nin*8, r=Y+(0*3+1)*8
//   b0 n2: a=data_base,   w=W+2*nin*8, r=Y+(0*3+2)*8
//   b1 n0: a=data_base+2*8, w=W+0*nin*8, r=Y+(1*3+0)*8
//   b1 n1: a=data_base+2*8, w=W+1*nin*8, r=Y+(1*3+1)*8
//   b1 n2: a=data_base+2*8, w=W+2*nin*8, r=Y+(1*3+2)*8
module tb;
  logic clk = 0, rst_n = 0, en = 0, go = 0;
  logic [31:0] data_base = 32'h0000_0100, table_base = 0, mailbox_base = 0;
  logic [15:0] n_units = 1;
  logic desc_task_valid, table_req, done, mailbox_wr_start;
  logic [31:0] mailbox_wr_addr; logic [63:0] mailbox_wr_data;
  logic desc_task_ready = 1;
  logic [31:0] desc_task_a, desc_task_w, desc_task_r;
  logic [15:0] desc_task_n, desc_task_tag;
  logic table_rvalid = 0; logic [63:0] table_rdata = 0; logic [31:0] table_addr;

  device_prog #(.DEVPROG_EN(1), .NUM_MAC(32), .ADDR_WIDTH(32)) uut ( .* );

  always #5 clk = ~clk;

  // таблица: 1 юнит
  logic [63:0] u_tab[0:3];
  int serve = 0;
  localparam W = 32'h0000_1000;
  localparam Y = 32'h0000_2000;
  initial begin
    u_tab[0] = 64'(W);                          // w_addr
    u_tab[1] = 64'(Y);                          // out_addr
    u_tab[2] = ({16'd2, 48'd0});                // n_in=2 в [63:48], b_addr=0
    u_tab[3] = (64'd3) | (64'd1 << 16) | (64'h0 << 32) | (64'h33 << 40) | (64'd2 << 56); // n_out=3,pass=1,flags=0,tag=0x33,n_batch=2
  end
  always @(posedge clk) begin
    if (!rst_n) begin table_rvalid <= 0; serve <= 0; end
    else begin
      if (!en) serve <= 0;
      if (table_rvalid) begin table_rvalid <= 0; end
      if (table_req && !table_rvalid) begin table_rvalid <= 1'b1; table_rdata <= u_tab[serve]; end
      if (table_rvalid) serve <= serve + 1;
    end
  end

  // захват задач
  int ncap = 0, fail = 0;
  logic [31:0] cap_a[0:31], cap_w[0:31], cap_r[0:31];
  always @(posedge clk) begin
    if (desc_task_valid && desc_task_ready && ncap < 32) begin
      cap_a[ncap] <= desc_task_a; cap_w[ncap] <= desc_task_w; cap_r[ncap] <= desc_task_r;
      ncap <= ncap + 1;
    end
  end

  task chk(input string w, input bit ok); if (!ok) begin $display("FAIL: %s", w); fail = 1; end
    else $display("ok  : %s", w); endtask

  initial begin
    rst_n = 0; repeat (3) @(posedge clk); rst_n = 1; @(posedge clk);
    en = 1; go = 1; @(posedge clk); go = 0;
    wait (ncap >= 6); #20;
    chk("B0-N0 a=data_base", cap_a[0] == data_base);
    chk("B0-N0 w=W+0",      cap_w[0] == W);
    chk("B0-N0 r=Y+(0)",    cap_r[0] == Y);
    chk("B0-N1 w=W+1*2*8",  cap_w[1] == W + 1*2*8);
    chk("B0-N2 w=W+2*2*8",  cap_w[2] == W + 2*2*8);
    chk("B0-N2 r=Y+2*8",    cap_r[2] == Y + 2*8);
    chk("B1-N0 a=data_base+2*8", cap_a[3] == data_base + 2*8);
    chk("B1-N0 w=W+0",      cap_w[3] == W);
    chk("B1-N1 w=W+1*2*8",  cap_w[4] == W + 1*2*8);
    chk("B1-N0 r=Y+(1*3+0)*8", cap_r[3] == Y + (1*3+0)*8);
    chk("B1-N2 r=Y+(1*3+2)*8", cap_r[5] == Y + (1*3+2)*8);
    chk("кол-во задач = 6", ncap == 6);
    wait (done === 1'b1); #20; chk("done", 1);
    $display(fail ? "RESULT: FAIL" : "RESULT: PASS");
    $finish(fail ? 1 : 0);
  end
  initial begin #2_000_000; $display("TIMEOUT"); $finish(1); end
endmodule