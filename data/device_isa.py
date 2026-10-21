#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""device_isa.py — битовый ISA-компилятор + интерпретатор device-side программ (2026-10-21).

Роль: БИТ-ТОЧНАЯ функциональная модель «данные + программа = результат» на уровне
ISA, описанного в docs/device-isa-2026-10-20.md. Хост готовит ПРОГРАММУ — таблицу
32-байтных юнитов в DRAM, пишет только ARG0..ARG7 + RUN; устройство само крутит
линейную цепочку юнитов (каждый юнит = линейный слой, повторяемый `pass` раз),
а в конце пишет одно status-слово в completion-mailbox (WAITW-аналог). FPGA-ядро
tdot здесь представлено БИТ-В-БИТ: каждый линейный слой сводится к dot-per-output-neuron,
и каждый нейрон считается в TFloat48 (тернарная арифметика) по попарному бинарному
дереву сложения — ровно как RTL compute_dot_par_raw (эталон rtl/integration/
verify_tdot_axi4.dot_ref_raw). Эти примитивы (tfmul_raw / tfadd_raw) реализованы
здесь самодостаточно и сверяются с RTL-симуляцией
(C:\\Temp\\gigatool\\devprog_integ, tb_integ1) — 7/7, 0 несовпадений.

Два режима:
  mode="tf48"  (ПО УМОЛЧАНИЮ) — бит-точно к RTL device_prog: каждый dot-нейрон —
      TFloat48, РЕЗУЛЬТАТ — 48-битные слова (numpy int64). Воспроизводится
      in-place feed-forward: при pass>1 выходной буфер юнита перечитывается на
      следующий проход и обновляется по-нейронно в реальном времени (как делает
      устройство: задача нейрона J видит уже записанные результаты нейронов
      0..J-1 в том же проходе).
  mode="float" — прежняя numpy float32-семантика (cur @ W + b + relu, матричное
      умножение БЕЗ in-place). Сохраняется для совместимости со старыми
      numpy-эталонами (devseq / nn_audio_common.forward_batch cpu) и НЕ бит-точна
      к железу.

numpy-only (проект numpy-only). Все функции импортируются без железа (эмуляция).
Арифметика TFloat48 заимствована из ternary_sw/block (tfloat48.TFloat + arith48),
а бит-точные примитивы tfmul/tfadd — из rtl/integration/verify_tdot_axi4.dot_ref_raw.

ИЗВЕСТНОЕ РАСХОЖДЕНИЕ (b_en/relu): на тернарном RTL (device_prog) bias и relu НЕ
потребляются — юнит полностью игнорирует b_en/relu. Режим mode="tf48" воспроизводит
это ЖЕЛЕЗНЫМ способом: биты b_en/relu НЕ влияют на результат. Поэтому программа,
где b_en=1 или relu=1, НЕ даст математических «cur@W+b, затем relu» — на железе
bias/relu просто не применяются. Это будущий апгрейд RTL; сейчас mode="tf48" честно
НЕ моделирует bias/relu как «совпадает с железом» — бит-точность гарантируется только
для программ с b_en=0/relu=0. Для математических bias/relu используйте mode="float".

Версия 1.1.0 (2026-10-21): добавлен mode="tf48" — бит-точный к RTL TFloat48-интерпретатор
(по умолчанию); mode="float" оставлен как совместимость со старым numpy-поведением.
"""
from __future__ import annotations
import os
import sys
import struct
import numpy as np

# --- путь к троичному эмулятору (ternary_sw/block): TFloat48 + arith48 ---
_TERN = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                      "..", "ternary_sw"))
if _TERN not in sys.path:
    sys.path.insert(0, _TERN)

from block.tfloat48 import TFloat
from block import arith48
import block.trits as _trit_pack

__version__ = "1.1.0"

UNIT_BYTES = 32          # ровно 8 x 32-битных слов, little-endian
NUM_ARGS = 8             # ARG0..ARG7
MAX_PASS = 255           # pass в 8 битах

# Назначение ARG-регистров по умолчанию (смещения от карты §6, host-side offsets).
ARG_PROG = 0             # база таблицы программы (юниты) в DRAM
ARG_DATA = 1             # база входного батча данных
ARG_RESULT = 2           # база области результатов
ARG_WEIGHTS = 3          # база резидентных весов
ARG_COMP = 4             # completion-mailbox (одно status-слово)
ARG_LOOP = 5             # свободный (может служить счётчиком LOOP извне)
ARG_FREE6 = 6
ARG_FREE7 = 7

# Реалистичные значения по умолчанию (docs/ADDRESS_MAP.md §6):
DEFAULT_ARGS = {
    ARG_PROG: 0x0010_0000,      # 1 MiB desc-зона — под таблицу программы
    ARG_DATA: 0x0020_0000,      # 4 MiB data-слоты
    ARG_WEIGHTS: 0x0060_0000,   # 4 MiB weights-слоты (резидентные веса)
    ARG_RESULT: 0x00A0_0000,    # 2 KB results
    ARG_COMP: 0x0011_0000,      # 16 KB completion-область
    5: 0, 6: 0, 7: 0,
}

STATUS_DONE = 0x00000001        # бит0 = готово, программа завершена OK
STATUS_ERR = 0xDEADBEEF         # фатальная ошибка интерпретации (reserved сем.)

# ---------------------------------------------------------------------------
# Битовый формат 32-байтного юнита (LE). Позиция = (номер 32-битного слова, сдвиг, ширина).
# Слово 0: n_in | n_out<<16
# Слово 1: pass | relu<<8 | b_en<<9 | src<<10 | tag<<16
# Слово 2: w_reg | w_imm<<4          (адрес весов   = ARG[w_reg]  + w_imm)
# Слово 3: b_reg | b_imm<<4          (адрес bias    = ARG[b_reg]  + b_imm)
# Слово 4: o_reg | o_imm<<4          (адрес вывода  = ARG[o_reg]  + o_imm)
# Слова 5..7: резерв (0)
# src: 0 = data (вход автономного батча), 1 = prev (выход предыдущего юнита)
# ---------------------------------------------------------------------------
FIELD = {
    'n_in':   (0, 0, 16),
    'n_out':  (0, 16, 16),
    'pass':   (1, 0, 8),
    'relu':   (1, 8, 1),
    'b_en':   (1, 9, 1),
    'src':    (1, 10, 1),
    'tag':    (1, 16, 16),
    'w_reg':  (2, 0, 4),
    'w_imm':  (2, 4, 28),
    'b_reg':  (3, 0, 4),
    'b_imm':  (3, 4, 28),
    'o_reg':  (4, 0, 4),
    'o_imm':  (4, 4, 28),
}
_SRC_DATA, _SRC_PREV = 0, 1


def normalize_unit(unit):
    """Привести юнит к каноническому dict со всеми ISA-полями (src→int)."""
    u = dict(unit)
    u.setdefault('n_in', 0)
    u.setdefault('n_out', 0)
    u.setdefault('pass', 1)
    u.setdefault('relu', 0)
    u.setdefault('b_en', 1)
    u.setdefault('tag', 0)
    src = u.get('src', 'prev')
    if isinstance(src, str):
        s = src.strip().lower()
        if s in ('data', 'd'):
            src = _SRC_DATA
        elif s in ('prev', 'chain', 'p'):
            src = _SRC_PREV
        else:
            raise ValueError(f"src должен быть 'data'|'prev', получено {src!r}")
    u['src'] = int(src)
    u.setdefault('w_reg', ARG_WEIGHTS)
    u.setdefault('w_imm', 0)
    u.setdefault('b_reg', ARG_WEIGHTS)
    u.setdefault('b_imm', 0)
    u.setdefault('o_reg', ARG_RESULT)
    u.setdefault('o_imm', 0)
    return u


def make_unit(n_in, n_out, w_reg=ARG_WEIGHTS, w_imm=0, b_reg=ARG_WEIGHTS,
              b_imm=0, o_reg=ARG_RESULT, o_imm=0, passes=1, relu=False,
              b_en=True, src='prev', tag=0):
    """Собрать юнит-описание в канонической пред-битовой форме (как devseq.make_unit)."""
    return {
        'n_in': int(n_in), 'n_out': int(n_out), 'pass': int(passes),
        'relu': int(relu), 'b_en': int(b_en), 'src': src, 'tag': int(tag),
        'w_reg': int(w_reg), 'w_imm': int(w_imm),
        'b_reg': int(b_reg), 'b_imm': int(b_imm),
        'o_reg': int(o_reg), 'o_imm': int(o_imm),
    }


def _unit_words(unit):
    u = normalize_unit(unit)
    words = [0] * 8
    for key, (wi, sh, w) in FIELD.items():
        v = int(u[key]) & ((1 << w) - 1)
        words[wi] |= v << sh
    return words


def bits(unit) -> bytes:
    """Компилятор одного юнита в 32 байта (little-endian)."""
    return struct.pack('<8I', *_unit_words(unit))


def compile_program(units) -> bytes:
    """Компилятор ПРОГРАММЫ: конкатенация битов юнитов в одну таблицу DRAM."""
    if isinstance(units, (bytes, bytearray)):
        return bytes(units)
    out = bytearray()
    for u in units:
        out += bits(u)
    return bytes(out)


def parse_unit(b) -> dict:
    """Разобрать 32-байтный юнит обратно в dict (поле src — int)."""
    if len(b) != UNIT_BYTES:
        raise ValueError(f"юнит должен быть ровно {UNIT_BYTES} байт, получено {len(b)}")
    words = struct.unpack('<8I', b)
    u = {}
    for key, (wi, sh, w) in FIELD.items():
        u[key] = (words[wi] >> sh) & ((1 << w) - 1)
    return u


def parse(program) -> list:
    """Разобрать таблицу программы (байты) в список юнитов-словарей."""
    if not isinstance(program, (bytes, bytearray)):
        program = compile_program(program)
    n = len(program)
    if n % UNIT_BYTES:
        raise ValueError(f"длина программы {n} не кратна {UNIT_BYTES}")
    return [parse_unit(program[i:i + UNIT_BYTES]) for i in range(0, n, UNIT_BYTES)]


# ---------------------------------------------------------------------------
# TFloat48 — бит-точные примитивы tfmul/tfadd + dot (эталон RTL compute_dot_par_raw).
# Копия логики rtl/integration/verify_tdot_axi4.dot_ref_raw: НЕ каноника arith48,
# а изменённое RTL-поведение нормализации (_norm_rtl_sum со знакомым сканом sum;
# сдвиг выравнивания _shift_seq сбросом младших тритов; 40-тритная обрезка произведения
# _raw_mul). Позволяет неканоническую мантиссу на выходе — как железо.
# ---------------------------------------------------------------------------

def _tf_to_bits48(t: TFloat) -> int:
    """TFloat -> 48-битное слово (E в старшем байте, M в младших 40 битах)."""
    return ((t.e_int & 0xFF) << 40) | (t.m_int & ((1 << 40) - 1))


def _tf_to_trits(v: int, n: int):
    out = [0] * n
    x = v
    for i in range(n):
        r = x % 3
        x //= 3
        if r == 2:
            r = -1
            x += 1
        out[i] = r
    return out


def _tf_from_trits(ts):
    v = 0
    for t in reversed(ts):
        v = v * 3 + t
    return v


def _tf_shift_seq(m, k, W=42):
    """Баррель выравнивания tfadd_raw: сдвиг вправо на k тритов СБРОСОМ младших."""
    k = min(k, 22)
    if k <= 0:
        return m
    ts = _tf_to_trits(m, W)
    return _tf_from_trits(ts[k:] + [0] * k)


def _tf_trunc20(v):
    """Низкие 20 тритов значения v (RTL: результат = sum[39:0])."""
    return _tf_from_trits(_tf_to_trits(v, 60)[0:20])


def _tf_norm_rtl_sum(v, e_sum):
    """ТОЧНАЯ копия нормализации tfadd_raw (знаковый скан sum, без |sum|)."""
    ts = _tf_to_trits(v, 42)
    if not any(t != 0 for t in ts):
        return (0, 0)
    p_top = None
    sneg = 0
    for t in range(41, -1, -1):
        if ts[t] != 0:
            p_top = t
            sneg = (ts[t] == -1)
            break
    rest_n1 = 0
    for t in range(p_top - 1, -1, -1):
        if ts[t] != 0:
            rest_n1 = (ts[t] == -1)
            break
    P_can = 0 if p_top == 0 else (p_top - (1 if rest_n1 else 0))
    if e_sum > 40 or (P_can >= 19 and e_sum + (P_can - 18) > 40):
        return (None, None)
    if e_sum < -40:
        return (0, 0)
    t_abs = [-t if sneg else t for t in ts]
    m_abs = _tf_from_trits(t_abs)
    if P_can >= 19:
        k = P_can - 18
        hi_drop = 0
        for i in range(k - 1, -1, -1):
            if t_abs[i] != 0:
                hi_drop = t_abs[i]
                break
        fq = _tf_from_trits(t_abs[k:] + [0] * k)
        if hi_drop == -1:
            fq -= 1
        m_out = -fq if sneg else fq
        e_out = e_sum + k
    elif P_can <= 17:
        k_dn = 18 - P_can
        room = e_sum + 40
        k_dn_c = room if room < k_dn else k_dn
        if k_dn_c < 0:
            k_dn_c = 0
        if k_dn_c:
            m_out = v * (3 ** k_dn_c)
            e_out = e_sum - k_dn_c
        else:
            m_out = v
            e_out = e_sum
    else:
        m_out = v
        e_out = e_sum
    return (_tf_trunc20(m_out), e_out)


def _tf_raw_mul(a: TFloat, b: TFloat):
    """RTL tfmul_raw: произведение мантисс, обрезанное до 40 тритов."""
    ma = int(arith48._trits_value(arith48._m_trits(a)))
    mb = int(arith48._trits_value(arith48._m_trits(b)))
    ea = arith48._e_raw(a)
    eb = arith48._e_raw(b)
    p = _tf_from_trits(_tf_to_trits(ma * mb, 80)[0:40])
    return (p, ea + eb - 18)


def _tf_raw_add(pa, ea, pb, eb):
    """RTL tfadd_raw: выравнивание сдвигом, сложение, RTL-нормализация."""
    if pa == 0:
        return _tf_norm_rtl_sum(pb, eb)
    if pb == 0:
        return _tf_norm_rtl_sum(pa, ea)
    if ea > eb:
        pb = _tf_shift_seq(pb, ea - eb)
        e = ea
    elif eb > ea:
        pa = _tf_shift_seq(pa, eb - ea)
        e = eb
    else:
        e = ea
    return _tf_norm_rtl_sum(pa + pb, e)


def _tf_bits_to_tf(b: int) -> TFloat:
    return TFloat.from_bits(((b & ((1 << 40) - 1)) << 8) | ((b >> 40) & 0xFF))


def _tf_pack_raw(m20, e) -> int:
    """Упаковать (мант., эксп.) в 48 бит БЕЗ повторной нормализации — как RTL
    output = {exp_code(e_sum), sum[39:0]}."""
    m_trits = arith48._round_int_to_trits(m20)
    e_trits = arith48._encode_exp(e)
    return _tf_to_bits48(TFloat(_trit_pack.pack(m_trits), _trit_pack.pack(e_trits)))


def dot_ref_raw(vals_a, vals_b):
    """Бит-точный эталон tdot-dot: vals_a/vals_b — списки 48-битных TFloat48 слов,
    возвращает 48-битное итоговое слово. Попарное бинарное дерево сложения."""
    a = [_tf_bits_to_tf(v) for v in vals_a]
    b = [_tf_bits_to_tf(v) for v in vals_b]
    products = [_tf_raw_mul(x, y) for x, y in zip(a, b)]
    while len(products) > 1:
        nxt = []
        for i in range(0, len(products) - 1, 2):
            nxt.append(_tf_raw_add(products[i][0], products[i][1],
                                   products[i + 1][0], products[i + 1][1]))
        if len(products) % 2 == 1:
            nxt.append(products[-1])
        products = nxt
    m, e = products[0]
    if m == 0 and e == 0:
        return 0
    return _tf_pack_raw(m, e)


# ---------------------------------------------------------------------------
# Функциональная модель
# ---------------------------------------------------------------------------
def _tf48_rows_from_matrix(mat: np.ndarray) -> list:
    """(B, N) float32 -> список построчно списков 48-битных TFloat48 слов."""
    out = []
    for row in mat:
        out.append([_tf_to_bits48(TFloat.from_float(float(v))) for v in row])
    return out


def _tf48_weight_vectors(W: np.ndarray) -> list:
    """(n_in, n_out) float32 -> список per-нейрон строк весов (по n_in слов)."""
    Wf = np.asarray(W, dtype=np.float32)
    n_in, n_out = Wf.shape
    return [[_tf_to_bits48(TFloat.from_float(float(Wf[i, j]))) for i in range(n_in)]
            for j in range(n_out)]


def _dot_neuron_tf48(src, n_in, wrow) -> int:
    """Один dot-нейрон TFloat48: вход src (буфер), читаем n_in слов (с добором нулей),
    попарное дерево произведения с весовой строкой wrow."""
    m = len(src)
    if m >= n_in:
        inp = src[:n_in]
    else:
        inp = src + [0] * (n_in - m)
    return dot_ref_raw(inp, wrow)


def linear_pass(cur, W, b=None, relu=False, mode="float"):
    """Один проход линейного слоя.

    mode="float" (по умолч.) — старый numpy: cur @ W + b, опц. relu (как devseq).
    mode="tf48" — ТЕРНАРНО-бит-точный: каждый выходной нейрон = dot_ref_raw по
        TFloat48 (попарное дерево). b/relu в tf48 ИГНОРИРУЮТСЯ (на железе их нет —
        см. док-строку модуля о расхождении). Возвращает (B, n_out) int64 — 48-битные слова.
    """
    if mode == "float":
        out = cur @ W
        if b is not None:
            out = out + b
        if relu:
            out = np.maximum(0.0, out)
        return out
    curf = np.asarray(cur, dtype=np.float32)
    n_out = int(np.asarray(W).shape[1])
    wrows = _tf48_weight_vectors(W)
    rows = []
    nin = int(curf.shape[1])
    for s in range(curf.shape[0]):
        r48 = [_tf_to_bits48(TFloat.from_float(float(curf[s, i]))) for i in range(nin)]
        rows.append([_dot_neuron_tf48(r48, nin, wrows[j]) for j in range(n_out)])
    return np.array(rows, dtype=np.int64)


def _addr(args, reg, imm):
    return (int(args.get(reg, 0)) + int(imm)) & 0xFFFFFFFF


def _coerce_units(program):
    if isinstance(program, (bytes, bytearray)):
        return parse(program)
    return [normalize_unit(u) for u in program]


def _chain_tf48(cur_iter, units, weights48):
    """Прогнать цепочку юнитов в tf48 по каждому образцу батча отдельно.

    cur_iter — список (по образцам) списков входных 48-битных слов.
    weights48 — {tag: список per-нейрон строк весов}.
    Возвращает список (по образцам) списков 48-битных слов выхода ПОСЛЕДНЕГО юнита.
    in-place: для pass>1 выходной буфер юнита перечитывается на следующий проход и
    обновляется по-нейронно (нейрон J видит уже записанные нейроны 0..J-1).
    """
    results = []
    for row in cur_iter:
        prev_out = None
        for u in units:
            n_in = int(u['n_in'])
            n_out = int(u['n_out'])
            pas = int(u['pass'])
            s = int(u['src'])
            src0 = row if s == _SRC_DATA else (prev_out if prev_out is not None else row)
            wrows = weights48[int(u['tag'])]
            out_buf = [0] * n_out
            for p in range(pas):
                src = src0 if p == 0 else out_buf
                for j in range(n_out):
                    out_buf[j] = _dot_neuron_tf48(src, n_in, wrows[j])
            prev_out = out_buf
        if prev_out is None:
            prev_out = list(row)
        results.append(prev_out)
    return results


def run_chain(data, units, weights, args, mode="float"):
    """Прогнать цепочку юнитов.

    mode="float" — прежняя numpy-семантика с bias/relu (без in-place).
    mode="tf48" — бит-точно к RTL. b/relu игнорируются. Возвращает
    (результат, trace); в tf48 результат — np.int64 (B, n_out_last) 48-битных слов.
    """
    if mode == "float":
        args = dict(args)
        cur = np.asarray(data, dtype=np.float32)
        trace = []
        for u in units:
            pas = int(u['pass'])
            if pas > 1 and int(u['n_in']) != int(u['n_out']):
                raise ValueError(f"pass={pas}>1 требует квадратного слоя "
                                 f"(n_in==n_out), получено {u['n_in']}->{u['n_out']}")
            waddr = _addr(args, u['w_reg'], u['w_imm'])
            baddr = _addr(args, u['b_reg'], u['b_imm'])
            oaddr = _addr(args, u['o_reg'], u['o_imm'])
            W, b = weights[u['tag']]
            use_b = bool(u['b_en'])
            relu = bool(u['relu'])
            first_input_is_data = (u['src'] == _SRC_DATA)
            for p in range(pas):
                if p == 0:
                    inp = np.asarray(data, dtype=np.float32) if first_input_is_data else cur
                else:
                    inp = cur
                cur = linear_pass(inp, W, b if use_b else None, relu, mode="float")
            trace.append({'tag': int(u['tag']), 'w_addr': waddr, 'b_addr': baddr,
                          'out_addr': oaddr, 'pass': pas})
        return cur, trace
    # ---- tf48 ----
    cur_iter = _tf48_rows_from_matrix(np.asarray(data, dtype=np.float32))
    weights48 = {int(t): _tf48_weight_vectors(np.asarray(w, dtype=np.float32))
                 for t, (w, b) in weights.items()}
    out_iter = _chain_tf48(cur_iter, units, weights48)
    width = max((len(r) for r in out_iter), default=0)
    arr = np.zeros((len(out_iter), width), dtype=np.int64)
    for i, r in enumerate(out_iter):
        arr[i, :len(r)] = np.array(r, dtype=np.int64)
    trace = [{'tag': int(u['tag']),
              'w_addr': _addr(args, u['w_reg'], u['w_imm']),
              'b_addr': _addr(args, u['b_reg'], u['b_imm']),
              'out_addr': _addr(args, u['o_reg'], u['o_imm']),
              'pass': int(u['pass'])} for u in units]
    return arr, trace


def run_program(data, program, weights, args=None, mode="tf48"):
    """Интерпретатор: данные + программа -> результат батча.

    data — (B, in0) float32; program — список юнитов ИЛИ байты таблицы;
    weights — {tag: (W, b)} float32 (W: (n_in, n_out)); args — dict ARG-регистров
    (int-ключи 0..7) + служебные: args['repeat'] — целочисленный LOOP всей цепочки.

    mode="tf48" (по умолч.): результат — (B, n_out_last) int64 — 48-битные TFloat48
        слова, бит-точно к RTL device_prog (для b_en=0/relu=0; см. расхождение в
        док-строке модуля). Каждый образец батча = отдельное выполнение программы
        (независимые буферы), как делает устройство на одном сэмпле.
    mode="float": прежний numpy float32 (bias/relu есть, in-place нет).
    """
    units = _coerce_units(program)
    user = args or {}
    args = dict(DEFAULT_ARGS)
    args.update(user)
    repeat = int(args.pop('repeat', 1))
    if mode == "float":
        cur = np.asarray(data, dtype=np.float32)
        for _ in range(repeat):
            cur, _ = run_chain(cur, units, weights, args, mode="float")
        return cur
    # tf48
    cur_iter = _tf48_rows_from_matrix(np.asarray(data, dtype=np.float32))
    weights48 = {int(t): _tf48_weight_vectors(np.asarray(w, dtype=np.float32))
                 for t, (w, b) in weights.items()}
    for _ in range(repeat):
        cur_iter = _chain_tf48(cur_iter, units, weights48)
    width = max((len(r) for r in cur_iter), default=0)
    arr = np.zeros((len(cur_iter), width), dtype=np.int64)
    for i, r in enumerate(cur_iter):
        arr[i, :len(r)] = np.array(r, dtype=np.int64)
    return arr


def run_program_trace(data, program, weights, args=None, mode="tf48"):
    """Как run_program, но возвращает (результат, trace) — для RTL-сверки адресов."""
    user = args or {}
    args = dict(DEFAULT_ARGS)
    args.update(user)
    repeat = int(args.get('repeat', 1))
    result = run_program(data, program, weights, dict(args), mode=mode)
    units = _coerce_units(program)
    unit_trace = [{'tag': int(u['tag']),
                   'w_addr': _addr(args, u['w_reg'], u['w_imm']),
                   'b_addr': _addr(args, u['b_reg'], u['b_imm']),
                   'out_addr': _addr(args, u['o_reg'], u['o_imm']),
                   'pass': int(u['pass'])} for u in units]
    return result, [unit_trace] * repeat


def run_program_mb(data, program, weights, args=None, mode="tf48"):
    """Как run_program, но с completion-mailbox-семантикой.

    Возвращает (результат, completion), где completion = {'addr', 'word'}:
    addr — адрес status-слова в DRAM (по умолчанию ARG[comp_reg]);
    word — записанное status-слово (бит0=DONE). args['status'] переопределяет слово.
    """
    user = args or {}
    args = dict(DEFAULT_ARGS)
    args.update(user)
    result = run_program(data, program, weights, args, mode=mode)
    comp_reg = int(args.get('comp_reg', ARG_COMP))
    comp_addr = _addr(args, comp_reg, 0)
    word = int(args.get('status', STATUS_DONE))
    return result, {'addr': comp_addr, 'word': word}


def completion_word(args=None):
    """Значение status-слова программы (host читает ОДНО слово)."""
    user = args or {}
    args = dict(DEFAULT_ARGS)
    args.update(user)
    return int(args.get('status', STATUS_DONE))