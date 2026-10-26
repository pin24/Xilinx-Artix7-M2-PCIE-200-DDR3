// ============================================================================
// tb_tdot_dot_hang.sv — изолированный стенд для детерминированного
// воспроизведения зависания Tdot на РЕАЛЬНЫХ TFloat48-значениях из весов модели.
// (глобальный `timescale 1ns/1ps задаётся файлом rtl/timescale.sv — первой
//  единицей компиляции; здесь директива не дублируется)
//
// Запуск (Vivado 2025.2 XSim, из корня проекта):
//   python rtl\run_sim_tdot.py            # собирает и гоняет XSim
//   (эквивалент вручную: xvlog -sv timescale.sv compute_dot_par_raw.sv
//                        tfmul_raw.sv tbyte_mul.sv tfadd_raw.sv tfadd48.sv
//                        tb_tdot_dot_hang.sv
//                       xelab tb_tdot_dot_hang -debug typical
//                       xsim tb_tdot_dot_hang -runall)
//
// Нужные файлы (генерятся make_tdot_vectors.py):
//   vectors.dat / weights.dat — пары TFloat48 (48 бит на слово, hex, 12 симв.,
//   старший бит первый: [47:0] = {e[7:0], m[39:0]}), по NUM_MAC слов на вектор.
//
// Что делает: прогоняет N_VECT векторов; для каждого (по желанию параметра)
// — одиночный dot через compute_dot_par_raw и/или длинный dot с аккумуляцией
// через tfadd48 по нескольким подряд.result_out реальных результатов. На каждый
// valid_in ставится watchdog: если valid_out/add_valid_w не пришёл за WATCHDOG
// тактов — печатает HANG с номером вектора и внутренними пробниками дерева
// (`ifdef PROBE_TREE) и завершает с ошибкой. В конце PASS/FAIL.
// ============================================================================
`include "sim_cfg.svh"   // генерирует run_sim_tdot.py: `define SIM_NUM_MAC/ADDERS/PROBE_TREE

module tb_tdot_dot_hang;
  parameter int NUM_MAC = `SIM_NUM_MAC;
  parameter int ADDERS  = `SIM_ADDERS;
  parameter int N_VECT    = 4000;    // сколько векторов прогнать
  parameter int   LONG_DOT  = 1;       // 1 = ещё и длинный dot (аккум. tfadd48)
  parameter longint WATCHDOG = 300000; // тактов ожидания результата после kick

  logic clk = 0, rst_n = 0;
  logic [48*NUM_MAC-1:0] data_in, weights;
  logic valid_in = 0, valid_out;
  logic [47:0] result_out;

  wire [47:0] acc_a  = result_out;     // накопитель берёт результат очередного dot-этапа
  logic       acc_start = 0;
  logic [47:0] acc_b;
  logic [47:0] acc_out;
  logic        acc_valid;

  compute_dot_par_raw #(.NUM_MAC(NUM_MAC), .ADDERS(ADDERS)) u_core (
    .clk(clk), .rst_n(rst_n), .data_in(data_in), .weights(weights),
    .valid_in(valid_in), .result_out(result_out), .valid_out(valid_out));

  tfadd48 u_acc (
    .clk(clk), .rst_n(rst_n),
    .a(acc_a), .b(acc_b), .valid_in(acc_start), .result(acc_out), .valid_out(acc_valid));

`ifdef PROBE_TREE
  wire [7:0]  t_lvl     = u_core.t_lvl;
  wire [7:0]  t_cnt     = u_core.t_cnt;
  wire [7:0]  collected = u_core.collected;
  wire [7:0]  rnd_issue = u_core.rnd_issue;
  wire        tree_can  = u_core.tree_can_issue;
`endif

  // --- память векторов ---
  reg [48*NUM_MAC-1:0] VM [0:100000];
  reg [48*NUM_MAC-1:0] WM [0:100000];
  integer n_loaded;

  always #5 clk = ~clk;

  integer fd, i;
  initial begin
    $readmemh("vectors.dat", VM, 0, 100000);
    $readmemh("weights.dat",  WM, 0, 100000);
    n_loaded = 0;
    for (i = 0; i < 100000; i = i + 1)
      if (VM[i] === 'x) break;
    n_loaded = i;
    $display("loaded vectors = %0d (NUM_MAC=%0d, ADDERS=%0d, LONG_DOT=%0d)",
             n_loaded, NUM_MAC, ADDERS, LONG_DOT);
    if (n_loaded == 0) begin
      $display("FAIL: vectors.dat/weights.dat пусты — сначала сгенерируй их");
      $finish;
    end
  end

  // --- FSM: 0=IDLE, 1=RUN_DOT, 2=WAIT_ACC ---
  int state = 0;
  int idx = 0;                 // текущий обрабатываемый вектор
  int done = 0;                // сколько векторов завершено
  longint t0 = 0;

  function void report_hang(string tag, integer vidx);
    $display(">>> HANG [%0t] %s: вектор #%0d, результат не пришёл за %0d тактов",
             $time, tag, vidx, WATCHDOG);
`ifdef PROBE_TREE
    $display("    probe: t_lvl=%0d t_cnt=%0d collected=%0d rnd_issue=%0d tree_can=%0d",
             t_lvl, t_cnt, collected, rnd_issue, tree_can);
`endif
    $fatal(1);
  endfunction

  always @(posedge clk) begin
    if (!rst_n) begin
      state <= 0; valid_in <= 0; acc_start <= 0; idx <= 0; done <= 0;
    end else begin
      valid_in  <= 0;
      acc_start <= 0;
      case (state)
        0: begin // IDLE: подать следующий вектор
          if (idx < N_VECT && idx < n_loaded) begin
            data_in <= VM[idx];
            weights <= WM[idx];
            valid_in <= 1;
            t0 <= $time;
            state <= 1;
          end else begin
            // конец — финальный отчёт
            if (done > 0) $display("PASS: %0d векторов без зависаний", done);
            else          $display("PASS: (не прогнано)");
            $finish;
          end
        end
        1: begin // RUN_DOT: ждать valid_out
          if (valid_out) begin
            // результат dot пришёл
            if (LONG_DOT) begin
              // длинный dot: накопить следующий этап в tfadd48 (аккум по умолчанию 0)
              acc_b  <= acc_out;       // накопление (на первом этапе acc_out=0)
              acc_start <= 1;
              state <= 2;
            end else begin
              done <= done + 1;
              idx  <= idx + 1;
              state <= 0;
            end
          end else if (($time - t0) > WATCHDOG) begin
            report_hang("одиночный dot", idx);
          end
        end
        2: begin // WAIT_ACC: ждать valid аккумулятора (длинный dot)
          if (acc_valid) begin
            done <= done + 1;
            idx  <= idx + 1;
            state <= 0;
          end else if (($time - t0) > WATCHDOG) begin
            report_hang("аккумулятор tfadd48", idx);
          end
        end
      endcase
    end
  end

  integer k;
  initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1;
    repeat (4) @(posedge clk);
    // страховка от полного зависания FSM: если упёрлись в 0 без прогресса,
    // основная машина сама выйдет по idx>=N_VECT. Ничего дополнительно не нужно.
    #1;
  end

endmodule