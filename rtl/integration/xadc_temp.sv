// ============================================================================
// xadc_temp.sv — AXI-Lite slave для чтения температуры/напряжения XADC
// ============================================================================
// Регистры (32-бит, байтовый адрес, декод [3:2]):
//   [0x00] TEMP    {16'h0, raw_temp[15:0]}      — температура (XADC format)
//   [0x04] VCCINT  {16'h0, raw_vccint[15:0]}    — внутреннее питание
//   [0x08] VALID   {31'b0, valid_q}             — флаг валидности данных
//
// Источник данных: модуль ожидает external XADC Wizard IP, который пишет
// raw_temp / raw_vccint / raw_valid в этом же такте. В текущей интеграции
// (без XADC Wizard в BD) эти входы привязаны к 0 — TEMP=0, VCCINT=0, VALID=0.
// Для активации monitor_temp.py нужно добавить xilinx.com:ip:xadc_wiz в BD
// и подключить его выходы к u_xadc.raw_* (см. docs/ADDRESS_MAP.md §2.1).
//
// AXI-Lite slave переписан по образцу tdot_axi4.sv: независимые защёлки AW/W
// (приём в разных тактах не приводит к зависанию шины), корректная защита
// AR от перезаписи при висящем rvalid (PG055 §5/§6).
// ============================================================================
module xadc_temp #(
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int C_S_AXI_ADDR_WIDTH = 8
)(
    input  logic                                  S_AXI_ACLK,
    input  logic                                  S_AXI_ARESETN,
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]         S_AXI_AWADDR,
    input  logic                                  S_AXI_AWPROT,
    input  logic                                  S_AXI_AWVALID,
    output logic                                  S_AXI_AWREADY,
    input  logic [C_S_AXI_DATA_WIDTH-1:0]         S_AXI_WDATA,
    input  logic [C_S_AXI_DATA_WIDTH/8-1:0]       S_AXI_WSTRB,
    input  logic                                  S_AXI_WVALID,
    output logic                                  S_AXI_WREADY,
    output logic [1:0]                            S_AXI_BRESP,
    output logic                                  S_AXI_BVALID,
    input  logic                                  S_AXI_BREADY,
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]         S_AXI_ARADDR,
    input  logic                                  S_AXI_ARPROT,
    input  logic                                  S_AXI_ARVALID,
    output logic                                  S_AXI_ARREADY,
    output logic [C_S_AXI_DATA_WIDTH-1:0]         S_AXI_RDATA,
    output logic [1:0]                            S_AXI_RRESP,
    output logic                                  S_AXI_RVALID,
    input  logic                                  S_AXI_RREADY,
    // данные от XADC Wizard IP
    input  logic [15:0]                           raw_temp,
    input  logic [15:0]                           raw_vccint,
    input  logic                                  raw_valid
);

    logic clk, rst_n;
    assign clk   = S_AXI_ACLK;
    assign rst_n = S_AXI_ARESETN;

    localparam int ADDR_LSB = 2;

    // ==================== AXI-Lite write channel ====================
    // Независимый приём AW и W (защёлки глубиной 1): фазы могут приходить в
    // разных тактах — запись коммитируется, когда собраны обе и bvalid свободен.
    // Устраняет тупик/потерю записи, когда AWVALID и WVALID не совпадают в одном
    // такте (PG055 §5). Шаблон повторяет tdot_axi4.sv:148-206.
    logic awready, wready, bvalid;
    logic aw_latched, w_latched;    // занятость защёлок адреса/данных
    logic [C_S_AXI_ADDR_WIDTH-1:0] awaddr_q;
    logic [C_S_AXI_DATA_WIDTH-1:0] wdata_q;

    wire aw_hs     = S_AXI_AWVALID && awready;            // handshake AW
    wire w_hs      = S_AXI_WVALID  && wready;             // handshake W
    wire wr_commit = aw_latched && w_latched && !bvalid;  // commit: оба защёлкнуты, B свободен

    // состояние на следующий такт (для формирования готовностей без тупиков)
    wire aw_latched_n = aw_hs ? 1'b1 : (wr_commit ? 1'b0 : aw_latched);
    wire w_latched_n  = w_hs  ? 1'b1 : (wr_commit ? 1'b0 : w_latched);
    wire bvalid_n     = wr_commit ? 1'b1 :
                        (bvalid && S_AXI_BREADY) ? 1'b0 : bvalid;
    wire wr_commit_n  = aw_latched_n && w_latched_n && !bvalid_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awready <= 0; wready <= 0; bvalid <= 0;
            aw_latched <= 0; w_latched <= 0;
            awaddr_q <= 0; wdata_q <= 0;
        end else begin
            // приём AW/W в защёлки по handshake каждого канала независимо
            if (aw_hs) awaddr_q <= S_AXI_AWADDR;
            if (w_hs)  wdata_q  <= S_AXI_WDATA;
            aw_latched <= aw_latched_n;   // handshake заполняет, commit освобождает
            w_latched  <= w_latched_n;
            bvalid     <= bvalid_n;       // ответ: выставляется по commit, сброс по BREADY
            // готовности: защёлка свободна ИЛИ освободится этим тактом (commit).
            // Если обе защёлки заняты и bvalid висит — готовности сняты,
            // пока не освободится место.
            awready <= !aw_latched_n || wr_commit_n;
            wready  <= !w_latched_n  || wr_commit_n;
            // xadc_temp — read-only, поэтому write-commit игнорируется (не меняет
            // состояние регистров). Адрес/данные защёлкиваются только для возврата B.
        end
    end

    // ==================== AXI-Lite read channel ====================
    // Независимый приём AR (защёлка адреса), ответ (rvalid + rdata) выставляется
    // в следующем такте, сброс по rvalid && RREADY. Новый AR не принимается,
    // пока висит непрочитанный ответ (PG055 §6).
    logic arready, rvalid;
    logic [C_S_AXI_ADDR_WIDTH-1:0] araddr_q;
    wire ar_hs = S_AXI_ARVALID && arready;   // handshake AR
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arready <= 0; rvalid <= 0; araddr_q <= 0;
        end else begin
            // готовность к приёму AR: через такт после ARVALID и только
            // при отсутствии висящего ответа
            if (S_AXI_ARVALID && !arready && !rvalid) begin
                arready <= 1;
            end else begin
                arready <= 0;
            end
            // приём AR: фиксируем адрес, rvalid — в следующем такте
            if (ar_hs) begin
                araddr_q <= S_AXI_ARADDR;
                rvalid   <= 1;
            end else if (rvalid && S_AXI_RREADY) begin
                rvalid <= 0;
            end
        end
    end

    // ==================== XADC data latches ====================
    logic [15:0] temp_val, vccint_val;
    logic valid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            temp_val <= 0; vccint_val <= 0; valid_q <= 0;
        end else if (raw_valid) begin
            temp_val    <= raw_temp;
            vccint_val  <= raw_vccint;
            valid_q     <= 1;
        end
    end

    // ==================== read mux ====================
    logic [C_S_AXI_DATA_WIDTH-1:0] rdata;
    always_comb begin
        case (araddr_q[ADDR_LSB+:2])
            2'd0: rdata = {16'h0, temp_val};        // TEMP
            2'd1: rdata = {16'h0, vccint_val};      // VCCINT
            2'd2: rdata = {31'b0, valid_q};         // VALID
            default: rdata = 32'h0;
        endcase
    end

    assign S_AXI_AWREADY = awready;
    assign S_AXI_WREADY  = wready;
    assign S_AXI_BRESP   = 2'b00;
    assign S_AXI_BVALID  = bvalid;
    assign S_AXI_ARREADY = arready;
    assign S_AXI_RRESP   = 2'b00;
    assign S_AXI_RVALID  = rvalid;
    assign S_AXI_RDATA   = rdata;

endmodule
