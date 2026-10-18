"""Полная верификация ELEM_FMT=2 (PACKED6, 6 байт/элемент) ядра tdot_axi4.

Закрывает все пути PACKED6-режима (баррель 6<->8) поверх уплотнённой памяти
(N*6 байт на элемент tf48). Запускает tb_tdot_axi4_packed6x.sv для набора
конфигураций (NUM_MAC / BURST_RD_LEN), каждая покрывает свой сценарий:

  cfg_partial  NUM_MAC=16, BURST_RD_LEN=16   partial/нечётный N_IN (N<NUM_MAC),
               хвостовое слово частичное (баррель останавливается на n_elem).
  cfg_long     NUM_MAC=16, BURST_RD_LEN=16   long-dot N>NUM_MAC (multi-pass +
               аккумулятор tfadd48).
  cfg_sched    NUM_MAC=16, BURST_RD_LEN=16   планировщик PACKED6 (CS_CMP1..3).
  cfg_align    NUM_MAC=16, BURST_RD_LEN=16   align_q-fault (адрес не кратен 8).
  cfg_burst    NUM_MAC=32, BURST_RD_LEN=8    multi-burst (chunk_words>RD_LEN).
  cfg_mix      NUM_MAC=16, BURST_RD_LEN=16   случайный составной прогон.

ЭТАЛОН = dot_ref_raw над входными 48-бит словами (теми же, что упакованы 6 байт
в память); результат - 48-бит tf48 слово, сверяется бит-в-бит с записанным.

Учтены грабли прошлых задач:
  1) нечётный чанк - баррель выдаёт РОВНО n_elem элементов (не +pad); последнее
     слово частичное, лишние байты отбрасываются.
  2) pf_reset/межпроходовой сброс барреля - перевооружение (p6_arm) на каждый
     read-старт + гейт rd_phase_done (ждёт drained перед переходом).
  3) тест-харнес компилирует ПОДСТАВЛЕННУЮ tb_use (с параметрами конфигурации),
     а не оригинал tb_tdot_axi4_packed6x.sv.

Запуск: python verify_tdot_axi4_packed6x.py [cfg1 cfg2 ...]
"""
from __future__ import annotations
import sys, os, subprocess, struct, random

RTL = os.path.dirname(os.path.abspath(__file__))
BLOCK = os.path.join(RTL, "..", "block")
SIM = os.path.join(RTL, "sim")
sys.path.insert(0, RTL)
sys.path.insert(0, os.path.join(RTL, "..", "..", "ternary_sw"))

from block.tfloat48 import TFloat
import block.trits as Tmod
_save_argv = list(sys.argv)
sys.argv = [sys.argv[0]]
from verify_tdot_axi4 import (dot_ref_raw, to_bits48, _bits_to_tf, _pack_raw,
                              _raw_add)
sys.argv = _save_argv

XIL = os.environ.get("VIVADO_BIN") or "C:/AMDDesignTools/2025.2/Vivado/bin"
M_MASK = (1 << 40) - 1
ZERO_BITS = to_bits48(TFloat.from_float(0.0))
# Gap-2 (WSTRB): результат PACKED6 пишется 6 байт (WSTRB=0x3F), верхние 2 байта
# слова НЕ трогаются. Перед задачей верхние 16 бит слова результата ядовиты этим
# сентинелом; после записи они ДОЛЖНЫ остаться = WSTRB_SENT (иначе WSTRB игнорируется).
WSTRB_SENT = 0xC5C5

FILES = [
    os.path.join(BLOCK, "tbyte_add.sv"),
    os.path.join(BLOCK, "tbyte_mul.sv"),
    os.path.join(BLOCK, "tfadd_raw.sv"),
    os.path.join(BLOCK, "tfmul_raw.sv"),
    os.path.join(BLOCK, "tfadd48.sv"),
    os.path.join(BLOCK, "compute_dot_par_raw.sv"),
    os.path.join(BLOCK, "packed6_rd.sv"),
    os.path.join(BLOCK, "packed6_wr.sv"),
    os.path.join(RTL, "..", "rtl", "tf48_pkg.sv"),
    os.path.join(RTL, "..", "rtl", "int_to_trits.sv"),
    os.path.join(RTL, "tdot_axi4.sv"),
    os.path.join(RTL, "tb_tdot_axi4_packed6x.sv"),
]


def f32(x): return struct.unpack("f", struct.pack("f", x))[0]


def _unpack_word(w):
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
    ma, ea = _unpack_word(a_word)
    mb, eb = _unpack_word(b_word)
    mo, eo = _raw_add(ma, ea, mb, eb)
    return _pack_raw(mo, eo)


def longdot_ref(a_bits, b_bits, NUM_MAC):
    acc = None
    offset = 0
    passes = 0
    n = len(a_bits)
    while offset < n:
        chunk = min(NUM_MAC, n - offset)
        a_ch = list(a_bits[offset:offset + chunk]) + [ZERO_BITS] * (NUM_MAC - chunk)
        b_ch = list(b_bits[offset:offset + chunk]) + [ZERO_BITS] * (NUM_MAC - chunk)
        partial = dot_ref_raw(a_ch, b_ch)
        acc = partial if acc is None else tfadd48_ref(acc, partial)
        passes += 1
        offset += chunk
    return acc, passes


def single_chunk_ref(a_bits, b_bits, NUM_MAC):
    a_ch = list(a_bits) + [ZERO_BITS] * (NUM_MAC - len(a_bits))
    b_ch = list(b_bits) + [ZERO_BITS] * (NUM_MAC - len(b_bits))
    return dot_ref_raw(a_ch, b_ch)


def gen_tf48_vectors(n, seed):
    """Случайные float -> tf48 kernel-слова (E в бит[47:40]). PACKED6 вход уже tf48."""
    rnd = random.Random(seed + n * 7919)
    a = [TFloat.from_float(f32(rnd.uniform(-10, 10))) for _ in range(n)]
    b = [TFloat.from_float(f32(rnd.uniform(-10, 10))) for _ in range(n)]
    return [to_bits48(x) for x in a], [to_bits48(y) for y in b]


# ---------------- PACKED6 байт-пакер (память в 64-бит словах) ----------------
# element = 48-бит kernel-слово. Little-endian байты:
#   b0=M[7:0], b1=M[15:8], b2=M[23:16], b3=M[31:24], b4=M[39:32], b5=E.
class Mem:
    def __init__(self):
        self.words = {}           # byte_addr & ~7 -> 64-бит значение

    def _get(self, wa):
        return self.words.get(wa, 0)

    def put_byte(self, addr, val):
        wa = addr & ~7
        lane = addr & 7
        cur = self._get(wa)
        self.words[wa] = (cur & ~(0xFF << (8 * lane))) | (val << (8 * lane))

    def get_word(self, addr):
        return self._get(addr & ~7)

    def set_word(self, addr, val):
        self.words[addr & ~7] = val

    def put_tf48(self, base, w48, idx):
        """Упаковать idx-й элемент (48-бит kernel-слово) в байты base+6*idx..+5."""
        off = base + 6 * idx
        for j in range(6):
            self.put_byte(off + j, (w48 >> (8 * j)) & 0xFF)


DESC_BASE = 0x00000000
COMP_BASE = 0x00008000   # в стороне от data-регионов sched-задач (slots могут идти до 0x7xxx)
REGION_BASE = 0x00001000
REGION_STRIDE = 0x1000


class Task:
    def __init__(self, kind, n, data, wgt, result, tag, baseline, align, cfg):
        self.kind = kind
        self.n = n
        self.data = data
        self.wgt = wgt
        self.result = result
        self.tag = tag
        self.baseline = baseline
        self.align = align
        self.cfg = cfg
        self.a_bits = None
        self.b_bits = None
        self.exp_r48 = None
        self.exp_passes = None


# ---------------- сценарии ----------------
def build_cfg_partial():
    cfg = dict(name="cfg_partial", NUM_MAC=16, rd=16, wr=8, tasks=[])
    base = REGION_BASE
    ns = [1, 3, 7, 15, 8, 16, 5]
    for k, n in enumerate(ns):
        t = Task("go", n, base, base + 0x400, base + 0x800, 0, 0, False, cfg["name"])
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    return cfg


def build_cfg_long():
    cfg = dict(name="cfg_long", NUM_MAC=16, rd=16, wr=8, tasks=[])
    base = REGION_BASE
    for k, n in enumerate([17, 40, 100, 48]):
        t = Task("go", n, base, base + 0x400, base + 0x800, 0, 0, False, cfg["name"])
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    return cfg


def build_cfg_sched():
    cfg = dict(name="cfg_sched", NUM_MAC=16, rd=16, wr=8, tasks=[])
    base = REGION_BASE
    for k, (n, tag) in enumerate([(8, 0x2110), (24, 0x2111), (40, 0x2112), (17, 0x2113)]):
        t = Task("sched", n, base, base + 0x400, base + 0x800, tag, 0, False, cfg["name"])
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    return cfg


def build_cfg_align():
    cfg = dict(name="cfg_align", NUM_MAC=16, rd=16, wr=8, tasks=[])
    base = REGION_BASE
    for n in [4, 16]:
        t = Task("go", n, base, base + 0x400, base + 0x800, 0, 0, False, cfg["name"])
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    for k, n in enumerate([3, 7]):
        res = base + 0x800 + 1          # bit0=1 -> PACKED6 мизалайнг (не кратен 8)
        t = Task("go", n, base, base + 0x400, res, 0, 0xABC010001111, True, cfg["name"])
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    for k, n in enumerate([12, 5]):
        if k == 0:
            res = base + 0x800
            t = Task("sched", n, base, base + 0x400, res, 0xAB01, 0, False, cfg["name"])
        else:
            res = base + 0x800 + 1
            t = Task("sched", n, base, base + 0x400, res, 0xAB02,
                     0xC0FFEE003_0B1A, True, cfg["name"])
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    return cfg


def build_cfg_burst():
    cfg = dict(name="cfg_burst", NUM_MAC=32, rd=8, wr=4, tasks=[])
    base = REGION_BASE
    specs = [(32, 0)] * 2 + [(40, 1), (55, 2), (64, 3)]
    for k, (n, _s) in enumerate(specs):
        t = Task("go", n, base, base + 0x400, base + 0x800, 0, 0, False, cfg["name"])
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    return cfg


def build_cfg_mix():
    cfg = dict(name="cfg_mix", NUM_MAC=16, rd=16, wr=8, tasks=[])
    ns = [1, 5, 16, 3, 10, 17, 24, 2, 33, 48, 8, 15, 9, 13, 40, 19]
    base = REGION_BASE
    for k, n in enumerate(ns):
        t = Task("go", n, base, base + 0x400, base + 0x800, 0, 0, False, cfg["name"])
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    return cfg


def build_cfg_mac2():
    """Gap-1 (start_skip != 0) ИНТЕГРАЦИЯ: NUM_MAC=2, long-dot N>2.

    skip=(elems_done*6)%8. При NUM_MAC=2: elems_done = (k-1)*2 на проходе k,
    => skip = ((k-1)*12)%8 = 4 на ЧЁТНЫХ проходах, 0 на нечётных. Это ЕДИНСТВЕННАЯ
    степень-2 NUM_MAC (ядро compute_dot_par_raw держит только degree-2 дерево),
    дающая start_skip=4 СКВОЗЬ полный интеграционный путь (память -> barrel 6->8
    с nbytes=8-4=4 и overlap-перечитыванием слова -> fifo -> дерево -> результат).
    Значения skip=2,6 недостижимы интеграцией при working-degree NUM_MAC и
    покрываются barrel-UNIT-тестом (verify_packed6_rd.py, gap-1*).
    """
    cfg = dict(name="cfg_mac2", NUM_MAC=2, rd=16, wr=8, tasks=[])
    base = REGION_BASE
    # все N>2 -> multi-pass (2,3,4,5 проходов), на 2-м/4-м проходе skip=4.
    for k, n in enumerate([3, 4, 5, 7, 9]):
        t = Task("go", n, base, base + 0x400, base + 0x800, 0, 0, False, cfg["name"])
        cfg["tasks"].append(t)
        base += REGION_STRIDE
    return cfg


ALL_CFG = [build_cfg_partial, build_cfg_long, build_cfg_sched,
           build_cfg_align, build_cfg_burst, build_cfg_mix, build_cfg_mac2]


# ---------------- сборка памяти и эталонов ----------------
def place_mem(cfg):
    NUM_MAC = cfg["NUM_MAC"]
    name_key = sum(ord(c) for c in cfg["name"])
    memobj = Mem()
    sched_slots = []
    for ti, task in enumerate(cfg["tasks"]):
        a_bits, b_bits = gen_tf48_vectors(task.n, name_key + ti * 101 + 5000)
        task.a_bits = a_bits
        task.b_bits = b_bits
        for i, w in enumerate(a_bits):
            memobj.put_tf48(task.data, w, i)
        for i, w in enumerate(b_bits):
            memobj.put_tf48(task.wgt, w, i)
        if task.n <= NUM_MAC:
            r48 = single_chunk_ref(a_bits, b_bits, NUM_MAC)
            passes = 1
        else:
            r48, passes = longdot_ref(a_bits, b_bits, NUM_MAC)
        task.exp_r48 = r48
        task.exp_passes = passes
        if task.align:
            memobj.set_word(task.result, task.baseline)
        else:
            # Gap-2: ядовитые верхние 16 бит слова результата (WSTRB=0x3F не должен их
            # трогать). Если ядро (ошибочно) пишет полное слово, верх станет 0 -> FAIL.
            # Нижние 48 бит тоже не нулевые, чтобы переход на полное слово был заметен.
            memobj.set_word(task.result, (WSTRB_SENT << 48) | 0x0B0B0B0B0B0B)
    idx_sched = 0
    for task in cfg["tasks"]:
        if task.kind != "sched":
            continue
        dbase = DESC_BASE + idx_sched * 32
        memobj.set_word(dbase, task.data & 0xFFFFFFFFFFFF)
        memobj.set_word(dbase + 8, task.wgt & 0xFFFFFFFFFFFF)
        memobj.set_word(dbase + 16, task.result & 0xFFFFFFFFFFFF)
        memobj.set_word(dbase + 24, ((task.n & 0xFFFF) << 16) | (task.tag & 0xFFFF))
        idx_sched += 1
        sched_slots.append(task)
    return memobj, sched_slots


def write_files(cfg):
    memobj, sched_slots = place_mem(cfg)
    with open(os.path.join(SIM, "packed6x_mem.hex"), "w") as f:
        for addr in sorted(memobj.words):
            f.write(f"{addr:08x} {memobj.words[addr]:016x}\n")
    with open(os.path.join(SIM, "packed6x_tasks.txt"), "w") as f:
        for idx, task in enumerate(cfg["tasks"]):
            kind = 1 if task.kind == "go" else 2
            tag = task.tag if task.kind == "sched" else 0
            blo = task.baseline & 0xFFFFFFFF
            bhi = (task.baseline >> 32) & 0xFFFFFFFF
            f.write(f"{kind} {task.n} {task.data} {task.wgt} {task.result} "
                    f"{tag} {blo} {bhi}\n")
    return sched_slots


def run_sim(cfg):
    name = cfg["name"]
    tb_path = os.path.join(RTL, "tb_tdot_axi4_packed6x.sv")
    tb_src = open(tb_path, encoding="utf-8").read()
    tb_src = tb_src.replace("parameter int NUM_MAC = 32;",
                            f"parameter int NUM_MAC = {cfg['NUM_MAC']};")
    tb_src = tb_src.replace("parameter int BURST_RD_LEN = 16;",
                            f"parameter int BURST_RD_LEN = {cfg['rd']};")
    tb_src = tb_src.replace("parameter int BURST_WR_LEN = 8;",
                            f"parameter int BURST_WR_LEN = {cfg['wr']};")
    tb_use = os.path.join(RTL, "tb_tdot_axi4_packed6x_use.sv")
    open(tb_use, "w", encoding="utf-8").write(tb_src)

    import shutil
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
    files_use = [tb_use if os.path.abspath(f) == os.path.abspath(
        os.path.join(RTL, "tb_tdot_axi4_packed6x.sv")) else f for f in FILES]
    run(f'"{xvlog}" -sv {" ".join(files_use)}')
    run(f'"{xelab}" tb_tdot_axi4_packed6x -debug typical')
    run(f'"{xsim}" tb_tdot_axi4_packed6x -runall')
    out = open(os.path.join(SIM, "packed6x_out.hex")).read()
    return out


# ---------------- верификация вывода ----------------
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

    go_results = {}
    cmp = {}
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

    # --- GO ---
    n_go = 0
    for idx, task in enumerate(cfg["tasks"]):
        if task.kind != "go":
            continue
        n_go += 1
        if idx not in go_results:
            check(False, f"cfg {name} GO#{idx}: нет результата в выходе", "")
            continue
        word = go_results[idx]
        got48 = word & 0xFFFFFFFFFFFF
        if task.align:
            check(word == task.baseline,
                  f"{name} GO#{idx}(align n={task.n}): слово НЕ записано (baseline)",
                  f"got={word:016x} baseline={task.baseline:016x}")
        else:
            check(got48 == task.exp_r48,
                  f"{name} GO#{idx}(n={task.n}): результат 48-бит == эталон",
                  f"got48={got48:012x} exp={task.exp_r48:012x}")
            check((word >> 48) == WSTRB_SENT,
                  f"{name} GO#{idx}(n={task.n}): WSTRB=0x3F - верхние 16 бит не тронуты (={WSTRB_SENT:04x})",
                  f"word={word:016x} hi={(word>>48)&0xFFFF:04x} exp={WSTRB_SENT:04x}")

    # --- планировщик ---
    sched_tasks = [t for t in cfg["tasks"] if t.kind == "sched"]
    if sched_tasks:
        want_done = len(sched_tasks)
        n_sched_read = len([idx for idx in cmp if cfg["tasks"][idx].kind == "sched"])
        if sched_sum is not None:
            rptr, done, irq = sched_sum
            check(done == want_done, f"{name} sched: DONE_CNT=={want_done}", f"done={done}")
            check(irq, f"{name} sched: IRQ поднят при опустошении", f"irq={'1' if rptr else '0'}")
        for slot, task in enumerate(sched_tasks):
            idx = cfg["tasks"].index(task)
            if idx not in cmp:
                check(False, f"{name} sched slot{slot}: completion нет", "")
                continue
            w0, w1, rw = cmp[idx]
            tag = (w0 >> 48) & 0xFFFF
            comp48 = w0 & 0xFFFFFFFFFFFF
            passes = (w1 >> 8) & 0xFF
            status = w1 & 0xFF
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
                check(align_bit == 0, f"{name} sched slot{slot}: align=0", f"align={align_bit}")
                check(sat_bit == 0, f"{name} sched slot{slot}: sat=0", f"sat={sat_bit}")
                check(comp48 == task.exp_r48,
                      f"{name} sched slot{slot}(n={task.n}): completion.result 48-бит == эталон",
                      f"got48={comp48:012x} exp={task.exp_r48:012x}")
                check((w0 >> 48) == (task.tag & 0xFFFF),
                      f"{name} sched slot{slot}: tag 48-бит биты", f"w0hi={(w0>>48)&0xFFFF:04x}")
                check(passes == task.exp_passes,
                      f"{name} sched slot{slot}(n={task.n}): passes=={task.exp_passes}",
                      f"passes={passes}")
                check((rw & 0xFFFFFFFFFFFF) == task.exp_r48,
                      f"{name} sched slot{slot}(n={task.n}): result_addr 48-бит == эталон",
                      f"got={rw & 0xFFFFFFFFFFFF:012x} exp={task.exp_r48:012x}")
                check((rw >> 48) == WSTRB_SENT,
                      f"{name} sched slot{slot}(n={task.n}): WSTRB=0x3F - верхние 16 бит не тронуты",
                      f"rw={rw:016x} hi={(rw>>48)&0xFFFF:04x} exp={WSTRB_SENT:04x}")

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


def main():
    which = sys.argv[1:] if len(sys.argv) > 1 else ["cfg_partial", "cfg_long",
                                                     "cfg_sched", "cfg_align",
                                                     "cfg_burst", "cfg_mix",
                                                     "cfg_mac2"]
    os.makedirs(SIM, exist_ok=True)
    total_ok = True
    for build in ALL_CFG:
        cfg = build()
        if cfg["name"] not in which:
            continue
        sched_slots = write_files(cfg)
        out = run_sim(cfg)
        ok = verify_output(cfg, sched_slots, out)
        total_ok = total_ok and ok
    print("\n===== ВСЕ КОНФИГУРАЦИИ:", "PASS" if total_ok else "FAIL", "=====")
    sys.exit(0 if total_ok else 1)


if __name__ == "__main__":
    main()