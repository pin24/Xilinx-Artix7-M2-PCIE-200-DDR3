// ============================================================================
// tfadd_raw.sv — сумматор НЕНОРМАЛИЗОВАННЫХ продуктов TFloat48, BARREL-версия
// ============================================================================
// Шаг 1 плана пайплайнинга дерева (разрешено пользователем, 2026-09-06).
// ЛАТЕНТНОСТЬ: ФИКСИРОВАННАЯ 22 такта (23 состояния; было 21 такт/22
//   состояния до BUG-057, 15 тактов/16 состояний до BUG-056, 14 тактов/15
//   после BUG-053, 10 тактов/11 после BUG-047, 9 тактов/10 после BUG-046,
//   8 тактов/9 до):
//   IDLE -> INIT -> ALGN(баррель) -> ADD0..ADD11 (6 секций x 2 под-фазы 3+4
//   трита, BUG-048+BUG-056) ->
//   NORM0A(под-групп. мини-сканы 7 тритов, ст.1a BUG-057) ->
//   NORM0B(слияние под-групп в группы, ст.1b BUG-057) ->
//   NORM0C(слияние групп, ст.2 BUG-053) ->
//   NORM1A -> NORM1B -> NORM1C(pipe fq_dec) -> NORM2 -> DONE.
//
// BUG-048 (тайминг-цикл, gen_ad[u_add]): два разреза остаточных путей.
//   (a) ADD-фазы: каждая 14-тритная секция сумматора разрезана пополам
//       (7 тритов + регистр промежуточного переноса carry0a_q/carry1a_q/
//       carry2a_q) — конус carry_mid1_q -> sum_reg[78] (11+ тритов серийной
//       переносной цепочки) сокращён до 7 тритов на фазу.
//   (b) NORM-сканы: приоритетные сканы sum (p_found/p_top/sum_neg/rest_n1)
//       зарегистрированы в новой фазе PH_NORM0A, дешифровка P_can и
//       k_nrm_c = P_can - 18 выполняется в PH_NORM1A из ЗАРЕГИСТРИРОВАННЫХ
//       флагов — конус sum_reg -> k_nrm_q теряет слой дешифровки.
//   Семантика/математика бит-в-бит та же: A/B tb_tdot_axi4 24/24 байта.
//
// BUG-049 (тайминг-цикл, последний FATAL gen_ad[3]): микро-разрез расчёта
//   corr_n1 (тернарный корректор «ближайшего»/floor) в PH_NORM1B. Путь
//   sum_q_reg[82] -> corr_n1_q_reg (slack -0.572) шёл через слой |sum|
//   (mux sum_q/sum_neg_q) в приоритетный скан по sum_abs. Теперь сам |sum|
//   (sum_abs_q) и per-trit флаги коррекции (corr_nz_q: трит != 0, corr_i1_q:
//   трит == N1) считаются в PH_NORM1A (от комбинаторного sum + sum_neg_q) и
//   РЕГИСТРИРУЮТСЯ; PH_NORM1B делает только приоритетный скан ОДИНОЧНЫХ бит
//   (структура == скан-фазы NORM0A, доказана в бюджете). fq-баррель читает
//   sum_abs_q (регистр). FSM/латентность НЕ менялись (14 тактов).
//   Семантика бит-в-бит: A/B tb_tdot_axi4 24/24 байта.
//
// BUG-051 (тайминг-догоняние, последний FATAL gen_ad[2], WNS -0.026ns):
//   ÷-баррель fq разрезан на ДВЕ регистровые стадии. Стадия 1 (коарс: сдвиг
//   на k_nrm[2:0] тритов) считается в PH_NORM1A от КОМБИНАТОРНЫХ |sum|
//   (sum_abs_n1) и k_nrm_c[2:0] и регистрируется в fq_mid_q; стадия 2 (финал:
//   досдвиг на 8·k_nrm[5:3]) в PH_NORM1B читает fq_mid_q и k_nrm_q[5:3] ->
//   fq_q. Путь k_nrm_q -> fq_q (42x1-баррель, 6-бит селект по sum_abs_q)
//   сокращён до 8:1-мукса по 3 битам. Отдельный регистр sum_abs_q удалён:
//   |sum| теперь регистрируется в составе стадии 1 (fq_mid_q). Итог
//   fq[t] = |sum|[t + k_nrm] бит-в-бит прежний (8·k_hi + k_lo == k_nrm,
//   границы сдвига (t+8·k_hi)+k_lo <= 41 эквивалентны t+k_nrm <= 41).
//   FSM/латентность НЕ менялись (14 тактов). Семантика бит-в-бит:
//   A/B tb_tdot_axi4 24/24 байта.
//
// BUG-052 (микро-разрез тонкого пути PH_NORM1A, 16/4): регистр k_nrm_q был
//   удалён (вычитание -18 ушло в PH_NORM1B от регистра p_can_q). При 32/16
//   ЭТОТ путь стал FATAL (p_can_q -> fq_q, -1.976) — см. BUG-054, который
//   возвращает захват k_nrm_q в PH_NORM1A (математика не меняется).
//
// BUG-056 (тайминг-догоняние 32/16, WNS -0.270): последний серийный конус
//   ADD-цепочки. 7-тритные половины (BUG-048) при 32/16 снова глубоки:
//   carry1a_q -> sum_reg[55] (трит 27, 7 тритов серийной переносной сборки в
//   PH_ADD3). Каждая половина разрезана на 3+4 трита (PH_ADD0..PH_ADD11),
//   внутри добавлены регистры промежуточного переноса b0a_q..b2b_q: путь
//   carry->sum теперь <= 4 трита на такт. ФАЗ: 16 -> 22 состояния, латентность
//   15 -> 21 такт (валид-агностично: контроллер ждёт valid_out, lockstep
//   принимает сдвиг). Математика трит-в-трит та же (переносы ассоциативны).
//   Семантика бит-в-бит: A/B tb_tdot_axi4 24/24 байта.
//
// BUG-057 (тайминг-догоняние 32/16, WNS -0.342): остаточный конус скана
//   sum_reg -> g_top_q — 14-тритный мини-скан группы в PH_NORM0A (endpoint
//   g_top_q_reg[1][2]/D, src sum_reg[45]/C, трит 22 группы 1). Каждая группа
//   G=14 тритов разбита на 2 под-группы SG=7: PH_NORM0A сканирует под-группы
//   (глубина ~2-3 LUT) -> sg_*_q; PH_NORM0B сливает пары под-групп в
//   атрибуты групп (2-way приоритет из ЗАРЕГИСТРИРОВАННЫХ sg_*_q, ~2 LUT) ->
//   g_*_q; PH_NORM0C (новая, слияние групп, ~2 LUT) -> p_found_q/p_top_q/
//   sum_neg_q/rest_n1_q. Композиция под-группа->группа->итог ассоциативна
//   (та же префиксная структура, что BUG-053; доказательство gprefix
//   распространяется на любой уровень) — значения признаков бит-в-бит те же.
//   ФАЗ 22 -> 23, латентность 21 -> 22 такта (валид-агностично: контроллер
//   ждёт valid_out, lockstep принимает сдвиг). Математика трит-в-трит та же.
//   Семантика бит-в-бит: A/B tb_tdot_axi4 24/24 байта.
//
// BUG-053 (тайминг-догоняние, последний FATAL gen_ad[1], WNS -0.017ns):
//   приоритетный скан sum (p_found/p_top/sum_neg/rest_n1) разрезан на ДВЕ
//   регистровые стадии по принципу «групповой префикс» (G = 14 тритов,
//   NG = 3 группы). Было: пара серийных проходов по 42 тритам прямо от sum
//   в PH_NORM0A (первый ищет старший ненулевой трит, второй rest ниже него
//   и ЗАВИСИТ от p_top первого; цепочка ~6-7 LUT) -> WNS-путь
//   sum_reg -> rest_n1_q. Стало: стадия 1 (PH_NORM0A) считает для КАЖДОЙ
//   группы НЕЗАВИСИМО сырые признаки (параллельные мини-сканы по 14 тритов,
//   глубина ~2-3 LUT): g_nz/g_top/g_top_n1/g_rest_nz/g_rest_n1 и
//   регистрирует их; стадия 2 (новая PH_NORM0B) сливает группы сверху вниз
//   (3-way приоритет из ЗАРЕГИСТРИРОВАННЫХ признаков, глубина ~2 LUT) ->
//   p_found_q/p_top_q/sum_neg_q/rest_n1_q. Математика та же
//   (доказательство: proof_gprefix.py, 2.0M+ векторов old-scan == prefix,
//   0 расхождений). Латентность: 14 -> 15 тактов (16 состояний, +PH_NORM0B).
//   Семантика бит-в-бит: A/B tb_tdot_axi4 24/24 байта.
//
// BUG-054 (тайминг-цикл 32/16, FATAL p_can_q -> fq_q, WNS -1.976ns): путь
//   PH_NORM1B p_can_q_reg -> fq_q_reg шёл через k_nrm = p_can_q - 18 (comb) и
//   баррель-финал {k_nrm[5:3]} -> 8:1-mux. Стало: захват k_nrm_q <= k_nrm_c
//   в PH_NORM1A ПАРАЛЛЕЛЬНО fq_mid_q (оба от комбинаторики NORM1A, та же
//   фаза), все потребители PH_NORM1B (финал ÷-барреля по k_nrm_q[5:3],
//   corr_n1, sat_k, e_sum_next) читают ТОЛЬКО регистр k_nrm_q. Стадии 1/2
//   барреля согласованы: k_nrm_q == k_nrm_c того же такта (как при BUG-051).
//   Математика бит-в-бит та же. FSM/латентность НЕ менялись (16 состояний/
//   15 тактов). Семантика: A/B tb_tdot_axi4 24/24 байта.
//
// Семантика НЕ изменилась (бит-в-бит). Доказательство: proof_tfadd_barrel.py
// (ALL PROOFS PASSED, 280k+ векторов) + A/B на xsim: tb_tfadd_equiv.sv.
//   * ALGN: rhu_next serial (+1/-1 танцы, round-to-nearest по модулю) ==
//     чистый сбалансированный сдвиг на 1 (A1); k сдвигов == сдвиг на k (A3)
//     -> однотактный баррель k = min(|de|, 22), БЕЗ цепей переноса.
//   * NORM: fd3 == sign*floor(|x|/3) (A2) -> floor/3^k одним сдвигом с
//     коррекцией -1 (если старший ненулевой отброшенный трит == N1);
//     x3^k — чистый сдвиг. Диапазон — по КАНОНИЧЕСКОЙ позиции
//     P = floor(log3|sum|), НЕ по позиции старшего сбалансированного трита
//     (контрпример: 3^19-1: p=19, но P=18 — уже в диапазоне). HW-правило:
//     P = p - [старший ненулевой трит ниже p == N1] (A4b, 50k векторов).
//   * Порядок проверок NORM как в serial: zero -> e_sum>40 (SAT) ->
//     P>=19: floor/3^(P-18) c клампом e_sum+k<=40 -> P<=17: x3^min(18-P,
//     e_sum+40) -> P=18: готово. DONE: zero|e_sum<-40 -> 0; SAT -> FF.
//
// BUG-040 (исправлен здесь, найден при подготовке барреля): в serial
//   cnt[5:0] обрезал |Δe| по mod 64; продукты tfmul_raw дают
//   e = ea+eb-18 ∈ [-98, 62] => Δe до 160, при |Δe| >= 64 выравнивание
//   шло по мусорному сдвигу (напр. Δe=64 -> cnt=0 -> малый продукт
//   добавлялся в масштабе большого). Теперь de — 9 бит,
//   k = min(|de|, 22) — проектное намерение (A6: barrel == intent на всём
//   de 0..160; serial с багом расходится в 2880/30000 случайных de>=64).
//
// BUG-041 (исправлен здесь, 2026-09-06, найден при подготовке Шага 2 дерева):
//   нулевые операнды. Выбор big/small шёл по ЭКСПОНЕНТЕ, а нулевой продукт /
//   частичная сумма несёт МУСОРНУЮ экспоненту (tfmul_raw: prod=0,
//   e=ea+eb-18 ∈ [-98,62]; нулевой TFloat48 = m=0, e=0). Если нулевой операнд
//   оказывался «большим» (напр. нулевой вес при данных с e<0), ненулевой
//   операнд уходил в m_small и сдвигался на min(|Δe|,22) тритов: при |Δe|>22 —
//   ТЕРЯЛСЯ ПОЛНОСТЬЮ (x+0 == 0), при |Δe|<=22 — огрызался. Реальный кейс —
//   тернарные веса {-1,0,+1}: много нулевых продуктов на уровне 0 дерева и
//   нулевые частичные суммы (48'h0, e=0) на уровнях >=1. Теперь: za/zb —
//   нулевой операнд выбрасывается, ненулевой идёт как big с k=0:
//   x+0 == norm(x), 0+0 == 0 (семантика golden _raw_add из
//   verify_compute_dot_par_raw.py). Доказательство: proof_tree_par.py (Z1/Z2).
// ============================================================================
module tfadd_raw (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [79:0] a_prod,
    input  logic signed [7:0]  a_e,
    input  logic        a_neg,
    input  logic [79:0] b_prod,
    input  logic signed [7:0]  b_e,
    input  logic        b_neg,
    output logic        valid_out,
    output logic [47:0] result
);
    localparam logic [1:0] P1 = 2'b01;
    localparam logic [1:0] N1 = 2'b10;
    localparam int W = 42;
    // BUG-053: групповой префикс скан-стадии (стадия 1 = мини-сканы по группам,
    // стадия 2 = слияние групп). NG групп по G тритов, NG*G == W.
    localparam int NG = 3;
    localparam int G  = 14;
    // BUG-057: каждая группа G=14 тритов разрезана на 2 под-группы SG=7
    // (NSG = 2*NG под-групп на 42 трита, NSG*SG == W). Трёхстадийный префикс:
    // под-группы (PH_NORM0A) -> группы (PH_NORM0B) -> итог (PH_NORM0C).
    localparam int NSG = 6;
    localparam int SG  = 7;

    function automatic logic signed [2:0] trit_val2(input logic [1:0] c);
        case (c)
            P1: trit_val2 = 3'sd1;
            N1: trit_val2 = -3'sd1;
            default: trit_val2 = 3'sd0;
        endcase
    endfunction

    function automatic logic [1:0] int2trit2(input logic signed [2:0] v);
        case (v)
            3'sd1: int2trit2 = P1;
            -3'sd1: int2trit2 = N1;
            default: int2trit2 = 2'b00;
        endcase
    endfunction

    function automatic logic [7:0] exp_code(input logic signed [7:0] v);
        logic [7:0] out;
        case (v)
            -8'sd40: out = {2'b10,2'b10,2'b10,2'b10};
            -8'sd39: out = {2'b10,2'b10,2'b10,2'b00};
            -8'sd38: out = {2'b10,2'b10,2'b10,2'b01};
            -8'sd37: out = {2'b10,2'b10,2'b00,2'b10};
            -8'sd36: out = {2'b10,2'b10,2'b00,2'b00};
            -8'sd35: out = {2'b10,2'b10,2'b00,2'b01};
            -8'sd34: out = {2'b10,2'b10,2'b01,2'b10};
            -8'sd33: out = {2'b10,2'b10,2'b01,2'b00};
            -8'sd32: out = {2'b10,2'b10,2'b01,2'b01};
            -8'sd31: out = {2'b10,2'b00,2'b10,2'b10};
            -8'sd30: out = {2'b10,2'b00,2'b10,2'b00};
            -8'sd29: out = {2'b10,2'b00,2'b10,2'b01};
            -8'sd28: out = {2'b10,2'b00,2'b00,2'b10};
            -8'sd27: out = {2'b10,2'b00,2'b00,2'b00};
            -8'sd26: out = {2'b10,2'b00,2'b00,2'b01};
            -8'sd25: out = {2'b10,2'b00,2'b01,2'b10};
            -8'sd24: out = {2'b10,2'b00,2'b01,2'b00};
            -8'sd23: out = {2'b10,2'b00,2'b01,2'b01};
            -8'sd22: out = {2'b10,2'b01,2'b10,2'b10};
            -8'sd21: out = {2'b10,2'b01,2'b10,2'b00};
            -8'sd20: out = {2'b10,2'b01,2'b10,2'b01};
            -8'sd19: out = {2'b10,2'b01,2'b00,2'b10};
            -8'sd18: out = {2'b10,2'b01,2'b00,2'b00};
            -8'sd17: out = {2'b10,2'b01,2'b00,2'b01};
            -8'sd16: out = {2'b10,2'b01,2'b01,2'b10};
            -8'sd15: out = {2'b10,2'b01,2'b01,2'b00};
            -8'sd14: out = {2'b10,2'b01,2'b01,2'b01};
            -8'sd13: out = {2'b00,2'b10,2'b10,2'b10};
            -8'sd12: out = {2'b00,2'b10,2'b10,2'b00};
            -8'sd11: out = {2'b00,2'b10,2'b10,2'b01};
            -8'sd10: out = {2'b00,2'b10,2'b00,2'b10};
            -8'sd9 : out = {2'b00,2'b10,2'b00,2'b00};
            -8'sd8 : out = {2'b00,2'b10,2'b00,2'b01};
            -8'sd7 : out = {2'b00,2'b10,2'b01,2'b10};
            -8'sd6 : out = {2'b00,2'b10,2'b01,2'b00};
            -8'sd5 : out = {2'b00,2'b10,2'b01,2'b01};
            -8'sd4 : out = {2'b00,2'b00,2'b10,2'b10};
            -8'sd3 : out = {2'b00,2'b00,2'b10,2'b00};
            -8'sd2 : out = {2'b00,2'b00,2'b10,2'b01};
            -8'sd1 : out = {2'b00,2'b00,2'b00,2'b10};
            8'sd0  : out = {2'b00,2'b00,2'b00,2'b00};
            8'sd1  : out = {2'b00,2'b00,2'b00,2'b01};
            8'sd2  : out = {2'b00,2'b00,2'b01,2'b10};
            8'sd3  : out = {2'b00,2'b00,2'b01,2'b00};
            8'sd4  : out = {2'b00,2'b00,2'b01,2'b01};
            8'sd5  : out = {2'b00,2'b01,2'b10,2'b10};
            8'sd6  : out = {2'b00,2'b01,2'b10,2'b00};
            8'sd7  : out = {2'b00,2'b01,2'b10,2'b01};
            8'sd8  : out = {2'b00,2'b01,2'b00,2'b10};
            8'sd9  : out = {2'b00,2'b01,2'b00,2'b00};
            8'sd10 : out = {2'b00,2'b01,2'b00,2'b01};
            8'sd11 : out = {2'b00,2'b01,2'b01,2'b10};
            8'sd12 : out = {2'b00,2'b01,2'b01,2'b00};
            8'sd13 : out = {2'b00,2'b01,2'b01,2'b01};
            8'sd14 : out = {2'b01,2'b10,2'b10,2'b10};
            8'sd15 : out = {2'b01,2'b10,2'b10,2'b00};
            8'sd16 : out = {2'b01,2'b10,2'b10,2'b01};
            8'sd17 : out = {2'b01,2'b10,2'b00,2'b10};
            8'sd18 : out = {2'b01,2'b10,2'b00,2'b00};
            8'sd19 : out = {2'b01,2'b10,2'b00,2'b01};
            8'sd20 : out = {2'b01,2'b10,2'b01,2'b10};
            8'sd21 : out = {2'b01,2'b10,2'b01,2'b00};
            8'sd22 : out = {2'b01,2'b10,2'b01,2'b01};
            8'sd23 : out = {2'b01,2'b00,2'b10,2'b10};
            8'sd24 : out = {2'b01,2'b00,2'b10,2'b00};
            8'sd25 : out = {2'b01,2'b00,2'b10,2'b01};
            8'sd26 : out = {2'b01,2'b00,2'b00,2'b10};
            8'sd27 : out = {2'b01,2'b00,2'b00,2'b00};
            8'sd28 : out = {2'b01,2'b00,2'b00,2'b01};
            8'sd29 : out = {2'b01,2'b00,2'b01,2'b10};
            8'sd30 : out = {2'b01,2'b00,2'b01,2'b00};
            8'sd31 : out = {2'b01,2'b00,2'b01,2'b01};
            8'sd32 : out = {2'b01,2'b01,2'b10,2'b10};
            8'sd33 : out = {2'b01,2'b01,2'b10,2'b00};
            8'sd34 : out = {2'b01,2'b01,2'b10,2'b01};
            8'sd35 : out = {2'b01,2'b01,2'b00,2'b10};
            8'sd36 : out = {2'b01,2'b01,2'b00,2'b00};
            8'sd37 : out = {2'b01,2'b01,2'b00,2'b01};
            8'sd38 : out = {2'b01,2'b01,2'b01,2'b10};
            8'sd39 : out = {2'b01,2'b01,2'b01,2'b00};
            8'sd40 : out = {2'b01,2'b01,2'b01,2'b01};
            default: out = 8'h00;
        endcase
        exp_code = out;
    endfunction

    // ---- регистры ----
    logic [2*W-1:0] m_big, m_small;
    logic signed [7:0] m_big_e;
    logic signed [7:0] e_sum;
    logic [2*W-1:0] sum;
    logic [47:0] result_q;
    logic valid_q;
    logic [4:0] k_algn;
    logic zero_q, sat_q;

    // ---- BUG-047: «сырые» регистры стадии 1 (захват в PH_NORM1A) ----
    // Разрез конуса sum -> fq_q/corr_n1_q/e_sum_next_q: PH_NORM1A хранит
    // результат сканов и дешифровки (sum_q/sum_neg_q/zero_q/p_can_q/k_nrm_q),
    // PH_NORM1B считает |sum|, баррель, коррекцию и флаги из ЭТИХ регистров.
    logic [83:0] sum_q;       // копия sum (для |sum| и ×-барреля в NORM2)
    logic        sum_neg_q;   // знак исходной sum (для инверсии fq_dec и |sum|)
    logic [5:0]  p_can_q;     // каноническая позиция P = floor(log3|sum|)
    // BUG-052: регистр k_nrm_q УДАЛЁН (был P-18, индекс ÷-барреля). P_can
    //   захватывается в PH_NORM1A (p_can_q), и ВСЕ потребители k_nrm в
    //   PH_NORM1B считают k_nrm = p_can_q - 18 комбинаторно ОТ РЕГИСТРА —
    //   вычитание константы (2-3 LUT) уходит с критического пути
    //   rest_n1_q -> k_nrm_q (WNS +0.011). Значение barreля/коррекции то же
    //   (k_nrm_q был = k_nrm_c = P_can - 18, а p_can_q == P_can такта PH_NORM1A).

    // ---- BUG-048/BUG-053: «сырые» скан-флаги sum (захват в PH_NORM0B) ----
    // BUG-048: приоритетные сканы зарегистрированы после сканирования;
    //   дешифровка P_can и k_nrm_c = P_can - 18 выполняется в PH_NORM1A из
    //   ЭТИХ регистров. BUG-053: само сканирование разрезано на 2 стадии —
    //   PH_NORM0A захватывает сырые ГРУППОВЫЕ признаки ниже, PH_NORM0B
    //   (новая) сливает группы в эти же финальные регистры. Конус sum_reg ->
    //   rest_n1_q заканчивается на мини-скане G=14 тритов + 3-way приоритете.
    logic        p_found_q;   // sum != 0 (захват в PH_NORM0C, BUG-053/BUG-057)
    logic [5:0]  p_top_q;     // позиция старшего ненулевого трита (PH_NORM0C)
    logic        rest_n1_q;   // старший ненулевой ниже p_top == N1 (PH_NORM0C)
    // ---- BUG-053: «сырые» групповые признаки скан-стадии ----
    // стадия 1 (PH_NORM0A): комбинаторные мини-сканы по группам из sum ->
    //   g_*_q; стадия 2 (PH_NORM0B): слияние групп -> p_found_q/p_top_q/...
    logic [NG-1:0]      g_nz;        // группа содержит ненулевой трит
    logic [NG-1:0][5:0] g_top;       // абсолютный индекс старшего ненулевого трита
    logic [NG-1:0]      g_top_n1;    // старший трит группы == N1
    logic [NG-1:0]      g_rest_nz;   // ниже g_top в группе есть ненулевой трит
    logic [NG-1:0]      g_rest_n1;   // высший из тритов ниже g_top == N1
    logic [NG-1:0]      g_nz_q;      // (регистры стадии 1 -> стадия 2)
    logic [NG-1:0][5:0] g_top_q;
    logic [NG-1:0]      g_top_n1_q;
    logic [NG-1:0]      g_rest_nz_q;
    logic [NG-1:0]      g_rest_n1_q;
    // ---- BUG-057: под-групповые «сырые» признаки (стадия 1a) ----
    // PH_NORM0A сканирует NSG под-групп по SG=7 тритов (комбинаторно из sum,
    // глубина ~2-3 LUT) -> sg_*_q; PH_NORM0B сливает пары под-групп в
    // групповые атрибуты g_* (2-way приоритет из ЗАРЕГИСТРИРОВАННЫХ sg_*_q)
    // -> g_*_q; PH_NORM0C сливает группы (3-way приоритет) -> p_*_q.
    logic [NSG-1:0]      sg_nz;        // под-группа содержит ненулевой трит
    logic [NSG-1:0][5:0] sg_top;       // абсолютный индекс старшего ненулевого трита
    logic [NSG-1:0]      sg_top_n1;    // старший трит под-группы == N1
    logic [NSG-1:0]      sg_rest_nz;   // ниже sg_top в под-группе есть ненулевой трит
    logic [NSG-1:0]      sg_rest_n1;   // высший из тритов ниже sg_top == N1
    logic [NSG-1:0]      sg_nz_q;      // (регистры стадии 1a -> стадия 1b)
    logic [NSG-1:0][5:0] sg_top_q;
    logic [NSG-1:0]      sg_top_n1_q;
    logic [NSG-1:0]      sg_rest_nz_q;
    logic [NSG-1:0]      sg_rest_n1_q;

    // ---- Δe (9 бит, BUG-040 fix) и k_algn = min(|Δe|, 22) ----
    logic signed [8:0] de_s;
    logic [8:0] de_a;
    logic [4:0] k_algn_c;
    assign de_s = $signed({a_e[7], a_e}) - $signed({b_e[7], b_e});
    assign de_a = de_s[8] ? (9'd0 - de_s) : de_s;
    assign k_algn_c = (de_a > 9'd22) ? 5'd22 : de_a[4:0];

    // ---- BUG-041: детект нулевых операндов (мантисса == 0, все триты 00) ----
    logic za, zb;
    assign za = (a_prod == 80'h0);
    assign zb = (b_prod == 80'h0);

    // ---- ALGN баррель: чистый сбалансированный сдвиг на k_algn (nearest) ----
    logic [2*W-1:0] algn_y;
    always_comb begin
        for (int t = 0; t < W; t++)
            algn_y[2*t +: 2] = (t + k_algn <= W-1)
                             ? m_small[2*(t + k_algn) +: 2] : 2'b00;
    end

    // ---- ADD: 42-тритная сумма, разбита на 6 секций (линии переноса) ----
    // BUG-043: секции 14 тритов; BUG-048: каждая секция разрезана пополам
    // (7 тритов), переносы между половинами секций (carry0a_q/carry_mid0_q/
    // carry1a_q/carry_mid1_q/carry2a_q).
    // BUG-056: каждую 7-тритную половину разрезаем ЕЩЁ раз на 3+4 трита
    // (всего 12 под-фаз PH_ADD0..PH_ADD11), между под-фазами внутри половины
    // вставлены НОВЫЕ регистры промежуточного переноса
    // b0a_q/b0b_q/b1a_q/b1b_q/b2a_q/b2b_q. Теперь путь перенос куда-то -> sum
    // серийно проходит не более 4 тритов за такт (было 7): WNS-путь 32/16
    // carry1a_q -> sum[55] (трит 27, фаза PH_ADD3, конус 7 тритов) разрезан на
    // carry1a_q -> b1b_q (триты 21..23, 3 трита) и b1b_q -> sum[55] (триты
    // 24..27, 4 трита). Математика переносов ассоциативна — сумма трит-в-трит
    // та же.
    logic signed [2:0] carry_mid0, carry_mid1;      // переносы на стыках секций
    logic signed [2:0] carry_mid0_q, carry_mid1_q;  // (decl moved up for xvlog legality)
    logic signed [2:0] carry0a, carry1a, carry2a, carry2b;
    logic signed [2:0] carry0a_q, carry1a_q, carry2a_q;  // BUG-048: переносы половин
    // BUG-056: промежуточные переносы 3+4-под-фаз внутри каждой половины.
    logic signed [2:0] b0a, b0b, b1a, b1b, b2a, b2b;        // комбинаторные
    logic signed [2:0] b0a_q, b0b_q, b1a_q, b1b_q, b2a_q, b2b_q; // регистры под-фаз
    logic [7:0] add_r0a1, add_r0a2;    // триты 0..2 (3), 3..6 (4)     секция 0 (a)
    logic [7:0] add_r0b1, add_r0b2;    // триты 7..9 (3), 10..13 (4)   секция 0 (b)
    logic [7:0] add_r1a1, add_r1a2;    // триты 14..16, 17..20          секция 1 (a)
    logic [7:0] add_r1b1, add_r1b2;    // триты 21..23, 24..27          секция 1 (b)
    logic [7:0] add_r2a1, add_r2a2;    // триты 28..30, 31..34          секция 2 (a)
    logic [7:0] add_r2b1, add_r2b2;    // триты 35..37, 38..41          секция 2 (b)

    // универсальный «прогон» под-фазы: триты [lo..hi] (<=4), стартовый перенос cin.
    function automatic void srun(input logic [2*W-1:0] bm,
                                 input logic [2*W-1:0] sm,
                                 input int lo, input int hi,
                                 input logic signed [2:0] cin,
                                 output logic [7:0] out,
                                 output logic signed [2:0] cout);
        logic signed [2:0] c;
        c = cin;
        for (int t = lo; t <= hi; t++) begin
            logic signed [2:0] sv;
            sv = trit_val2(bm[2*t +: 2]) + trit_val2(sm[2*t +: 2]) + c;
            if (sv > 1) begin c = 3'sd1; out[2*(t-lo) +: 2] = int2trit2(sv - 3); end
            else if (sv < -1) begin c = -3'sd1; out[2*(t-lo) +: 2] = int2trit2(sv + 3); end
            else begin c = 3'sd0; out[2*(t-lo) +: 2] = int2trit2(sv); end
        end
        cout = c;
    endfunction

    always_comb srun(m_big, m_small,  0,  2,  3'sd0,     add_r0a1, b0a);
    always_comb srun(m_big, m_small,  3,  6,  b0a_q,     add_r0a2, carry0a);
    always_comb srun(m_big, m_small,  7,  9,  carry0a_q, add_r0b1, b0b);
    always_comb srun(m_big, m_small, 10, 13,  b0b_q,     add_r0b2, carry_mid0);
    always_comb srun(m_big, m_small, 14, 16,  carry_mid0_q, add_r1a1, b1a);
    always_comb srun(m_big, m_small, 17, 20,  b1a_q,     add_r1a2, carry1a);
    always_comb srun(m_big, m_small, 21, 23,  carry1a_q, add_r1b1, b1b);
    always_comb srun(m_big, m_small, 24, 27,  b1b_q,     add_r1b2, carry_mid1);
    always_comb srun(m_big, m_small, 28, 30,  carry_mid1_q, add_r2a1, b2a);
    always_comb srun(m_big, m_small, 31, 34,  b2a_q,     add_r2a2, carry2a);
    always_comb srun(m_big, m_small, 35, 37,  carry2a_q, add_r2b1, b2b);
    always_comb srun(m_big, m_small, 38, 41,  b2b_q,     add_r2b2, carry2b);
    // carry2b: перенос из старшего трита суммы — теряется (как и раньше)

    // ---- NORM: знак, p (старший сбаланс.), P (каноническая), барьеры ----
    logic        sum_neg;    // старший ненулевой трит sum == N1
    logic        p_found;    // sum != 0
    logic [5:0]  p_top;      // позиция старшего ненулевого трита
    logic        rest_n1;    // старший ненулевой НИЖЕ p_top == N1
    logic [5:0]  P_can;      // каноническая floor(log3|sum|): P = p - rest_n1
    logic [83:0] sum_abs_n1; // |sum| (комбинаторно из sum/sum_neg_q, BUG-049)
    logic [W-1:0] corr_nz;   // per-trit: |sum|[t] != 0 (BUG-049)
    logic [W-1:0] corr_i1;   // per-trit: |sum|[t] == N1 (BUG-049)
    // ---- PH_NORM1A -> PH_NORM1B: зарегистрированные флаги коррекции (BUG-049)
    // |sum| и per-trit флаги считаются в PH_NORM1A от sum/sum_neg_q и
    // регистрируются — corr_n1_q в NORM1B получается приоритетным сканом
    // ОДИНОЧНЫХ бит, а не из sum_q. |sum| (sum_abs_n1) дополнительно уходит в
    // стадию 1 ÷-барреля (fq_mid_q), отдельный регистр sum_abs_q удалён (BUG-051).
    logic [W-1:0] corr_nz_q;  // |sum|[t] != 0 (захват в PH_NORM1A, BUG-049)
    logic [W-1:0] corr_i1_q;  // |sum|[t] == N1 (захват в PH_NORM1A, BUG-049)
    // ---- BUG-058: гейт-предикаты corr (разрез пути k_nrm_q -> corr_n1_q -> fq_q) ----
    // Путь #1 (WNS +0.030, 32/16): k_nrm_q[5] -> fq_q[19] шёл через приоритетный
    // скан corr_n1 (6 LUT: сравнения t<k_nrm_q) + fq-дешифровку (4 LUT),
    // data 7.659ns (route 78%). Разрез: PH_NORM1B считает ОДИНОЧНЫЕ гейт-
    // предикаты cg_c[t] = corr_nz_q[t] && (t < k_nrm_q) (параллельно, 1 LUT на
    // трит) и регистрирует их; новая PH_NORM1B2 делает приоритетный скан по
    // ОДНОБИТОВЫМ cg_q (структура как скан-фазы NORM0, ~2-3 LUT) -> corr_n1_q.
    // Семантика та же: старший t с corr_nz_q[t] и t<k_nrm_q даёт corr_i1_q[t].
    logic [W-1:0] cg_c;   // комбинаторно: corr_nz_q[t] && (t < k_nrm_q) (PH_NORM1B)
    logic [W-1:0] cg_q;   // захват PH_NORM1B -> скан PH_NORM1B2

    // ---- BUG-053: двухстадийный групповой префикс приоритетного скана ----
    // мини-скан одной группы (семантика идентична старой паре проходов:
    // 1-й ищет старший ненулевой трит группы, 2-й — высший ненулевой СТРОГО
    // ниже него; см. proof_gprefix.py)
    function automatic void gscan_f(input logic [83:0] sv, input int gb, input int ge,
        output logic gnz, output logic [5:0] gtop, output logic gtop_n1,
        output logic grst_nz, output logic grst_n1);
        logic fnd;
        fnd = 1'b0; gnz = 1'b0; gtop = 6'd0; gtop_n1 = 1'b0;
        for (int t = ge; t >= gb; t--) begin
            if (!fnd && sv[2*t +: 2] != 2'b00) begin
                fnd = 1'b1; gnz = 1'b1;
                gtop    = 6'(t);
                gtop_n1 = (sv[2*t +: 2] == N1);
            end
        end
        fnd = 1'b0; grst_nz = 1'b0; grst_n1 = 1'b0;
        for (int t = ge; t >= gb; t--) begin
            if (!fnd && 32'(t) < 32'(gtop) && sv[2*t +: 2] != 2'b00) begin
                fnd = 1'b1; grst_nz = 1'b1;
                grst_n1 = (sv[2*t +: 2] == N1);
            end
        end
    endfunction

    // слияние пары под-групп (низ A / верх B) в атрибуты группы (PH_NORM0B).
    // Семантика та же, что у слияния групп в PH_NORM0C, на уровень ниже:
    // top берется из B, если B ненулевая; rest — внутри B, а если ниже top в B
    // пусто — старший трит A (если A ненулевая).
    function automatic void sgmerge_f(
        input logic nz_lo, input logic [5:0] top_lo, input logic top_n1_lo,
        input logic rstnz_lo, input logic rstn1_lo,
        input logic nz_hi, input logic [5:0] top_hi, input logic top_n1_hi,
        input logic rstnz_hi, input logic rstn1_hi,
        output logic gnz, output logic [5:0] gtop, output logic gtop_n1,
        output logic grstnz, output logic grstn1);
        gnz = nz_hi | nz_lo;
        if (nz_hi) begin
            gtop    = top_hi;
            gtop_n1 = top_n1_hi;
            if (rstnz_hi) begin
                grstnz = 1'b1;
                grstn1 = rstn1_hi;
            end else begin
                grstnz = nz_lo;
                grstn1 = nz_lo ? top_n1_lo : 1'b0;
            end
        end else begin
            gtop    = top_lo;
            gtop_n1 = top_n1_lo;
            grstnz  = rstnz_lo;
            grstn1  = rstn1_lo;
        end
    endfunction

    // стадия 1a (PH_NORM0A, BUG-057): сырые ПОД-ГРУППОВЫЕ признаки — NSG
    // независимых параллельных мини-сканов по SG=7 тритов (глубина ~2-3 LUT)
    // из sum -> sg_*_q. Конус sum_reg -> sg_*_q вдвое короче прежнего
    // 14-тритного scan (endpoint g_top_q_reg при 32/16 был WNS -0.342).
    always_comb begin
        for (int s = 0; s < NSG; s++)
            gscan_f(sum, s*SG, s*SG + SG - 1, sg_nz[s], sg_top[s],
                    sg_top_n1[s], sg_rest_nz[s], sg_rest_n1[s]);
    end

    // стадия 1b (PH_NORM0B, BUG-057): слияние пар под-групп в групповые
    // атрибуты из ЗАРЕГИСТРИРОВАННЫХ sg_*_q (2-way приоритет, глубина ~2 LUT)
    // -> g_* (захват в g_*_q). Группа g = под-группы {2g (низ), 2g+1 (верх)}.
    always_comb begin
        for (int g = 0; g < NG; g++)
            sgmerge_f(sg_nz_q[2*g], sg_top_q[2*g], sg_top_n1_q[2*g],
                      sg_rest_nz_q[2*g], sg_rest_n1_q[2*g],
                      sg_nz_q[2*g+1], sg_top_q[2*g+1], sg_top_n1_q[2*g+1],
                      sg_rest_nz_q[2*g+1], sg_rest_n1_q[2*g+1],
                      g_nz[g], g_top[g], g_top_n1[g],
                      g_rest_nz[g], g_rest_n1[g]);
    end

    // стадия 2 (PH_NORM0C): слияние групп сверху вниз из ЗАРЕГИСТРИРОВАННЫХ
    // g_*_q (3-way приоритет, глубина ~2 LUT) -> финальные сканы.
    // rest_n1: второй трит верхней ненулевой группы; если его нет — старший
    // трит следующей ненулевой группы ниже; если и его нет — 0.
    always_comb begin
        p_found = g_nz_q[2] | g_nz_q[1] | g_nz_q[0];
        if (g_nz_q[2]) begin
            p_top   = g_top_q[2];
            sum_neg = g_top_n1_q[2];
            if (g_rest_nz_q[2])      rest_n1 = g_rest_n1_q[2];
            else if (g_nz_q[1])      rest_n1 = g_top_n1_q[1];
            else if (g_nz_q[0])      rest_n1 = g_top_n1_q[0];
            else                     rest_n1 = 1'b0;
        end else if (g_nz_q[1]) begin
            p_top   = g_top_q[1];
            sum_neg = g_top_n1_q[1];
            if (g_rest_nz_q[1])      rest_n1 = g_rest_n1_q[1];
            else if (g_nz_q[0])      rest_n1 = g_top_n1_q[0];
            else                     rest_n1 = 1'b0;
        end else begin
            p_top   = g_top_q[0];
            sum_neg = g_top_n1_q[0];
            if (g_rest_nz_q[0])      rest_n1 = g_rest_n1_q[0];
            else                     rest_n1 = 1'b0;
        end
    end

    // BUG-048: дешифровка P_can — из ЗАРЕГИСТРИРОВАННЫХ сканов (сырые флаги
    // p_found_q/p_top_q/rest_n1_q захвачены в PH_NORM0B, BUG-053). Конус
    // sum -> p_can_q/k_nrm_q теряет слой дешифровки + вычитания, приоритетный
    // скан заканчивается на сырых регистрах.
    always_comb begin
        if (!p_found_q)         P_can = 6'd0;
        else if (p_top_q == 0)  P_can = 6'd0;                  // |sum| == 1
        else                    P_can = rest_n1_q ? (p_top_q - 6'd1) : p_top_q;
    end

    // BUG-049: per-trit флаги коррекции floor считаются в PH_NORM1A от
    // комбинаторных sum/sum_neg (скан NORM0A) и РЕГИСТРИРУЮТСЯ
    // (corr_nz_q/corr_i1_q) до PH_NORM1B. Единственный FATAL-путь
    // укорочен: sum_q_reg -> corr_n1_q (расчёт corr_n1, ~-0.57ns) теперь
    // начинается с ОДИНОЧНЫХ регистровых бит corr_nz_q/corr_i1_q/k_nrm_q, а не
    // с sum_q через слой |sum| (mux). PH_NORM1B делает только приоритетный
    // скан — структура идентична скан-фазам NORM0A (доказано в бюджете).
    // BUG-051: |sum| (sum_abs_n1) дополнительно используется здесь же в стадии
    // 1 ÷-барреля (см. fq_mid выше) — общей комбинаторной выработки |sum| нет.
    always_comb begin
        for (int t = 0; t < W; t++) begin
            sum_abs_n1[2*t +: 2] = sum_neg_q
                                 ? ((sum[2*t +: 2] == P1) ? N1 :
                                    (sum[2*t +: 2] == N1) ? P1 : 2'b00)
                                 : sum[2*t +: 2];
            corr_nz[t] = (sum[2*t +: 2] != 2'b00);
            corr_i1[t] = sum_neg_q ? (sum[2*t +: 2] == P1)
                                   : (sum[2*t +: 2] == N1);
        end
    end

    logic        up_big;      // P >= 19  -> floor/3^(P-18)
    logic        dn_small;    // P <= 17  -> x3^(18-P)
    logic [5:0]  k_nrm_c;     // сырое P - 18 (комбинаторно, стадия 1 ÷-барреля, BUG-047)
    logic [5:0]  k_nrm_q;     // P - 18 (1..23), захват PH_NORM1A (BUG-054: разрез p_can_q -> fq_q)
    logic        sat_entry, sat_k, sat_norm;
    logic [83:0] fq;          // ÷-баррель (сдвиг |sum|)
    // ---- BUG-051: ÷-баррель fq разрезан на ДВЕ регистровые стадии ----
    // Стадия 1 (коарс: сдвиг на k_nrm[2:0] тритов) считается в PH_NORM1A от
    // КОМБИНАТОРНЫХ |sum| (sum_abs_n1) и k_nrm_c[2:0], захватывается в
    // fq_mid_q; стадия 2 (досдвиг на 8·k_nrm[5:3]) в PH_NORM1B читает fq_mid_q
    // и k_nrm_q[5:3] -> fq_q. Путь k_nrm_q -> fq_q (WNS -0.026, 42x1-баррель с
    // 6-бит селектом) сокращён до 8:1-мукса по 3 битам. Отдельный регистр
    // sum_abs_q больше не нужен (|sum| уходит в стадию 1 без регистрации).
    logic [83:0] fq_mid;      // стадия 1 ÷-барреля (комбинаторно, PH_NORM1A)
    logic [83:0] fq_mid_q;    // захват стадии 1 (PH_NORM1A -> PH_NORM1B)
    logic        corr_n1;     // коррекция floor: старший отброшенный == N1
    logic [5:0]  k_dn;        // min(18-P, e_sum+40), 0..18
    logic signed [7:0] e_sum_next;

    // BUG-047: эти сигналы живут во второй половине стадии 1 (PH_NORM1B) и
    // зависят ТОЛЬКО от зарегистрированных zero_q/p_can_q/k_nrm_q/e_sum —
    // конус комбинаторики от sum_reg заканчивается на регистрах PH_NORM1A.
    assign up_big   = !zero_q && (p_can_q >= 6'd19);
    assign dn_small = !zero_q && (p_can_q <= 6'd17);
    assign k_nrm_c  = P_can - 6'd18;
    // BUG-054: k_nrm_q (захват PH_NORM1A из k_nrm_c = P_can - 18) — все потребители
    // PH_NORM1B (финал ÷-барреля по k_nrm_q[5:3], corr_n1, sat_k, e_sum_next)
    // читают РЕГИСТР, а не комбинаторный p_can_q - 18: конус p_can_q -> fq_q
    // сокращён до 8:1-мукса по 3 битам селекта k_nrm_q[5:3] (FATAL -1.976, 32/16).
    assign sat_entry = (e_sum > 8'sd40);
    assign sat_k     = up_big &&
        (($signed({e_sum[7], e_sum}) + $signed({2'b00, k_nrm_q})) > 9'sd40);
    assign sat_norm  = sat_entry || sat_k;

    // ÷-баррель, стадия 1 (коарс: сдвиг на k_nrm[2:0] тритов, 0..7):
    // PH_NORM1A, от КОМБИНАТОРНЫХ |sum| (sum_abs_n1) и k_nrm_c[2:0] -> fq_mid_q.
    // BUG-051: разрез конуса sum_abs_q -> fq_q (6-бит селект 42x1-барреля).
    always_comb begin
        for (int t = 0; t < W; t++)
            fq_mid[2*t +: 2] = (t + k_nrm_c[2:0] <= W-1)
                             ? sum_abs_n1[2*(t + k_nrm_c[2:0]) +: 2] : 2'b00;
    end
    // ÷-баррель, стадия 2 (финал: досдвиг на 8·k_nrm[5:3] тритов): PH_NORM1B,
    // из ЗАРЕГИСТРИРОВАННЫХ fq_mid_q и k_nrm_q[5:3] -> fq_q. Конус k_nrm_q ->
    // fq_q сокращён до 8:1-мукса по 3 битам (было ~7 LUT-уровней барреля).
    // Итог: fq[t] = |sum|[t + k_nrm] — бит-в-бит прежний сдвиг (ретайминг на
    // две регистровые ступени: (t + 8·k_hi) + k_lo == t + k_nrm).
    always_comb begin
        logic [5:0] k_hi8;
        k_hi8 = {k_nrm_q[5:3], 3'b000};
        for (int t = 0; t < W; t++)
            fq[2*t +: 2] = (t + k_hi8 <= W-1)
                         ? fq_mid_q[2*(t + k_hi8) +: 2] : 2'b00;
    end
    // коррекция floor: старший ненулевой из отброшенных (t < k_nrm) == N1.
    // BUG-049: сканируются ОДИНОЧНЫЕ регистровые биты corr_nz_q/corr_i1_q
    // (захвачены в PH_NORM1A) — конус от sum_q до corr_n1_q отсутствует.
    // BUG-058: скан разрезан на ДВА такта. PH_NORM1B считает ТОЛЬКО гейт-
    // предикаты cg_c[t] = corr_nz_q[t] && (t < k_nrm_q) — сравнение t<k_nrm_q
    // это 1 LUT на трит (константный компаратор), без каскадной приоритетной
    // цепочки; скан по ОДНОБИТОВЫМ cg_q (структура как фазы NORM0A/NORM1B
    // приоритетных сканов) переехал в новую PH_NORM1B2 -> corr_n1_q. Путь
    // k_nrm_q -> corr_n1_q теряет 6-LUT каскад сравнений (WNS +0.030, 32/16).
    always_comb begin
        for (int t = 0; t < W; t++)
            cg_c[t] = corr_nz_q[t] && (32'(t) < 32'(k_nrm_q));
    end
    always_comb begin
        logic cf;
        cf = 1'b0; corr_n1 = 1'b0;
        for (int t = W-1; t >= 0; t--) begin
            if (!cf && cg_q[t]) begin
                cf = 1'b1;
                corr_n1 = corr_i1_q[t];
            end
        end
    end
    // тернарный декремент fq (borrow идёт по цепочке N1). Вынесен в ФУНКЦИЮ,
    // чтобы бит-в-бит тот же результат считать в PH_NORM1C от
    // ЗАРЕГИСТРИРОВАННОГО входа (fq_q, corr_n1_q) — разрез конуса
    // sum -> fq_dec_q (BUG-046). Функция идентична прежнему always_comb.
    function automatic logic [83:0] fq_dec_f(input logic [83:0] fq_in,
                                             input logic        corr_in);
        logic [1:0] borr;
        logic signed [2:0] sv;
        fq_dec_f = fq_in;
        borr   = corr_in ? N1 : 2'b00;
        for (int t = 0; t < W; t++) begin
            if (borr != 2'b00) begin
                sv = trit_val2(fq_dec_f[2*t +: 2]) + trit_val2(borr);
                if (sv < -1) begin
                    fq_dec_f[2*t +: 2] = P1;   // -2 -> +1, borrow дальше
                    borr = N1;
                end else begin
                    fq_dec_f[2*t +: 2] = int2trit2(sv);
                    borr = 2'b00;
                end
            end
        end
    endfunction

    // k_dn: мин(18-P, e_sum+40) для ×-барреля NORM2; сам ×-баррель
    // (dn_small) считается ИНЛАЙН в PH_NORM2 от sum_q/k_dn_q —
    // комбинаторный блок mul_y удалён как мёртвый (BUG-048).
    logic signed [8:0] room_dn;    // e_sum + 40
    logic [5:0]  need_dn;          // 18 - P (1..18 при P<=17)
    logic signed [8:0] k_dn_s;
    assign room_dn = $signed({e_sum[7], e_sum}) + 9'sd40;
    assign need_dn = 6'd18 - p_can_q;   // BUG-047: от зарегистрированной P
    always_comb begin
        if (!dn_small)
            k_dn_s = 9'sd0;
        else if (room_dn < $signed({2'b00, need_dn}))
            k_dn_s = (room_dn < 9'sd0) ? 9'sd0 : room_dn;
        else
            k_dn_s = $signed({2'b00, need_dn});
    end
    assign k_dn = k_dn_s[5:0];

    always_comb begin
        logic signed [8:0] es9;
        if (up_big)
            es9 = $signed({e_sum[7], e_sum}) + $signed({2'b00, k_nrm_q});
        else if (dn_small)
            es9 = $signed({e_sum[7], e_sum}) - $signed({3'b000, k_dn});
        else
            es9 = $signed({e_sum[7], e_sum});
        e_sum_next = es9[7:0];
    end

    // ---- FSM: фиксированные 15 тактов (BUG-045: PH_NORM разбит на 2 под-фазы;
    // BUG-046: PH_NORM1 разрезан на PH_NORM1A/PH_NORM1B — регистр
    // fq_q/corr_n1_q делил конус sum -> fq_dec_q на две стадии;
    // BUG-047: стадия 1 разрезана ещё раз, 10 -> 11 состояний;
    // BUG-048: ADD 3 секции -> 6 половин (+3 состояния) и сырые скан-флаги
    //   в PH_NORM0A (+1 состояние), 11 -> 15 состояний;
    // BUG-053: скан разрезан на 2 стадии (PH_NORM0A -> групповые признаки,
    //   + PH_NORM0B слияние), 15 -> 16 состояний;
    // BUG-056: ADD 3+4-под-фазы, 16 -> 22 состояния;
    // BUG-057: скан разрезан ЕЩЁ раз — под-группы SG=7 (PH_NORM0A) /
    //   слияние под-групп (PH_NORM0B) / слияние групп (PH_NORM0C), 22 -> 23
    //   состояния;
    // BUG-058: скан corr_n1 разрезан на гейт-биты cg_q (PH_NORM1B) и скан
    //   first-one (новая PH_NORM1B2), 23 -> 24 состояния, +1 такт) ----
    // PH_ADD0..PH_ADD11: 12 под-фаз по <=4 тритов (BUG-048: 6 половин по 7
    //   тритов; BUG-056: ещё раз пополам 3+4, +6 состояний) - переносы между
    //   половинами через carry0a_q/carry1a_q/carry2a_q, внутри половин через
    //   b0a_q..b2b_q (см. ADD выше).
    // PH_NORM0A: сырые ПОД-ГРУППОВЫЕ признаки sum (мини-сканы по SG=7 тритов,
    //   стадия 1a префикса BUG-057) -> регистры sg_*_q.
    // PH_NORM0B: слияние пар под-групп в ГРУППОВЫЕ атрибуты (стадия 1b
    //   BUG-057, 2-way приоритет из sg_*_q) -> регистры g_*_q.
    // PH_NORM0C: слияние групп сверху вниз (стадия 2 BUG-053) ->
    //   регистры p_found_q/p_top_q/sum_neg_q/rest_n1_q (бывш. BUG-048, разрез (b)).
    // PH_NORM1A: дешифровка P_can (из ЗАРЕГИСТРИРОВАННЫХ флагов), k_nrm_c,
    //   стадия 1 ÷-барреля (fq_mid из |sum| и k_nrm_c[2:0]), |sum| и per-trit
    //   флаги коррекции -> регистры zero_q/sum_q/p_can_q/k_nrm_q/fq_mid_q/
    //   corr_*_q (BUG-047..051)
    // PH_NORM1B: от ЗАРЕГИСТРИРОВАННЫХ входов: финал ÷-барреля (fq из fq_mid_q
    //   по k_nrm_q[5:3], BUG-051), гейт-биты cg_c (BUG-058: corr_nz_q[t] &&
    //   t<k_nrm_q), up_big/dn_small, k_dn, e_sum_next, sat_norm ->
    //   регистры fq_q/cg_q/up_big_q/dn_small_q/k_dn_q/e_sum_next_q/sat_q
    //   (вторая половина стадии 1; BUG-047, BUG-049)
    // PH_NORM1B2: скан first-one по ОДНОБИТОВЫМ cg_q -> corr_n1_q (BUG-058,
    //   разрез пути k_nrm_q -> fq_q, WNS +0.030 при 32/16)
    // PH_NORM1C: тернарный декремент fq_q (borrow-цепочка) -> fq_dec_q
    // PH_NORM2: инверсия знака (up_big) / ×-баррель (dn_small) + e_sum_next
    localparam int PH_IDLE = 0;
    localparam int PH_INIT = 1;
    localparam int PH_ALGN = 2;
    localparam int PH_ADD0 = 3;
    localparam int PH_ADD1 = 4;
    localparam int PH_ADD2 = 5;
    localparam int PH_ADD3 = 6;
    localparam int PH_ADD4 = 7;
    localparam int PH_ADD5 = 8;
    localparam int PH_ADD6 = 9;
    localparam int PH_ADD7 = 10;
    localparam int PH_ADD8 = 11;
    localparam int PH_ADD9 = 12;
    localparam int PH_ADD10 = 13;
    localparam int PH_ADD11 = 14;
    localparam int PH_NORM0A = 15;
    localparam int PH_NORM1A = 16;
    localparam int PH_NORM1B = 17;
    localparam int PH_NORM1B2 = 18;  // BUG-058: скан corr_n1 из гейт-бит cg_q (разрез k_nrm_q -> corr_n1_q)
    localparam int PH_NORM1C = 19;
    localparam int PH_NORM2 = 20;
    localparam int PH_DONE = 21;
    localparam int PH_NORM0B = 22;   // BUG-053: слияние групп скана; BUG-057: слияние под-групп (стадия 1b)
    localparam int PH_NORM0C = 23;   // BUG-057: слияние групп скана (стадия 2, бывш. PH_NORM0B)
    // (индексы 22/23 — после PH_DONE — чтобы не перенумеровывать остальные
    //  фазы; case-порядок не зависит от значений, переходы явные по фазе)

    logic [4:0] phase;   // 24 состояния (0..23) -> 5 бит (было 16 -> 4 бита)
    // ---- PH_NORM1A -> PH_NORM2: промежуточные регистры нормализации (BUG-045) ----
    logic [83:0] fq_dec_q;    // результат floor-деления (без инверсии знака)
    logic        up_big_q;    // P >= 19
    logic        dn_small_q;  // P <= 17
    logic [5:0]  k_dn_q;      // сдвиг влево (×3^k)
    logic signed [7:0] e_sum_next_q;
    // ---- PH_NORM1A -> PH_NORM1B: вход финальной дешифровки (BUG-046) ----
    logic [83:0] fq_q;        // ÷-баррель (до тернарного декремента)
    logic        corr_n1_q;   // коррекция floor (запускает borrow fq_dec)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE;
            m_big <= 0; m_small <= 0; m_big_e <= 0;
            e_sum <= 0; sum <= 0; result_q <= 0; valid_q <= 0;
            k_algn <= 0; zero_q <= 0; sat_q <= 0;
            carry_mid0_q <= 0; carry_mid1_q <= 0;
            carry0a_q <= 0; carry1a_q <= 0; carry2a_q <= 0;
            b0a_q <= 0; b0b_q <= 0; b1a_q <= 0; b1b_q <= 0; b2a_q <= 0; b2b_q <= 0;
            fq_q <= 0; corr_n1_q <= 0;
            sum_q <= 0; sum_neg_q <= 0; p_can_q <= 0;
            k_nrm_q <= 0;
            p_found_q <= 0; p_top_q <= 0; rest_n1_q <= 0;
            fq_mid_q <= 0; corr_nz_q <= 0; corr_i1_q <= 0;
            cg_q <= 0;
            g_nz_q <= 0; g_top_q <= 0; g_top_n1_q <= 0;
            g_rest_nz_q <= 0; g_rest_n1_q <= 0;
            sg_nz_q <= 0; sg_top_q <= 0; sg_top_n1_q <= 0;
            sg_rest_nz_q <= 0; sg_rest_n1_q <= 0;
        end else begin
            valid_q <= 0;
            case (phase)
                PH_IDLE: begin
                    if (valid_in) begin
                        if (za && zb) begin           // BUG-041: 0 + 0 = 0
                            m_big   <= 84'h0;
                            m_small <= 84'h0;
                            m_big_e <= 8'sd0;
                            k_algn  <= 5'd0;
                        end else if (za) begin        // BUG-041: 0 + b = norm(b), b — big вне зависимости от e
                            m_big   <= {2'b00, b_prod};
                            m_small <= 84'h0;
                            m_big_e <= b_e;
                            k_algn  <= 5'd0;
                        end else if (zb) begin        // BUG-041: a + 0 = norm(a)
                            m_big   <= {2'b00, a_prod};
                            m_small <= 84'h0;
                            m_big_e <= a_e;
                            k_algn  <= 5'd0;
                        end else if (a_e > b_e) begin
                            m_big   <= {2'b00, a_prod};
                            m_small <= {2'b00, b_prod};
                            m_big_e <= a_e;
                            k_algn <= k_algn_c;
                        end else begin
                            m_big   <= {2'b00, b_prod};
                            m_small <= {2'b00, a_prod};
                            m_big_e <= b_e;
                            k_algn <= k_algn_c;
                        end
                        phase <= PH_INIT;
                    end
                end
                PH_INIT: begin
                    e_sum <= m_big_e;
                    phase <= PH_ALGN;
                end
                PH_ALGN: begin
                    m_small <= algn_y;      // баррель выравнивания, 1 такт
                    phase <= PH_ADD0;
                end
                PH_ADD0: begin
                    sum[5:0]        <= add_r0a1[5:0];       // триты 0..2
                    b0a_q           <= b0a;
                    phase <= PH_ADD1;
                end
                PH_ADD1: begin
                    sum[13:6]       <= add_r0a2[7:0];       // триты 3..6
                    carry0a_q       <= carry0a;
                    phase <= PH_ADD2;
                end
                PH_ADD2: begin
                    sum[19:14]      <= add_r0b1[5:0];       // триты 7..9
                    b0b_q           <= b0b;
                    phase <= PH_ADD3;
                end
                PH_ADD3: begin
                    sum[27:20]      <= add_r0b2[7:0];       // триты 10..13
                    carry_mid0_q    <= carry_mid0;
                    phase <= PH_ADD4;
                end
                PH_ADD4: begin
                    sum[33:28]      <= add_r1a1[5:0];       // триты 14..16
                    b1a_q           <= b1a;
                    phase <= PH_ADD5;
                end
                PH_ADD5: begin
                    sum[41:34]      <= add_r1a2[7:0];       // триты 17..20
                    carry1a_q       <= carry1a;
                    phase <= PH_ADD6;
                end
                PH_ADD6: begin
                    sum[47:42]      <= add_r1b1[5:0];       // триты 21..23
                    b1b_q           <= b1b;
                    phase <= PH_ADD7;
                end
                PH_ADD7: begin
                    sum[55:48]      <= add_r1b2[7:0];       // триты 24..27
                    carry_mid1_q    <= carry_mid1;
                    phase <= PH_ADD8;
                end
                PH_ADD8: begin
                    sum[61:56]      <= add_r2a1[5:0];       // триты 28..30
                    b2a_q           <= b2a;
                    phase <= PH_ADD9;
                end
                PH_ADD9: begin
                    sum[69:62]      <= add_r2a2[7:0];       // триты 31..34
                    carry2a_q       <= carry2a;
                    phase <= PH_ADD10;
                end
                PH_ADD10: begin
                    sum[75:70]      <= add_r2b1[5:0];       // триты 35..37
                    b2b_q           <= b2b;
                    phase <= PH_ADD11;
                end
                PH_ADD11: begin
                    sum[83:76]      <= add_r2b2[7:0];       // триты 38..41
                    phase <= PH_NORM0A;
                end
                PH_NORM0A: begin
                    // BUG-057 стадия 1a: захват «сырых» ПОД-ГРУППОВЫХ признаков
                    // sum. NSG независимых параллельных мини-сканов по SG=7
                    // тритов (глубина ~2-3 LUT) — конус sum_reg -> sg_*_q
                    // вдвое короче прежнего 14-тритного (был WNS -0.342 при
                    // 32/16, endpoint g_top_q_reg); слияния уехали в
                    // PH_NORM0B (под-группы -> группы) и PH_NORM0C (группы -> итог).
                    sg_nz_q      <= sg_nz;
                    sg_top_q     <= sg_top;
                    sg_top_n1_q  <= sg_top_n1;
                    sg_rest_nz_q <= sg_rest_nz;
                    sg_rest_n1_q <= sg_rest_n1;
                    phase <= PH_NORM0B;
                end
                PH_NORM0B: begin
                    // BUG-057 стадия 1b: слияние пар под-групп в ГРУППОВЫЕ
                    // атрибуты из ЗАРЕГИСТРИРОВАННЫХ sg_*_q (2-way приоритет,
                    // глубина ~2 LUT) -> g_*_q. Значения групп бит-в-бит те же,
                    // что давал прежний мини-скан по G=14 тритов (ассоциативная
                    // префиксная композиция, как в BUG-053).
                    g_nz_q      <= g_nz;
                    g_top_q     <= g_top;
                    g_top_n1_q  <= g_top_n1;
                    g_rest_nz_q <= g_rest_nz;
                    g_rest_n1_q <= g_rest_n1;
                    phase <= PH_NORM0C;
                end
                PH_NORM0C: begin
                    // BUG-053 стадия 2 (бывш. PH_NORM0B): слияние групп сверху
                    // вниз (3-way приоритет из ЗАРЕГИСТРИРОВАННЫХ g_*_q,
                    // глубина ~2 LUT) -> те же финальные сканы, что старая
                    // PH_NORM0A (BUG-048, разрез (b)) брала прямо от sum;
                    // дешифровка P_can по-прежнему в PH_NORM1A.
                    p_found_q <= p_found;
                    p_top_q   <= p_top;
                    sum_neg_q <= sum_neg;
                    rest_n1_q <= rest_n1;
                    phase <= PH_NORM1A;
                end
                PH_NORM1A: begin
                    // разрез 1 (BUG-046) + BUG-047 + BUG-048: дешифровка P_can из
                    // ЗАРЕГИСТРИРОВАННЫХ флагов (p_found_q/p_top_q/rest_n1_q из
                    // PH_NORM0C) — конус от sum_reg до p_can_q/zero_q является
                    // ТОЛЬКО дешифровкой (2-3 LUT). BUG-052: k_nrm_q удалён,
                    // вычитание -18 ушло в PH_NORM1B от регистра p_can_q.
                    zero_q    <= !p_found_q;
                    sum_q     <= sum;
                    p_can_q   <= P_can;
                    // BUG-049 + BUG-051: |sum| (sum_abs_n1) и per-trit флаги
                    // коррекции считаются и РЕГИСТРИРУЮТСЯ здесь (от комбинаторного
                    // sum + sum_neg_q) — corr_n1_q в PH_NORM1B выбирается только
                    // из этих регистров; стадия 1 ÷-барреля (сдвиг на k[2:0])
                    // регистрируется в fq_mid_q (вместо отдельного sum_abs_q).
                    corr_nz_q   <= corr_nz;
                    corr_i1_q   <= corr_i1;
                    fq_mid_q    <= fq_mid;
                    // BUG-054: k_nrm_q <= k_nrm_c (= P_can - 18, тот же такт, что
                    // fq_mid_q) — стадии 1/2 ÷-барреля согласованы (k_nrm_q ==
                    // k_nrm_c, как при BUG-051); PH_NORM1B читает только регистр.
                    k_nrm_q     <= k_nrm_c;
                    phase <= PH_NORM1B;
                end
                PH_NORM1B: begin
                    // разрез 2 (BUG-047) + BUG-051: ВТОРАЯ половина стадии 1 —
                    // финал ÷-барреля (fq из fq_mid_q по k_nrm_q[5:3]), коррекция
                    // floor (corr_n1), флаги, k_dn, e_sum_next и sat_norm считаются
                    // из зарегистрированных входов (fq_mid_q/sum_q/corr_nz_q/
                    // corr_i1_q/k_nrm_q/e_sum):
                    // corr_n1 — приоритетный скан ОДИНОЧНЫХ бит (BUG-049), а не
                    // от sum_q через слой |sum|; каждый endpoint стадии 1
                    // (fq_q/corr_n1_q/up_big_q/dn_small_q/k_dn_q/e_sum_next_q/
                    // sat_q) получает вход сразу за регистром.
                    sat_q <= sat_norm;
                    up_big_q    <= up_big;
                    dn_small_q  <= dn_small;
                    k_dn_q      <= k_dn;
                    e_sum_next_q <= e_sum_next;
                    fq_q        <= fq;
                    // BUG-058: corr_n1 НЕ вычисляется здесь (каскад сравнений
                    // t<k_nrm_q перенесён в одиночные гейт-биты cg_c/q, скан
                    // коррекции -> corr_n1_q уехал в новую PH_NORM1B2).
                    cg_q        <= cg_c;
                    phase <= PH_NORM1B2;
                end
                PH_NORM1B2: begin
                    // BUG-058: приоритетный скан ОДНОБИТОВЫХ гейт-предикатов
                    // cg_q (corr_nz_q[t] && t < k_nrm_q, захвачен в PH_NORM1B) ->
                    // corr_n1_q. Структура — как NORM0-сканы (цепочка first-one
                    // по 1-бит флагам, ~2-3 LUT), конус k_nrm_q -> corr_n1_q
                    // сокращён с ~6 LUT до 1 LUT (гейт-предикат cg_c).
                    corr_n1_q   <= corr_n1;
                    phase <= PH_NORM1C;
                end
                PH_NORM1C: begin
                    // разрез 3 (BUG-046, перенесён сюда): тернарный декремент fq_q
                    // (borrow-цепочка 42 тритов) — бит-в-бит то же значение fq_dec,
                    // что считал прежний комбинаторный блок, из зарегистрированного
                    // входа (fq_q из PH_NORM1B, corr_n1_q из PH_NORM1B2).
                    fq_dec_q <= fq_dec_f(fq_q, corr_n1_q);
                    phase <= PH_NORM2;
                end
                PH_NORM2: begin
                    if (!sat_q) begin
                        if (up_big_q) begin
                            // инверсия и запись fq_dec
                            for (int t = 0; t < W; t++) begin
                                logic [1:0] tv;
                                tv = sum_neg_q ? ((fq_dec_q[2*t +: 2] == P1) ? N1 :
                                    (fq_dec_q[2*t +: 2] == N1) ? P1 : 2'b00) : fq_dec_q[2*t +: 2];
                                sum[2*t +: 2] <= tv;
                            end
                            e_sum <= e_sum_next_q;
                        end else if (dn_small_q && k_dn_q != 0) begin
                            for (int t = 0; t < W; t++) begin
                                logic [1:0] tv;
                                tv = (32'(t) >= 32'(k_dn_q)) ? sum_q[2*(t - k_dn_q) +: 2] : 2'b00;
                                sum[2*t +: 2] <= tv;
                            end
                            e_sum <= e_sum_next_q;
                        end
                        // elif sum == 0 / P==18: sum не меняем
                    end
                    phase <= PH_DONE;
                end
                PH_DONE: begin
                    if (zero_q)
                        result_q <= 48'h0;
                    else if (sat_q)
                        result_q <= {8'hFF, 40'hFFFFFFFFFF};
                    else if (e_sum < -8'sd40)
                        result_q <= 48'h0;
                    else
                        result_q <= {exp_code(e_sum), sum[39:0]};
                    valid_q <= 1;
                    phase <= PH_IDLE;
                end
                default: phase <= PH_IDLE;
            endcase
        end
    end

    assign valid_out = valid_q;
    assign result    = result_q;

endmodule
