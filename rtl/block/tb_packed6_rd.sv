// ============================================================================
// tb_packed6_rd.sv - UNIT-тест барреля packed6_rd (6->8) на ПУТЬ start_skip != 0
// ----------------------------------------------------------------------------
// Закрывает Gap-1: в интеграционных конфигурациях skip=(elems_done*6)%8 ВСЕГДА 0,
// т.к. core требует NUM_MAC=2^k и 6*2^k ≡ 0 mod 8 при k>=2. Этот tb пишет баррель
// НАПРЯМУЮ, питая упакованный байт-поток со ВСЕМИ start_skip ∈ {0,2,4,6} и
// нечётными/небольшими числами элементов, и сверяет выданные элементы с эталонной
// распаковкой elem_k = stream[skip+6k : skip+6k+6] (stream = байты всех элементов,
// первые `skip` байт — смещение 1-го элемента внутри 1-го 64-бит слова).
//
// Покрывает: арминг с nbytes=8-skip ∈ {8,6,4,2}; overlap-перечитывание слова на
// границе чанка (skip>0 => 1-е слово чанка перекрыто с хвостом прошлого прохода);
// хвостовое слово нечётного чанка (лишние байты отбрасываются); emit РОВНО n_elem.
//
// Файлы (cwd = rtl/block):
//   read  sim/packed6rd_in.hex    <word_addr> <64-бит value>
//   read  sim/packed6rd_tests.txt <id> <n_elem> <skip> <nwords> <word_addr>
//   write sim/packed6rd_out.hex   EMIT <id> <k> <value48> | DRAIN <id> <n_emitted>
// ============================================================================
module tb_packed6_rd;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic        enable, start, wvalid;
    logic [63:0] wdata;
    logic        wready;
    logic [15:0] n_elem;
    logic [2:0]  start_skip;
    logic [47:0] elem;
    logic        elem_valid;
    logic        drained;

    packed6_rd #(.BPE(6), .WORD_B(8)) u_bar (
        .clk(clk), .rst_n(rst_n),
        .enable(enable), .wdata(wdata), .wvalid(wvalid), .wready(wready),
        .n_elem(n_elem), .start_skip(start_skip), .start(start),
        .elem(elem), .elem_valid(elem_valid), .drained(drained)
    );

    logic [63:0] mem[0:65535];
    integer fi, fo, fi2;
    integer i;
    logic [31:0] wa;
    logic [63:0] wv;
    integer id, ne, sp, nw;
    logic [31:0] wbase;
    logic [47:0] emit_arr [0:4095];
    integer emit_cnt, wi, kk;

    initial begin
        enable = 0; start = 0; wvalid = 0; wdata = 64'h0;
        n_elem = 0; start_skip = 0;
        for (i = 0; i < 65536; i = i + 1) mem[i] = 64'h0;

        fi = $fopen("sim/packed6rd_in.hex", "r");
        if (fi == 0) begin $display("ERROR: no sim/packed6rd_in.hex"); $finish; end
        while (!$feof(fi)) begin
            if ($fscanf(fi, "%x %x\n", wa, wv) != 2) break;
            mem[wa & 31'hFFFF] = wv;
        end
        $fclose(fi);

        fi2 = $fopen("sim/packed6rd_tests.txt", "r");
        if (fi2 == 0) begin $display("ERROR: no sim/packed6rd_tests.txt"); $finish; end
        fo  = $fopen("sim/packed6rd_out.hex", "w");

        repeat (5) @(posedge clk);
        rst_n <= 1;
        repeat (5) @(posedge clk);

        while (!$feof(fi2)) begin
            if ($fscanf(fi2, "%d %d %d %d %x\n", id, ne, sp, nw, wbase) != 5) break;

            // ---- arm: перевооружить баррель на новое чтение ----
            n_elem     <= 16'(ne);
            start_skip <= 3'(sp);
            @(posedge clk);
            start <= 1; enable <= 1;
            @(posedge clk);          // barrel re-arms (sn deassert)
            start <= 0;
            @(posedge clk);          // start low; drive first word
            wvalid <= 1;
            wdata  <= mem[wbase & 31'hFFFF];
            emit_cnt = 0;
            wi = 0;                   // слов подано/поглощено

            while (wi < nw) begin
                @(posedge clk);
                if (elem_valid) begin
                    emit_arr[emit_cnt] = elem;
                    emit_cnt = emit_cnt + 1;
                end
                if (wready && wvalid) begin
                    wi = wi + 1;
                    if (wi < nw)
                        wdata <= mem[(wbase + wi) & 31'hFFFF];
                    else
                        wvalid <= 0;
                end
            end

            // ---- дождаться выдачи последнего элемента ----
            kk = 0;
            while (!(drained && emit_cnt >= ne)) begin
                @(posedge clk);
                if (elem_valid) begin
                    emit_arr[emit_cnt] = elem;
                    emit_cnt = emit_cnt + 1;
                end
                kk = kk + 1;
                if (kk > 20000) begin
                    $display("TB-P6RD TIMEOUT id=%0d drained=%b emit=%0d/%0d skip=%0d",
                             id, drained, emit_cnt, ne, sp);
                    $finish;
                end
            end
            enable <= 0;
            repeat (2) @(posedge clk);

            for (kk = 0; kk < emit_cnt; kk = kk + 1)
                $fdisplay(fo, "EMIT %0d %0d %012x", id, kk, emit_arr[kk]);
            $fdisplay(fo, "DRAIN %0d %0d", id, emit_cnt);
            $display("p6rd id=%0d ne=%0d skip=%0d nw=%0d emit=%0d", id, ne, sp, nw, emit_cnt);
        end

        $fclose(fi2);
        $fclose(fo);
        $display("=== p6rd DONE ===");
        $finish;
    end
endmodule