// ============================================================================
// packed6_rd.sv - Barrel 6->8 для PACKED6: 64-бит слова AXI -> N элементов tf48
// ----------------------------------------------------------------------------
// PACKED6 (ELEM_FMT=2): элемент = 48 бит = 6 байт, элементы упакованы плотно
// (N элементов = N*6 байт), а AXI читает 64-битными словами (8 байт). Этот
// модуль «разжимает» 64-бит слова обратно в поток 48-бит элементов, выдавая
// РОВНО ОДИН элемент за такт (1 запись в BRAM-порт/такт - исключает
// dual-write, см. DESIGN C.3).
//
// Модель: буфер `sr[95:0]` держит до 12 байт необработанных данных
// (остаток предыдущего слова + текущее слово). Необработанные байты лежат в
// НИЗКИХ позициях sr (старшие - более новые). Элемент = низкие 6 байт sr
// (48 бит), извлекается сдвигом вправо на 48. Новое слово добавляется СВЕРХУ
// оставшихся байт: {word, sr[left*8-1:0]}.
//
// Распределение элементов по словам (При C.2, N_elem(hold)=floor((8+hold)/6)):
//   hold ∈ {0,2,4} -> слово даёт 1,1,2 элемента (ритм 1-1-2-1-1-2...).
// Ограничение: emit ТОЛЬКО когда (nbytes>=6) и (emitted<n_elem). Как только
// emitted достигает n_elem (все элементы этого чтения выданы), оставшиеся
// слова чанка ПРИНИМАЮТСЯ и ОТБРАСЫВАЮТСЯ (для нечётного чанка последнее
// слово частичное: n*6 % 8 != 0 -> лишние байты паддинга не эмитятся).
//
// Начальный сдвиг в 1-м слове: `start_skip` (0,2,4,6) - байтовое смещение
// первого элемента чанка внутри первого 64-бит слова (для прохода k>0
// elems_base*6 % 8). `start` перевооружает баррель на новое чтение.
//
// Выход `drained` = enable && (emitted>=n_elem): все элементы чтения выданы
// (используется контроллером ядра для гейта перехода между чтениями, чтобы
// последний элемент успел выйти до сброса).
// ============================================================================
module packed6_rd #(
    parameter int BPE    = 6,     // байт на элемент (tf48 = 6)
    parameter int WORD_B = 8      // байт в AXI-слове (64-бит = 8)
)(
    input  logic        clk,
    input  logic        rst_n,
    // ---- AXI read ----
    input  logic        enable,     // активна фаза чтения данных/весов
    input  logic [63:0] wdata,      // M_AXI_RDATA
    input  logic        wvalid,     // M_AXI_RVALID
    output logic        wready,     // M_AXI_RREADY-гейт (заявка слова)
    // ---- управление чтением ----
    input  logic [15:0] n_elem,     // сколько элементов выдать за это чтение
    input  logic [2:0]  start_skip, // 0,2,4,6 (см. шапку)
    input  logic        start,      // перевооружить на новое чтение (импульс)
    // ---- FIFO ----
    output logic [47:0] elem,       // 48-бит tf48 элемент
    output logic        elem_valid, // 1 элемент за такт -> fifo_push
    output logic        drained     // enable && (emitted >= n_elem)
);

    localparam int SW = BPE * 8;     // 48 bit

    logic [95:0] sr;
    logic [3:0]  nbytes;             // 0..12
    logic [15:0] emitted;
    logic        armed;              // следующее слово - первое (применить start_skip)
    logic [2:0]  skip_q;

    // может ли выдать элемент В ЭТОМ такте (комбинационно)
    // `start` (перевооружение) гасит выдачу/приём на этот такт: при re-arm
    // баррель обнуляет nbytes/emitted на фоне, а комбинационные выходы с
    // устаревшими регистрами не должны протолкнуть лишний элемент/заявку слова.
    wire emit_can = (nbytes >= BPE) && (emitted < n_elem);
    wire emit_ok  = enable && !start && emit_can;
    assign wready     = enable && !start && !emit_can;
    assign drained    = enable && (emitted >= n_elem);
    assign elem_valid = emit_ok;
    assign elem       = emit_ok ? sr[ 6'd47 : 0 ] : 48'h0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr      <= 96'h0;
            nbytes  <= 4'h0;
            emitted <= 16'h0;
            armed   <= 1'b0;
            skip_q  <= 3'h0;
        end else if (start) begin
            // перевооружение на новое чтение: сброс остатка, кармана, счётчика
            skip_q  <= start_skip;
            armed   <= 1'b1;
            emitted <= 16'h0;
            nbytes  <= 4'h0;
            // sr не важен (nbytes=0)
        end else if (enable) begin
            if (emit_ok) begin
                // 1 элемент/такт: выдать низкие 6 байт, сдвинуть
                emitted <= emitted + 16'h1;
                sr      <= sr >> SW;
                nbytes  <= nbytes - BPE;
            end else if (wvalid && wready) begin
                if (emitted >= n_elem) begin
                    // все элементы выданы: принимаем хвост чанка и отбрасываем
                    // (nbytes/sr не трогаем, чистое поглощение слов)
                    ;
                end else if (armed) begin
                    // первое слово: отбросить низкие start_skip байт
                    // (wdata >> 8*skip: байты skip..7 ложатся в низ sr, верх нули)
                    sr     <= { 32'h0, wdata >> (start_skip * 8) };
                    nbytes <= WORD_B - start_skip;
                    armed  <= 1'b0;
                end else begin
                    // последующие слова: {wdata, sr[left*8-1:0]}
                    unique case (nbytes)
                        4'h0: begin
                            sr     <= { 32'h0, wdata };
                            nbytes <= WORD_B;
                        end
                        4'h2: begin
                            sr     <= { 16'h0, wdata, sr[15:0] };
                            nbytes <= WORD_B + 2;
                        end
                        4'h4: begin
                            sr     <= { wdata, sr[31:0] };
                            nbytes <= WORD_B + 4;
                        end
                        default: begin   // defensive
                            sr     <= { 32'h0, wdata };
                            nbytes <= WORD_B;
                        end
                    endcase
                end
            end
        end
    end

endmodule