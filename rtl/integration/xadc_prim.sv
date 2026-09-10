// ============================================================================
// xadc_prim.sv — чтение температуры/VCCINT с примитива XADC через DRP
// ============================================================================
// BUG-031 fix (реальный, не заглушка): MIG 7-series сконфигурирован с
// XADC_En=Off (xdma_ddr3_dfx_bd.tcl), значит физический XADC на Artix-7
// СВОБОДЕН — можно инстанцировать примитив XADC напрямую в top-level.
//
// Функция: маленький DRP-FSM периодически (раз в 1 с) читает регистры:
//   DADDR 0x00 — температура (DO = 16-бит raw, формула Temp[°C] =
//                DO[15:4] * 503.975/4096 - 273.15)
//   DADDR 0x06 — VCCINT (DO[15:4] * 3.0/4096)
// После DRDY выставляет raw_valid=1 на один такт; xadc_temp.sv защёлкивает
// значения и отдаёт их хосту по AXI-Lite @ 0x46000000 (без изменения карты).
//
// DCLK = clk50 (50 МГц, в спецификации XADC 8..250 МГц), период опроса
// 1 с — XADC выдаёт ~50 kSPS максимум, 1 Гц более чем достаточно.
// ============================================================================
module xadc_prim (
    input  logic        clk,        // DCLK (clk50)
    input  logic        rst_n,
    output logic [15:0] raw_temp,   // защёлка температуры (XADC raw, 16 бит)
    output logic [15:0] raw_vccint, // защёлка VCCINT
    output logic        raw_valid   // стробирующий импульс: оба значения обновлены
);

    // ---- сигналы DRP (объявлены до инстанса примитива) ----
    logic [4:0] daddr;
    logic       den;
    logic [15:0] do_out;
    logic       drdy;

    // ---- XADC primitive (MIG XADC_En=Off, примитив один на кристалле) ----
    XADC #(
        .INIT_40(16'h9000),   // JTAG/DRP enabled, averaging disabled
        .INIT_41(16'h3100),   // temp averaging 0, autonormalize
        .INIT_42(16'h0400),   // VCCINT enabled
        .SIM_MONITOR_FILE("")
    ) u_xadc_prim (
        .CONVST     (1'b0),
        .CONVSTCLK  (1'b0),
        .DCLK       (clk),
        .DEN        (den),
        .DWE        (1'b0),
        .DRDY       (drdy),
        .DADDR      (daddr),
        .DO         (do_out),
        .EOC        (),
        .ALM        (),
        .BUSY       (),
        .JTAGBUSY   (),
        .JTAGLOCKED (),
        .MUXADDR    (5'd0),
        .OT         (),
        .RESET      (1'b0),
        .VAUXN      (16'h0),
        .VAUXP      (16'h0),
        .VN         (1'b0),
        .VP         (1'b0)
    );

    // ---- DRP-FSM: чтение двух каналов по кругу ----
    localparam int ST_IDLE      = 0;
    localparam int ST_RD_TEMP   = 1;
    localparam int ST_RD_VCC    = 2;

    logic [1:0] state;
    logic [15:0] temp_l, vcc_l;

    // таймер опроса ~1 с при 50 МГц (50e6 циклов): 26-бит счётчик
    logic [25:0] timer;
    logic        tick;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer <= 0;
            tick  <= 0;
        end else begin
            tick <= 0;
            if (timer >= 26'd50_000_000 - 26'd1) begin
                timer <= 0;
                tick  <= 1;
            end else begin
                timer <= timer + 26'd1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            daddr       <= 5'h0;
            den         <= 0;
            temp_l      <= 0;
            vcc_l       <= 0;
            raw_temp    <= 0;
            raw_vccint  <= 0;
            raw_valid   <= 0;
        end else begin
            den <= 0;
            raw_valid <= 0;
            case (state)
                ST_IDLE: begin
                    if (tick) begin
                        daddr <= 5'h00;      // температура
                        den   <= 1;
                        state <= ST_RD_TEMP;
                    end
                end
                ST_RD_TEMP: begin
                    if (drdy) begin
                        temp_l <= do_out;
                        daddr  <= 5'h06;     // VCCINT
                        den    <= 1;
                        state  <= ST_RD_VCC;
                    end
                end
                ST_RD_VCC: begin
                    if (drdy) begin
                        vcc_l <= do_out;
                        raw_temp   <= temp_l;
                        raw_vccint <= vcc_l;
                        raw_valid  <= 1;
                        state <= ST_IDLE;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule