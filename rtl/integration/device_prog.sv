// ============================================================================
// device_prog.sv - интерпретатор «программы юнитов» поверх ring tdot
// ============================================================================
// ИДЕЯ (docs/device-prog-2026-10-20.md): host шлёт ОДНУ программу (список слоёв-
// юнитов в DDR), устройство САМО разворачивает её в последовательность dot-задач
// для кольца tdot и пишет completion-mailbox (статус 16 Б в DRAM). Это снимает
// стоимость ~15 мс/задачу host-IOCTL (BUG-071): хост вмешивается только на
// границе батча.
//
// ВАЖНО: модуль САМОДОСТАТОЧЕН и НЕ связан с tdot_axi4. Он выдаёт «намерения»
// (desc_task_*) — какие dot-задачи (data/weights/result/n_total/tag) должны быть
// поставлены в кольцо. Интеграция (передача desc_task_* в планировщик tdot,
// пересылка desc_task_* по AXI) — ОТДЕЛЬНЫЙ шаг. Он также НЕ читает DDR сам:
// юниты подаются через интерфейс чтения таблицы (table_req/table_rvalid/rdata) —
// на интеграции за ним будет DMA/AXI-чтение, здесь (TB) — синхронная память.
//
// DEVPROG_EN=0 (по умолчанию): модуль ПУСТ — все выходы 0, никакой FSM, никаких
// предупреждений о неиспользуемой логике. Не меняет поведение без параметра.
//
// Таблица юнитов в «DDR» (table_base, 32 Б/юнит = 4 слова по 64 бит):
//   +0x00 W0   w_addr[63:0]     базовый адрес весов слоя (полный AXI)
//   +0x08 W1   out_addr[63:0]   базовый адрес результата слоя
//   +0x10 W2   {n_in[15:0], b_addr[47:0]}   кол-во входов, базовый адрес смещения
//   +0x18 W3   bit[15:0]   n_out        кол-во выходных нейронов
//              bit[31:16]  pass         число проходов слоя (>=1; feed-forward:
//                                       после прохода 0 входом становится out_addr)
//              bit[39:32]  flags: bit0=relu, bit1=b_en, bit2=src(0=data,1=prev)
//              bit[55:40]  tag           тег юнита (передаётся в dot-задачу)
//              bit[63:56]  reserved (0)
//
// Интерпретация (вложенность циклов <= 4):
//   L1 программа = список юнитов u in [0, n_units)
//   L2 проход    = for k in [0, pass):   вход = (k==0 ? src_base : out_addr)
//   L3 нейрон    = for j in [0, n_out):  один dot-задача GEMM(input, w_col_j) -> out[j]
//   (L4 зарезервирован под батч/внешний LOOP на интеграции)
// src=data  -> вход = data_base (буфер батча);  src=prev -> вход = out_addr
// предыдущего юнита. w_col_j = w_addr + j*n_in*ELEM_BYTES; out[j] = out_addr + j*ELEM_BYTES.
// Для слоя с pass>1: проход 0 считает вход по src, проходы k>0 гонят out_addr
// (собственный выход слоя) обратно на вход — «feed-forward» повторы.
//
// Завершение: mailbox-статус 16 Б (2 слова по 64 бит) по mailbox_base:
//   W0 = {48'h0, tag[15:0]}          tag последнего юнита как tag программы
//   W1 = {40'h0, units_done[15:0], status[7:0]}    status: 0 = OK
// (units_done в [23:8], status в [7:0]; формат близок к completion tdot, где
// tag/status в младших полях). mailbox_wr_start пульсирует по слову;
// addr = base / base+8. Транзакцию AXI выполняет интеграция.
// ============================================================================
module device_prog #(
    parameter bit                             DEVPROG_EN   = 0,
    parameter int                             NUM_MAC      = 32,
    parameter int                             ADDR_WIDTH   = 32,
    parameter logic [ADDR_WIDTH-1:0]          TABLE_BASE   = 32'h8001_0000,
    parameter logic [ADDR_WIDTH-1:0]          MAILBOX_BASE = 32'h8002_0000,
    parameter int                             UNIT_BYTES   = 32,
    parameter int                             ELEM_BYTES   = 8
)(
    input  logic                             clk,
    input  logic                             rst_n,
    input  logic                             en,
    input  logic                             go,
    input  logic [ADDR_WIDTH-1:0]            data_base,
    input  logic [ADDR_WIDTH-1:0]            table_base,
    input  logic [ADDR_WIDTH-1:0]            mailbox_base,
    input  logic [15:0]                      n_units,
    output logic                             desc_task_valid,
    output logic [ADDR_WIDTH-1:0]            desc_task_a,
    output logic [ADDR_WIDTH-1:0]            desc_task_w,
    output logic [ADDR_WIDTH-1:0]            desc_task_r,
    output logic [15:0]                      desc_task_n,
    output logic [15:0]                      desc_task_tag,
    output logic                             table_req,
    output logic [ADDR_WIDTH-1:0]            table_addr,
    input  logic                             table_rvalid,
    input  logic [63:0]                      table_rdata,
    output logic                             done,
    output logic                             mailbox_wr_start,
    output logic [ADDR_WIDTH-1:0]            mailbox_wr_addr,
    output logic [63:0]                      mailbox_wr_data
);

    generate
    if (DEVPROG_EN) begin : gen_devprog
        localparam int AW   = ADDR_WIDTH;
        localparam logic [2:0] ST_IDLE   = 3'd0;
        localparam logic [2:0] ST_FETCH  = 3'd1;
        localparam logic [2:0] ST_EXEC   = 3'd2;
        localparam logic [2:0] ST_DECODE = 3'd3;
        localparam logic [2:0] ST_MBOX0  = 3'd4;
        localparam logic [2:0] ST_MBOX1  = 3'd5;
        localparam logic [2:0] ST_DONE   = 3'd6;

        // ---- ширина арифметики задачи (32-битная; расширение {16'd0,..}) ----
        localparam int WOFF_BITS = (ADDR_WIDTH > 32) ? ADDR_WIDTH : 32;

        logic [2:0]  state;
        logic [15:0] u_idx;
        logic [1:0]  fetch_cnt;
        logic        fetch_pend;
        logic [15:0] pass_cnt;
        logic [15:0] neuron_cnt;

        logic [63:0] uw [0:3];
        logic [47:0] cur_w_addr, cur_out_addr, cur_b_addr;
        logic [15:0] cur_n_in, cur_n_out, cur_pass, cur_tag;
        logic        cur_relu, cur_b_en, cur_src;

        logic [AW-1:0] input_base;
        logic [AW-1:0] prev_out;
        logic [15:0]   last_tag;

        // ---- комбинационные смещения заданий ----
        logic [WOFF_BITS-1:0] off_w;    // neuron * n_in * ELEM_BYTES
        logic [WOFF_BITS-1:0] off_r;    // neuron * ELEM_BYTES
        logic [AW-1:0]        task_w;
        logic [AW-1:0]        task_r;
        logic [AW-1:0]        fetch_addr;

        always_comb begin
            off_w = ({16'd0, neuron_cnt} * {16'd0, cur_n_in}) * ELEM_BYTES;
            off_r = {16'd0, neuron_cnt} * ELEM_BYTES;
            task_w = cur_w_addr[AW-1:0] + off_w[AW-1:0];
            task_r = cur_out_addr[AW-1:0] + off_r[AW-1:0];
            fetch_addr = table_base
                         + ({16'd0, u_idx} * 32'd32)
                         + ({16'd0, fetch_cnt} * 32'd8);
        end

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                state            <= ST_IDLE;
                u_idx            <= '0;
                fetch_cnt        <= '0;
                fetch_pend       <= 1'b0;
                pass_cnt         <= '0;
                neuron_cnt       <= '0;
                prev_out         <= '0;
                input_base       <= '0;
                last_tag         <= '0;
                cur_w_addr       <= '0;
                cur_out_addr     <= '0;
                cur_b_addr       <= '0;
                cur_n_in         <= '0;
                cur_n_out        <= '0;
                cur_pass         <= '0;
                cur_tag          <= '0;
                cur_relu         <= '0;
                cur_b_en         <= '0;
                cur_src          <= '0;
                uw[0]            <= 64'h0;
                uw[1]            <= 64'h0;
                uw[2]            <= 64'h0;
                uw[3]            <= 64'h0;
                desc_task_valid  <= 1'b0;
                desc_task_a      <= '0;
                desc_task_w      <= '0;
                desc_task_r      <= '0;
                desc_task_n      <= '0;
                desc_task_tag    <= '0;
                table_req        <= 1'b0;
                table_addr       <= '0;
                done             <= 1'b0;
                mailbox_wr_start <= 1'b0;
                mailbox_wr_addr  <= '0;
                mailbox_wr_data  <= '0;
            end else begin
                // по умолчанию гасим одиночные импульсы
                desc_task_valid  <= 1'b0;
                table_req        <= 1'b0;
                mailbox_wr_start <= 1'b0;
                done             <= 1'b0;

                case (state)
                    ST_IDLE: begin
                        if (en && go) begin
                            // только сброс индексов/указателей; ПЕРВЫЙ запрос таблицы
                            // выдается в ST_FETCH из уже обнулённых u_idx/fetch_cnt,
                            // чтобы fetch_addr считался по старту (корректно и на
                            // повторном go после ST_DONE, см. аудit#1).
                            u_idx      <= '0;
                            fetch_cnt  <= '0;
                            fetch_pend <= 1'b0;
                            prev_out   <= '0;
                            state      <= ST_FETCH;
                        end
                    end

                    ST_FETCH: begin
                        if (!fetch_pend) begin
                            // выдача запроса очередного слова юнита
                            table_addr <= fetch_addr;
                            table_req  <= 1'b1;
                            fetch_pend <= 1'b1;
                        end else if (table_rvalid) begin
                            // слово вернулось
                            uw[fetch_cnt] <= table_rdata;
                            fetch_pend    <= 1'b0;
                            table_req     <= 1'b0;
                            if (fetch_cnt == 2'd3) begin
                                // все 4 слова юнита собраны -> ST_DECODE
                                // (uw[3] только что записан; декодим в отдельном
                                // состоянии, чтобы не читать устаревшее значение)
                                state <= ST_DECODE;
                            end else begin
                                fetch_cnt  <= fetch_cnt + 1;
                            end
                        end
                        // иначе (fetch_pend=1, rvalid=0): ждём слово
                    end

                    ST_DECODE: begin
                        // ---- декодируем юнит (uw[] уже стабильны) ----
                        cur_w_addr   <= uw[0][47:0];
                        cur_out_addr <= uw[1][47:0];
                        cur_b_addr   <= uw[2][47:0];
                        cur_n_in     <= uw[2][63:48];
                        cur_n_out    <= uw[3][15:0];
                        cur_pass     <= (uw[3][31:16] == 16'd0) ? 16'd1 : uw[3][31:16];
                        cur_relu     <= uw[3][32];
                        cur_b_en     <= uw[3][33];
                        cur_src      <= uw[3][34];
                        cur_tag      <= uw[3][55:40];
                        pass_cnt     <= 16'd0;
                        neuron_cnt   <= 16'd0;
                        // вход прохода 0: src=data -> data_base, src=prev -> prev_out
                        input_base   <= uw[3][34] ? prev_out : data_base;
                        state        <= ST_EXEC;
                    end

                    ST_EXEC: begin
                        // одна задача GEMM на нейрон (без backpressure: интеграция
                        // ставит FIFO/руку; здесь — ровно 1 задача/такт)
                        desc_task_valid <= 1'b1;
                        desc_task_a     <= input_base;
                        desc_task_w     <= task_w;
                        desc_task_r     <= task_r;
                        desc_task_n     <= cur_n_in;
                        desc_task_tag   <= cur_tag;

                        if (neuron_cnt == (cur_n_out - 16'd1)) begin
                            neuron_cnt <= 16'd0;
                            if (pass_cnt == (cur_pass - 16'd1)) begin
                                // ---- юнит завершён ----
                                last_tag  <= cur_tag;
                                prev_out  <= cur_out_addr[AW-1:0];
                                pass_cnt  <= 16'd0;
                                if (u_idx == (n_units - 16'd1)) begin
                                    // программа закончилась -> mailbox (слово 0)
                                    mailbox_wr_addr  <= mailbox_base;
                                    mailbox_wr_data  <= {48'h0, 16'(cur_tag)};
                                    mailbox_wr_start <= 1'b1;
                                    state <= ST_MBOX1;
                                end else begin
                                    u_idx     <= u_idx + 16'd1;
                                    fetch_cnt <= 2'd0;
                                    state     <= ST_FETCH;
                                end
                            end else begin
                                // следующий проход: feed-forward (вход = собственный выход)
                                pass_cnt   <= pass_cnt + 16'd1;
                                input_base <= cur_out_addr[AW-1:0];
                            end
                        end else begin
                            neuron_cnt <= neuron_cnt + 16'd1;
                        end
                    end

                    ST_MBOX1: begin
                        // второе слово статуса 16 Б: {res40, units[23:8], status[7:0]}
                        mailbox_wr_addr  <= mailbox_base + 32'd8;
                        mailbox_wr_data  <= {40'h0, 16'(n_units), 8'd0};
                        mailbox_wr_start <= 1'b1;
                        state <= ST_DONE;
                    end

                    ST_DONE: begin
                        done <= 1'b1;
                        if (!go) state <= ST_IDLE;
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end

    end else begin : gen_idle
        assign desc_task_valid  = 1'b0;
        assign desc_task_a      = '0;
        assign desc_task_w      = '0;
        assign desc_task_r      = '0;
        assign desc_task_n      = '0;
        assign desc_task_tag    = '0;
        assign table_req        = 1'b0;
        assign table_addr       = '0;
        assign done             = 1'b0;
        assign mailbox_wr_start = 1'b0;
        assign mailbox_wr_addr  = '0;
        assign mailbox_wr_data  = '0;
    end
    endgenerate

endmodule