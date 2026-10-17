"""Полная верификация ELEM_FMT=1 (fp32) в 8-байт-режиме: все НЕпокрытые пути.

Закрывает тестовые гепки fp32-режима tdot_axi4 (PACKED8) перед переходом на
PACKED6. Запускает tb_tdot_axi4_fp32x.sv для набора конфигураций (NUM_MAC /
BURST_RD_LEN), каждая покрывает свой сценарий:

  cfg_partial  NUM_MAC=16, BURST_RD_LEN=16 — partial/нечётный N_IN (N<NUM_MAC)
               + zero-fill + ceil(n/2) с «половинкой» слова на нечётном хвосте.
  cfg_long     NUM_MAC=16, BURST_RD_LEN=16 — long-dot N>NUM_MAC (multi-pass +
               аккумулятор tfadd48), эталон через почанковый dot + tfadd.
  cfg_sched    NUM_MAC=16, BURST_RD_LEN=16 — планировщик fp32 (CS_FETCH_DESC +
               CS_CMP1..3, result через T2F), 2-3 задачи вкл. long-dot, doorbell.
  cfg_align    NUM_MAC=16, BURST_RD_LEN=16 — align_q-fault (адрес не кратен 4)
               в GO-пути и в планировщике: статус/пропуск, слово не пишется.
  cfg_burst    NUM_MAC=32, BURST_RD_LEN=8 — multi-burst (chunk_words>BURST_RD_LEN,
               несколько AR на чанк), fifo не переполняется, данные корректны.
  cfg_mix      NUM_MAC=16, BURST_RD_LEN=16 — случайный составной прогон:
               mix partial+full+long-dot в GO-пути со случайными fp32.

Эталон результата платы (после T2F) == float32-bits( TFloat.to_float(
dot_ref_raw / почанкового longdot )) — т.е. ровно путь ядра: F2T -> tfmul/tfadd
(raw) -> T2F. Данные — случайные float32 (не все 1.0), кроме специальных кейсов.

Запуск:  python verify_tdot_axi4_fp32x.py   (гоняет все конфигурации)
         python verify_tdot_axi4_fp32x.py cfg1 cfg2 ...  (только указанные)
"""
from __future__ import annotations
import sys, os, subprocess, struct, random, csv, shutil

RTL = os.path.dirname(os.path.abspath(__file__))
BLOCK = os.path.join(RTL, "..", "block")
SIM = os.path.join(RTL, "sim")
sys.path.insert(0, RTL)
sys.path.insert(0, os.path.join(RTL, "..", "..", "ternary_sw"))

from block.tfloat48 import TFloat
from block import arith48
import block.trits as Tmod
# переиспользуем точную модель RTL dot_ref_raw и тритовые примитивы.
# ВНИМАНИЕ: verify_tdot_axi4.py читает sys.argv на уровне модуля (NUM_MAC),
# а наш скрипт вызывается с именами конфигураций — временно подменяем sys.argv
# на время импорта, чтобы int(sys.argv[1]) не упал, и восстанавливаем.
_save_argv = list(sys.argv)
sys.argv = [sys.argv[0]]
from verify_tdot_axi4 import (dot_ref_raw, to_bits48, _bits_to_tf, _pack_raw,
                              _raw_add, _norm_rtl_flat)
sys.argv = _save_argv

_CAND = "C:/AMDDesignTools/2025.2/Vivado/bin"
XIL = os.environ.get("VIVADO_BIN") or _CAND

M_MASK = (1 << 40) - 1

FILES = [
    os.path.join(BLOCK, "tbyte_add.sv"),
    os.path.join(BLOCK, "tbyte_mul.sv"),
    os.path.join(BLOCK, "tfadd_raw.sv"),
    os.path.join(BLOCK, "tfmul_raw.sv"),
    os.path.join(BLOCK, "tfadd48.sv"),
    os.path.join(BLOCK, "compute_dot_par_raw.sv"),
    os.path.join(RTL, "..", "rtl", "tf48_pkg.sv"),
    os.path.join(RTL, "..", "rtl", "int_to_trits.sv"),
    os.path.join(RTL, "..", "rtl", "tf48_div_pipe.sv"),
    os.path.join(RTL, "..", "rtl", "f32_to_tf48_pipe.sv"),
    os.path.join(RTL, "..", "rtl", "tf48_to_f32_pipe.sv"),
    os.path.join(RTL, "tdot_axi4.sv"),
    os.path.join(RTL, "tb_tdot_axi4_fp32x.sv"),
]

# ------------------------- проброс: Python-модель границ ---------------------
import math

def f32(x): return struct.unpack("f", struct.pack("f", x))[0]
def f32_bits(x): return struct.unpack("I", struct.pack("f", x))[0]
def kernel_to_py(w): return ((w & M_MASK) << 8) | ((w >> 40) & 0xFF)
def py_to_kernel(b): return ((b & 0xFF) << 40) | ((b >> 8) & M_MASK)

def ref_fp32_result(tf48_word):
    """tf48 (kernel-конвенция) -> float32 bits (RNE), как T2F/RTL."""
    return f32_bits(TFloat.from_bits(kernel_to_py(tf48_word)).to_float())


ZERO_BITS = to_bits48(TFloat.from_float(0.0))   # tf48 нуль в kernel-конвенции


def _unpack_word(w):
    """kernel 48-бит word -> (signed m, signed e). [47:40]=e, [39:0]=m."""
    m = w & M_MASK
    e = (w >> 40) & 0xFF
    mt = Tmod.unpack(m, 20)
    et = Tmod.unpack(e, 4)
    mm = 0
    for t in mt: mm = mm * 3 + t
    ee = 0
    for t in et: ee = ee * 3 + t
    return mm, ee


def tfadd48_ref(a_word, b_word):
    """Точная модель аккумулятора tfadd48 (Р) поверх _raw_add.
    a,b — kernel 48-бит слова (норализованные TFloat48)."""
    ma, ea = _unpack_word(a_word)
    mb, eb = _unpack_word(b_word)
    mo, eo = _raw_add(ma, ea, mb, eb)
    return _pack_raw(mo, eo)


def longdot_ref(a_bits, b_bits, NUM_MAC):
    """Много-passовый dot c аккумуляцией, как в RTL (pass0 без сложения).
    Возвращает kernel-слово tf48 результата. a_bits/b_bits — списки to_bits48."""
    acc = None
    offset = 0
    passes = 0
    n = len(a_bits)
    while offset < n:
        chunk = min(NUM_MAC, n - offset)
        # КАЖДЫЙ чанк дополняем до NUM_MAC нулями, чтобы дерево RTL
        # (всегда полные NUM_MAC слотов, с zero-fill) совпадало с эталоном
        # dot_ref_raw (сбалансированное дерево по ровно NUM_MAC листьев).
        a_ch = list(a_bits[offset:offset + chunk]) + [ZERO_BITS] * (NUM_MAC - chunk)
        b_ch = list(b_bits[offset:offset + chunk]) + [ZERO_BITS] * (NUM_MAC - chunk)
        partial = dot_ref_raw(a_ch, b_ch)
        acc = partial if acc is None else tfadd48_ref(acc, partial)
        passes += 1
        offset += chunk
    return acc, passes


def single_chunk_ref(a_bits, b_bits, NUM_MAC):
    """Одно-чанковый dot для n<=NUM_MAC c zero-padding до NUM_MAC (RTL-слотируемость)."""
    a_ch = list(a_bits) + [ZERO_BITS] * (NUM_MAC - len(a_bits))
    b_ch = list(b_bits) + [ZERO_BITS] * (NUM_MAC - len(b_bits))
    return dot_ref_raw(a_ch, b_ch)


def gen_fp32_vectors(n, seed):
    """Случайные float32 векторы a/b длиной n (воспроизводимо по seed+len)."""
    rnd = random.Random(seed + n * 7919)
    a = [f32(rnd.uniform(-10, 10)) for _ in range(n)]
    b = [f32(rnd.uniform(-10, 10)) for _ in range(n)]
    return a, b


def pack_fp32_words(vec):
    """fp32 список -> список 64-бит слов (2 fp32 на слово), как в памяти ядра."""
    words = []
    for k in range(0, len(vec), 2):
        lo = f32_bits(vec[k])
        hi = f32_bits(vec[k + 1]) if k + 1 < len(vec) else 0
        words.append((hi << 32) | lo)
    return words


# ============================================================================
# Построение сценариев (каждая конфигурация -> набор заданий + память)
# ============================================================================
DESC_BASE = 0x0000_0000
COMP_BASE = 0x0000_4000
REGION_BASE = 0x0000_1000
REGION_STRIDE = 0x1000


class Task:
    def __init__(self, kind, n, data, wgt, result, tag, baseline, align, cfg):
        self.kind = kind        # 'go' | 'sched'
        self.n = n
        self.data = data
        self.wgt = wgt
        self.result = result
        self.tag = tag
        self.baseline = baseline
        self.align = align
        self.cfg = cfg
        self.exp_fp32 = None    # expected fp32 bits (заполняется reference)
        self.exp_passes = None


def build_cfg_partial():
    """1) partial/нечётный N_IN — zero-fill + ceil(n/2) с «половинкой» слова."""
    cfg = dict(name="cfg_partial", NUM_MAC=16, rd=16, wr=8, tasks=[])
    base = REGION_BASE
    for k, n in enumerate([1, 3, 7, 15, 8, 16]):
        a, b = gen_fp32_vectors(n, 1000 + k)
        t = Task("go", n, base, base + 0x400, base + 0x800, 0, 0, False, cfg["name"])
        t.a, t.b = a, b
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    return cfg


def build_cfg_long():
    """2) long-dot N>NUM_MAC — multi-pass + аккумулятор."""
    cfg = dict(name="cfg_long", NUM_MAC=16, rd=16, wr=8, tasks=[])
    base = REGION_BASE
    for k, n in enumerate([17, 40, 100]):
        a, b = gen_fp32_vectors(n, 2000 + k)
        t = Task("go", n, base, base + 0x400, base + 0x800, 0, 0, False, cfg["name"])
        t.a, t.b = a, b
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    return cfg


def build_cfg_sched():
    """3) планировщик fp32: partial + long-dot, doorbell, T2F результат."""
    cfg = dict(name="cfg_sched", NUM_MAC=16, rd=16, wr=8, tasks=[])
    base = REGION_BASE
    specs = [(8, 0x1110, False), (24, 0x1111, False), (40, 0x1112, False)]
    for k, (n, tag, _align) in enumerate(specs):
        a, b = gen_fp32_vectors(n, 3000 + k)
        t = Task("sched", n, base, base + 0x400, base + 0x800, tag, 0, False, cfg["name"])
        t.a, t.b = a, b
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    return cfg


def build_cfg_align():
    """4) align_q-fault в fp32: адрес не кратен 4 -> пропуск/статус."""
    cfg = dict(name="cfg_align", NUM_MAC=16, rd=16, wr=8, tasks=[])
    base = REGION_BASE
    # GO-путь: 2 normal (для сравнения) + 2 align
    for k, n in enumerate([4, 16]):
        a, b = gen_fp32_vectors(n, 4000 + k)
        t = Task("go", n, base, base + 0x400, base + 0x800, 0, 0, False, cfg["name"])
        t.a, t.b = a, b
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    for k, n in enumerate([3, 7]):   # align: result не кратен 4
        a, b = gen_fp32_vectors(n, 4100 + k)
        res = base + 0x800 + 1       # bit0=1 -> fp32 мизалайнг
        t = Task("go", n, base, base + 0x400, res, 0, 0xD1CEB4A5_F00D00D, True, cfg["name"])
        t.a, t.b = a, b
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    # планировщик: 1 normal + 1 align
    for k, n in enumerate([12, 5]):
        a, b = gen_fp32_vectors(n, 4200 + k)
        if k == 0:
            res = base + 0x800
            t = Task("sched", n, base, base + 0x400, res, 0xAB01, 0, False, cfg["name"])
        else:
            res = base + 0x800 + 1
            t = Task("sched", n, base, base + 0x400, res, 0xAB02,
                     0xC0FFEE003_0B1A, True, cfg["name"])
        t.a, t.b = a, b
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    return cfg


def build_cfg_burst():
    """5) multi-burst: NUM_MAC=32, BURST_RD_LEN=8 (chunk_words>RD_LEN)."""
    cfg = dict(name="cfg_burst", NUM_MAC=32, rd=8, wr=4, tasks=[])
    base = REGION_BASE
    specs = [(32, 1000 + k) for k in range(2)] + [(40, 1100 + k) for k in range(2)]
    for k, (n, _s) in enumerate(specs):
        a, b = gen_fp32_vectors(n, 5000 + k)
        t = Task("go", n, base, base + 0x400, base + 0x800, 0, 0, False, cfg["name"])
        t.a, t.b = a, b
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    return cfg


def build_cfg_mix():
    """6) случайный составной прогон: partial+full+long-dot, различные n."""
    cfg = dict(name="cfg_mix", NUM_MAC=16, rd=16, wr=8, tasks=[])
    rnd = random.Random(6000)
    ns = [1, 5, 16, 3, 10, 17, 24, 2, 33, 48, 8, 15, 9, 13, 40]
    base = REGION_BASE
    for k, n in enumerate(ns):
        a, b = gen_fp32_vectors(n, 6000 + k)
        t = Task("go", n, base, base + 0x400, base + 0x800, 0, 0, False, cfg["name"])
        t.a, t.b = a, b
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    return cfg


ALL_CFG = [build_cfg_partial, build_cfg_long, build_cfg_sched,
           build_cfg_align, build_cfg_burst, build_cfg_mix]


# ============================================================================
# Генерация памяти и manifest
# ============================================================================
def place_mem(cfg):
    """Заполняет mem (dict addr->word) для конфигурации и считает эталоны.
    Возвращает (mem, sched_slots), где sched_slots — слоты планировщика с описанием."""
    NUM_MAC = cfg["NUM_MAC"]
    mem = {}
    sched_slots = []          # список (description_tag, task) в порядке дескрипторов
    for task in cfg["tasks"]:
        data_words = pack_fp32_words(task.a)
        wgt_words = pack_fp32_words(task.b)
        base = task.data
        for i, w in enumerate(data_words):
            mem[base + i * 8] = w
        for i, w in enumerate(wgt_words):
            mem[task.wgt + i * 8] = w
        # эталон (tf48 kernel-слово) и fp32-bits
        a_bits = [to_bits48(TFloat.from_float(x)) for x in task.a]
        b_bits = [to_bits48(TFloat.from_float(y)) for y in task.b]
        if task.n <= NUM_MAC:
            r48 = single_chunk_ref(a_bits, b_bits, NUM_MAC)
            passes = 1
        else:
            r48, passes = longdot_ref(a_bits, b_bits, NUM_MAC)
        task.exp_fp32 = ref_fp32_result(r48)
        task.exp_passes = passes
        task.exp_r48 = r48
        # baseline для align-заданий (слово по result-адресу)
        if task.align:
            mem[task.result & ~7] = task.baseline   # result может быть не 8-выровнен; кладём baseline в слово, содержащее байт
        # для normal-задания результат будет записан ядром — baseline не трогаем (0)

    # дескрипторы планировщика
    idx_sched = 0
    for task in cfg["tasks"]:
        if task.kind != "sched":
            continue
        dbase = DESC_BASE + idx_sched * 32
        mem[dbase] = task.data & 0xFFFFFFFFFFFF
        mem[dbase + 8] = task.wgt & 0xFFFFFFFFFFFF
        mem[dbase + 16] = task.result & 0xFFFFFFFFFFFF
        # W3 4-й 64-бит слова: RTL берёт job_n_total_q <= desc_w[3][31:16],
        # job_tag_q <= desc_w[3][15:0], поэтому n в бит[31:16], tag в бит[15:0].
        mem[dbase + 24] = ((task.n & 0xFFFF) << 16) | (task.tag & 0xFFFF)
        idx_sched += 1
        sched_slots.append(task)
    return mem, sched_slots


def write_files(cfg):
    NUM_MAC = cfg["NUM_MAC"]
    mem, sched_slots = place_mem(cfg)
    # mem.hex
    with open(os.path.join(SIM, "fp32x_mem.hex"), "w") as f:
        for addr in sorted(mem):
            f.write(f"{addr:08x} {mem[addr]:016x}\n")
    # tasks.txt
    with open(os.path.join(SIM, "fp32x_tasks.txt"), "w") as f:
        for idx, task in enumerate(cfg["tasks"]):
            kind = 1 if task.kind == "go" else 2
            tag = task.tag if task.kind == "sched" else 0
            blo = task.baseline & 0xFFFFFFFF
            bhi = (task.baseline >> 32) & 0xFFFFFFFF
            f.write(f"{kind} {task.n} {task.data} {task.wgt} {task.result} "
                    f"{tag} {blo} {bhi}\n")
    return sched_slots


def run_sim(cfg):
    """Компиляция+эмуляция конфигурации. Возвращает текст sim/fp32x_out.hex."""
    name = cfg["name"]
    tb_path = os.path.join(RTL, "tb_tdot_axi4_fp32x.sv")
    tb_src = open(tb_path, encoding="utf-8").read()
    tb_src = tb_src.replace("parameter int NUM_MAC = 32;",
                            f"parameter int NUM_MAC = {cfg['NUM_MAC']};")
    tb_src = tb_src.replace("parameter int BURST_RD_LEN = 16;",
                            f"parameter int BURST_RD_LEN = {cfg['rd']};")
    tb_src = tb_src.replace("parameter int BURST_WR_LEN = 8;",
                            f"parameter int BURST_WR_LEN = {cfg['wr']};")
    tb_use = os.path.join(RTL, "tb_tdot_axi4_fp32x_use.sv")
    open(tb_use, "w", encoding="utf-8").write(tb_src)

    for d in ["xsim.dir", "xsim.cmd", "xsim.log"]:
        p = os.path.join(RTL, d)
        if os.path.isdir(p):
            shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)

    xvlog = os.path.join(XIL, "xvlog.bat")
    xelab = os.path.join(XIL, "xelab.bat")
    xsim = os.path.join(XIL, "xsim.bat")

    def run(cmd):
        r = subprocess.run(cmd, shell=True, cwd=RTL, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"CMD FAIL [{name}]:")
            print(r.stdout[-2500:])
            print(r.stderr[-2500:])
            sys.exit(1)
        return r

    print(f"[{name}] xvlog/xelab/xsim ...")
    # REVIEW-FIX 2026-10-18: компилируем ПОДСТАВЛЕННЫЙ tb_use (с параметрами
    # конфигурации), а не оригинальный tb_tdot_axi4_fp32x.sv (дефолт NUM_MAC=32).
    # Раньше _use.sv записывался, но не входил в FILES — xelab брал оригинал с
    # NUM_MAC=32 для ВСЕХ конфигураций, и моменток pass-count в счed расходился
    # с эталоном (эталон режет чанки по конфиг-ному NUM_MAC). Заменяем элемент
    # FILES, соответствующий оригинальному tb, на tb_use.
    files_use = [tb_use if os.path.abspath(f) == os.path.abspath(os.path.join(RTL, "tb_tdot_axi4_fp32x.sv"))
                 else f for f in FILES]
    run(f'"{xvlog}" -sv {" ".join(files_use)}')
    run(f'"{xelab}" tb_tdot_axi4_fp32x -debug typical')
    run(f'"{xsim}" tb_tdot_axi4_fp32x -runall')
    out = open(os.path.join(SIM, "fp32x_out.hex")).read()
    return out


# ============================================================================
# Верификация вывода
# ============================================================================
def buggy_shifted_ref(task, NUM_MAC):
    """Модель реального (ошибочного) поведения RTL для НЕЧЁТНОГО чанка:
    данные грузятся верно, а веса сдвигаются: slot0=0, slot i = b[i-1],
    последний вес теряется. Возвращает fp32-bits ожидаемого «сдвинутого» результата."""
    a = task.a
    b = task.b
    b_shift = [0.0] + b[:-1]                       # 0, b0, b1, ..., b[n-2] (длина n)
    a_bits = [to_bits48(TFloat.from_float(x)) for x in a] + [ZERO_BITS] * (NUM_MAC - len(a))
    b_bits = [to_bits48(TFloat.from_float(y)) for y in b_shift] + [ZERO_BITS] * (NUM_MAC - len(b_shift))
    r48 = dot_ref_raw(a_bits, b_bits)
    return ref_fp32_result(r48)


def verify_output(cfg, sched_slots, out):
    name = cfg["name"]
    NUM_MAC = cfg["NUM_MAC"]
    checks = []
    ok = True

    def check(cond, label, detail=""):
        nonlocal ok
        checks.append((label, bool(cond), detail))
        if not cond:
            ok = False

    go_results = {}       # idx -> word64
    cmp = {}              # idx -> (w0, w1) completion
    sched_res = {}        # idx -> result word
    sched_sum = None
    for l in out.splitlines():
        l = l.strip()
        if not l:
            continue
        parts = l.split()
        if parts[0] == "GO":
            go_results[int(parts[1])] = int(parts[2], 16)
        elif parts[0] == "CMP":
            cmp[int(parts[1])] = (int(parts[2], 16), int(parts[3], 16), int(parts[4], 16))
        elif parts[0] == "SUM":
            sched_sum = (int(parts[1]), int(parts[2]), parts[3] == "1")

    # --- GO-задания ---
    n_go = 0
    for idx, task in enumerate(cfg["tasks"]):
        if task.kind != "go":
            continue
        n_go += 1
        if idx not in go_results:
            check(False, f"cfg {name} GO#{idx}: нет результата в выходе", "")
            continue
        word = go_results[idx]
        got_fp32 = word & 0xFFFFFFFF
        if task.align:
            check(word == task.baseline,
                  f"{name} GO#{idx}(align n={task.n}): слово НЕ записано (baseline сохранён)",
                  f"got={word:016x} baseline={task.baseline:016x}")
        elif (task.n % 2) == 1:
            # НЕЧЁТНЫЙ чанк: проверяем и корректный эталон, и сдвинутую модель (RTL-баг).
            if got_fp32 == task.exp_fp32:
                check(True, f"{name} GO#{idx}(n={task.n}): результат == fp32 эталон", "")
            else:
                bug = buggy_shifted_ref(task, NUM_MAC)
                if got_fp32 == bug:
                    check(False,
                          f"{name} GO#{idx}(n={task.n}): RTL-БАГ — нечётный чанк, веса сдвинуты "
                          f"(совпадает со «сдвинутой» моделью)",
                          f"got={got_fp32:08x} (correct exp={task.exp_fp32:08x}, shifted exp={bug:08x})")
                else:
                    check(False, f"{name} GO#{idx}(n={task.n}): результат != fp32 эталон",
                          f"got={got_fp32:08x} exp={task.exp_fp32:08x}")
            check((word >> 32) == 0,
                  f"{name} GO#{idx}(n={task.n}): старшие 32 бита = 0",
                  f"word={word:016x}")
        else:
            check(got_fp32 == task.exp_fp32,
                  f"{name} GO#{idx}(n={task.n}): результат == fp32 эталон",
                  f"got={got_fp32:08x} exp={task.exp_fp32:08x}")
            check((word >> 32) == 0,
                  f"{name} GO#{idx}(n={task.n}): старшие 32 бита = 0",
                  f"word={word:016x}")

    # --- планировщик ---
    sched_tasks = [t for t in cfg["tasks"] if t.kind == "sched"]
    if sched_tasks:
        want_done = len(sched_tasks)
        n_sched_read = len([1 for idx in cmp if cfg["tasks"][idx].kind == "sched"])
        if sched_sum is not None:
            rptr, done, irq = sched_sum
            check(done == want_done, f"{name} sched: DONE_CNT=={want_done}",
                  f"done={done}")
            check(irq, f"{name} sched: IRQ поднят при опустошении очереди",
                  f"irq={'1' if rptr else '0'}")
        for slot, task in enumerate(sched_tasks):
            idx = cfg["tasks"].index(task)
            if idx not in cmp:
                check(False, f"{name} sched slot{slot} (n={task.n}): completion нет", "")
                continue
            w0, w1, rw = cmp[idx]
            tag = (w0 >> 48) & 0xFFFF
            comp_res = w0 & 0xFFFFFFFF          # fp32 результат в младших 32 битах W0
            comp_hi = (w0 >> 32) & 0xFFFF       # [47:32] == 0 для fp32 (res1_reg=0)
            passes = (w1 >> 8) & 0xFF
            status = w1 & 0xFF                  # sat|align в младших битах
            align_bit = (w1 >> 1) & 1
            sat_bit = (w1 >> 0) & 1
            check(tag == task.tag, f"{name} sched slot{slot}: tag",
                  f"got={tag:04x} exp={task.tag:04x}")
            if task.align:
                check(align_bit == 1, f"{name} sched slot{slot}(align): align-статус=1",
                      f"align={align_bit}")
                check(passes == 0, f"{name} sched slot{slot}(align): passes==0",
                      f"passes={passes}")
                check(rw == task.baseline, f"{name} sched slot{slot}(align): слово НЕ пишется",
                      f"got={rw:016x} baseline={task.baseline:016x}")
            else:
                check(align_bit == 0, f"{name} sched slot{slot}: align=0",
                      f"align={align_bit}")
                check(sat_bit == 0, f"{name} sched slot{slot}: sat=0", f"sat={sat_bit}")
                if (task.n % 2) == 1:
                    if comp_res == task.exp_fp32:
                        check(True, f"{name} sched slot{slot}(n={task.n}): result == эталон", "")
                    else:
                        bug = buggy_shifted_ref(task, NUM_MAC)
                        check(False,
                              f"{name} sched slot{slot}(n={task.n}): RTL-БАГ — нечётный чанк, "
                              f"веса сдвинуты",
                              f"got={comp_res:08x} (exp={task.exp_fp32:08x}, shifted={bug:08x})")
                else:
                    check(comp_res == task.exp_fp32,
                          f"{name} sched slot{slot}(n={task.n}): completion.result == fp32 эталон",
                          f"got={comp_res:08x} exp={task.exp_fp32:08x}")
                check(comp_hi == 0, f"{name} sched slot{slot}: result[47:32]==0 (fp32)",
                      f"comp_hi={comp_hi:04x}")
                check(passes == task.exp_passes,
                      f"{name} sched slot{slot}(n={task.n}): passes=={task.exp_passes}",
                      f"passes={passes}")
                if (task.n % 2) == 1:
                    if (rw & 0xFFFFFFFF) == task.exp_fp32:
                        check(True, f"{name} sched slot{slot}: result_addr слово == эталон", "")
                    else:
                        check(False, f"{name} sched slot{slot}: result_addr слово != эталон "
                                     f"(RTL-баг нечётного чанка)",
                              f"got={rw & 0xFFFFFFFF:08x} exp={task.exp_fp32:08x}")
                else:
                    check((rw & 0xFFFFFFFF) == task.exp_fp32,
                          f"{name} sched slot{slot}: result_addr слово == fp32 эталон",
                          f"got={rw & 0xFFFFFFFF:08x} exp={task.exp_fp32:08x}")

    print(f"\n===== {name} (NUM_MAC={NUM_MAC}, RD={cfg['rd']}, WR={cfg['wr']}, "
          f"go={n_go}, sched={len(sched_tasks)}) =====")
    all_pass = True
    for label, cond, detail in checks:
        flag = "PASS" if cond else "FAIL"
        if not cond:
            all_pass = False
        print(f"  [{flag}] {label}" + (f"  ({detail})" if detail and not cond else ""))
    print(f"  --- {name}: {'PASS' if all_pass else 'FAIL'}  "
          f"({sum(1 for c in checks if c[1])}/{len(checks)} проверок) ---")
    return all_pass


def print_fp8x_summary(cfg):
    """Сводка эталонных значений (для отчёта): декодирует результат в fp32."""
    name = cfg["name"]
    lines = []
    for task in cfg["tasks"]:
        if task.align:
            continue
        val = struct.unpack("f", struct.pack("I", task.exp_fp32))[0]
        lines.append(f"    {name}[{task.n}] fp32_bits={task.exp_fp32:08x} "
                     f"val={val:.9g} passes={task.exp_passes}")
    for ln in lines:
        print(ln)


def main():
    which = sys.argv[1:] if len(sys.argv) > 1 else ["cfg_partial", "cfg_long",
                                                     "cfg_sched", "cfg_align",
                                                     "cfg_burst", "cfg_mix"]
    os.makedirs(SIM, exist_ok=True)
    total_ok = True
    for build in ALL_CFG:
        cfg = build()
        if cfg["name"] not in which:
            continue
        sched_slots = write_files(cfg)
        out = run_sim(cfg)
        ok = verify_output(cfg, sched_slots, out)
        print_fp8x_summary(cfg)
        total_ok = total_ok and ok
    print("\n===== ВСЕ КОНФИГУРАЦИИ:", "PASS" if total_ok else "FAIL", "=====")
    sys.exit(0 if total_ok else 1)


if __name__ == "__main__":
    main()