// tb_device_prog.sv — проверка BUG-085 фикса: (1) нормальное завершение пишет
// mailbox статуса=0 + done; (2) снятие en (abort) возвращает в IDLE и гасит
// все выходные импульсы (desc_task_valid/table_req/mailbox_wr_start/done),
// чтобы остаток программы не вклинился в следующий батч; (3) после abort
// можно запустить новую программу штатно.
module tb;
  logic clk = 0, rst_n = 0, en = 0, go = 0;
  logic [31:0] data_base = 0;
  logic [31:0] table_base = 0;
  logic [31:0] mailbox_base = 0;
  logic [15:0] n_units = 1;

  logic        desc_task_valid = 0;
  logic [31:0] desc_task_a, desc_task_w, desc_task_r;
  logic [15:0] desc_task_n, desc_task_tag;
  logic        table_req = 0;
  logic [31:0] table_addr;
  logic        table_rvalid = 0;
  logic [63:0] table_rdata = 0;
  logic        desc_task_ready = 1;
  logic        done = 0;
  logic        mailbox_wr_start = 0;
  logic [31:0] mailbox_wr_addr;
  logic [63:0] mailbox_wr_data;

  device_prog #(.DEVPROG_EN(1), .NUM_MAC(32), .ADDR_WIDTH(32),
                .TABLE_BASE(32'h0), .MAILBOX_BASE(32'h0))
  uut ( .* );

  always #5 clk = ~clk;

  // ---- простая таблица на 1 юнит: n_out=1, pass=1, n_in=1 ----
  logic [63:0] u_tab[0:3];
  int serve = 0;
  initial begin
    u_tab[0] = 64'h0;                       // w_addr
    u_tab[1] = 64'h0;                       // out_addr
    u_tab[2] = 64'd1 << 48;                 // n_in=1 (bits 63:48), b_addr=0
    u_tab[3] = 64'h0000_0000_0001_0001;     // pass=1 (31:16), n_out=1 (15:0)
  end
  always @(posedge clk) begin
    if (!rst_n) begin table_rvalid <= 0; serve <= 0; end
    else begin
      if (!en) serve <= 0;                 // сброс указателя таблицы при abort
      if (table_rvalid) begin table_rvalid <= 0; end
      if (table_req && !table_rvalid) begin
        table_rvalid <= 1'b1;
        table_rdata  <= u_tab[serve];
      end
      if (table_rvalid) serve <= serve + 1;
    end
  end

  // ---- сбор mailbox для проверки статуса ----
  logic [63:0] mbox_data[0:1];
  logic [31:0] mbox_addr[0:1];
  int mc = 0;
  always @(posedge clk) begin
    if (mailbox_wr_start && mc < 2) begin
      mbox_addr[mc] <= mailbox_wr_addr;
      mbox_data[mc] <= mailbox_wr_data;
      mc <= mc + 1;
    end
  end

  int fail = 0;
  task check(input string what, input bit ok);
    if (!ok) begin $display("FAIL: %s", what); fail = 1; end
    else      $display("ok  : %s", what);
  endtask

  // ---- стимулы ----
  initial begin
    // сброс
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ===== ТЕСТ 1: нормальный запуск =====
    en = 1;
    go = 1;
    @(posedge clk);
    go = 0;
    // дождаться задачи
    wait (desc_task_valid === 1'b1);
    // дождаться done
    wait (done === 1'b1);
    #20;
    check("T1 нормальный: задача выдана", 1);
    check("T1 нормальный: mailbox записан (mc>0)", mc >= 2);
    // статус W1 (addr=+8): {40'h0, units, status=0} -> status=0
    if (mc >= 2) begin
      bit found = 0;
      for (int i = 0; i < 2; i++) begin
        if (mbox_addr[i] == 32'h8) begin
          check("T1 нормальный: status==0", (mbox_data[i][7:0] == 8'd0));
          found = 1;
        end
      end
      if (!found) check("T1 найден W1 (addr+8)", 0);
    end
    #30;
    // сброс теста-флага доне
    @(posedge clk);

    // ===== ТЕСТ 2: abort снятием en в середине исполнения =====
    en = 0;
    repeat (3) @(posedge clk);   // стабилизировать idle
    en = 1;
    go = 1;
    @(posedge clk);
    go = 0;
    // дождаться, пока device_prog выставит задачу (середина программы)
    wait (desc_task_valid === 1'b1);
    repeat (2) @(posedge clk);
    // АВАРИЙНОЕ снятие en (abort)
    en = 0;
    repeat (4) @(posedge clk);
    check("T2 abort: desc_task_valid сброшен", desc_task_valid === 1'b0);
    check("T2 abort: table_req сброшен", table_req === 1'b0);
    check("T2 abort: mailbox_wr_start сброшен", mailbox_wr_start === 1'b0);
    check("T2 abort: done не зажигается", done === 1'b0);
    // после abort не должно быть новых mailbox-импульсов
    begin
      int mc_before = mc;
      repeat (20) @(posedge clk);
      check("T2 abort: mailbox не пишется после снятия en", mc == mc_before);
    end
    // стабилизировать
    en = 1;
    repeat (6) @(posedge clk);

    // ===== ТЕСТ 3: после abort можно запустить новую программу =====
    go = 1;
    @(posedge clk);
    go = 0;
    wait (desc_task_valid === 1'b1);
    wait (done === 1'b1);
    #20;
    check("T3 повторный запуск после abort: done", 1);

    // ===== сброс/вывод =====
    en = 0;
    repeat (3) @(posedge clk);
    $display(fail ? "RESULT: FAIL" : "RESULT: PASS");
    $finish(fail ? 1 : 0);
  end

  // таймаут всей симуляции
  initial begin
    #2_000_000;
    $display("TIMEOUT всеобщий");
    $finish(1);
  end
endmodule