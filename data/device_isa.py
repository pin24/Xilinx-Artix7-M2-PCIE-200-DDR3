#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""device_isa.py — битовый ISA-компилятор + интерпретатор device-side программ (2026-10-20).

Роль: БИТ-ТОЧНАЯ функциональная модель «данные + программа = результат» на уровне
ISA, описанного в docs/device-isa-2026-10-20.md. Хост готовит ПРОГРАММУ — таблицу
32-байтных юнитов в DRAM, пишет только ARG0..ARG7 + RUN; устройство само крутит
линейную цепочку юнитов (каждый юнит = линейный слой, повторяемый `pass` раз),
а в конце пишет одно status-слово в completion-mailbox (WAITW-аналог). FPGA-ядро
tdot здесь только СЕМАНТИЧЕСКИ: линейный слой сводится к dot-per-output-neuron,
как devseq и nn_audio_common.matmul_w.

numpy-only (проект numpy-only). Все функции импортируются без железа (эмуляция).
tf48-округление на этом уровне НЕ требуется — бит-точность = к существующим
numpy-эталонам (devseq / nn_audio_common.forward_batch cpu).

Дисциплина адресов — «R[x] + imm»: каждый адрес в юните указан парой (reg, imm),
где reg выбирает один из ARG-регистров (0..7), а imm — 28-битное смещение.
Разрешённый адрес = ARG[reg] + imm. Каждое движение данных — явно.
"""
from __future__ import annotations
import struct
import numpy as np

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
# Функциональная модель (numpy-only)
# ---------------------------------------------------------------------------
def linear_pass(cur, W, b=None, relu=False):
    """Один проход линейного слоя: cur @ W + b, опц. relu (как devseq.linear_pass)."""
    out = cur @ W
    if b is not None:
        out = out + b
    if relu:
        out = np.maximum(0.0, out)
    return out


def _addr(args, reg, imm):
    return (int(args.get(reg, 0)) + int(imm)) & 0xFFFFFFFF


def _coerce_units(program):
    if isinstance(program, (bytes, bytearray)):
        return parse(program)
    return [normalize_unit(u) for u in program]


def run_chain(data, units, weights, args):
    """Прогнать цепочку юнитов; data — входной батч, weights — {tag: (W, b)}.

    Возвращает (результат-батч, trace) — trace список dict с разрешёнными адресами
    (для RTL-сравнения), каждое движение данных — явно.
    """
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
            cur = linear_pass(inp, W, b if use_b else None, relu)
        trace.append({'tag': int(u['tag']), 'w_addr': waddr, 'b_addr': baddr,
                      'out_addr': oaddr, 'pass': pas})
    return cur, trace


def run_program(data, program, weights, args=None):
    """Бит-точный интерпретатор: данные + программа -> результат батча (как devseq).

    data — (B, in0) float32; program — список юнитов ИЛИ байты таблицы;
    weights — {tag: (W, b)} float32; args — dict ARG-регистров (int-ключи 0..7)
    + служебные: args['repeat'] — целочисленный LOOP всей цепочки (по умолчанию 1).
    Возвращает результат батча (B, out_last).
    """
    units = _coerce_units(program)
    user = args or {}
    args = dict(DEFAULT_ARGS)
    args.update(user)
    repeat = int(args.pop('repeat', 1))
    cur = np.asarray(data, dtype=np.float32)
    for _ in range(repeat):
        cur, _ = run_chain(cur, units, weights, args)
    return cur


def run_program_trace(data, program, weights, args=None):
    """Как run_program, но возвращает (результат, trace) — для RTL-сверки адресов."""
    units = _coerce_units(program)
    user = args or {}
    args = dict(DEFAULT_ARGS)
    args.update(user)
    repeat = int(args.pop('repeat', 1))
    cur = np.asarray(data, dtype=np.float32)
    trace = []
    for _ in range(repeat):
        cur, tr = run_chain(cur, units, weights, args)
        trace.append(tr)
    return cur, trace


def run_program_mb(data, program, weights, args=None):
    """Как run_program, но с completion-mailbox-семантикой.

    Возвращает (результат, completion), где completion = {'addr', 'word'}:
    addr — адрес status-слова в DRAM (по умолчанию ARG[comp_reg]);
    word — записанное status-слово (бит0=DONE). args['status'] переопределяет слово.
    """
    user = args or {}
    args = dict(DEFAULT_ARGS)
    args.update(user)
    result = run_program(data, program, weights, args)
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