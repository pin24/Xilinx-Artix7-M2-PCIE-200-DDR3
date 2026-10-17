"""Data + reference generator for tdot scheduler emulation at NUM_MAC=32/ADDERS=16.

Writes C:/Temp/gigatool/sched32_mem_init.hex (lines "<addr8hex> <data64hex>")
for descriptors, data/weights (all 1.0) loaded by tb_tdot_sched32.sv into the
AXI memory model, plus sched32_expected.hex and sched32_tasks.csv for the
verifier.

Scenarios (all at NUM_MAC=32, MAX_N_TOTAL=512):
  A  SANITY : 4 tasks n=8,32,16,40, tags 0x1111..0x4444, one doorbell
  B  REARM  : irq_ack then 2 more tasks (n=8, tags 0xAAAA/0xBBBB)
  C  SAT    : 1 task n=700 (clamped->512, sat flag, passes=16)
  W  WRAP   : 260 tasks n=2, distinct tags; slots 0..255 preloaded, slots
              0..3 get REWRITTEN (by TB) to tasks 256..259 after first pass ->
              proves rptr wrap mod 256 + descriptor re-fetch.

Memory (1MB model):
  DESC_BASE 0x0000_0000 (256 slots * 32B = 8KB -> until 0x0000_1FFF)
  DATA_POOL 0x0000_2000 (512 pairs * 8B of 1.0)
  WGT_POOL  0x0000_3000 (512 pairs * 8B of 1.0)
  RES_POOL  0x0000_5000 (per-task result 8B)
  COMP_BASE 0x0000_6000 (256 completions * 16B)
"""
import os, sys, struct, csv
_THIS = os.path.dirname(os.path.abspath(__file__))
_RTL = os.path.abspath(os.path.join(_THIS, "..", ".."))
sys.path.insert(0, _RTL)
sys.path.insert(0, os.path.abspath(os.path.join(_RTL, "..", "ternary_sw")))
from block.tfloat48 import TFloat
import verify_tdot_axi4 as V

ONE = ((TFloat.from_float(1.0).e_int & 0xFF) << 40) | \
      (TFloat.from_float(1.0).m_int & ((1 << 40) - 1))

DESC_BASE = 0x0000_0000
DATA_POOL = 0x0000_2000
WGT_POOL  = 0x0000_3000
RES_POOL  = 0x0000_5000
COMP_BASE = 0x0000_6000

NUM_MAC = 32
MAX_PASSES = 16
MAX_N_TOTAL = MAX_PASSES * NUM_MAC  # 512

mem = {}
res_map = {}   # (scenario, seq) -> result_addr  (for the TB result-region check)


def put64(a, v):
    mem[a] = v & 0xFFFFFFFFFFFFFFFF


def put_desc(slot, da, wa, ra, n, tag):
    base = DESC_BASE + (slot & 0xFF) * 32
    put64(base + 0, da)
    put64(base + 8, wa)
    put64(base + 16, ra)
    put64(base + 24, (n << 16) | (tag & 0xFFFF))


def ones_region(base, n):
    for k in range(n):
        put64(base + k * 8, ONE)


def ref_dot(n):
    a = [ONE] * n
    b = [ONE] * n
    return V.dot_ref_raw(a, b)


def main():
    # ---- ones pools (covers max n=512 for SAT and any small task) ----
    ones_region(DATA_POOL, 512)
    ones_region(WGT_POOL, 512)

    tasks_meta = []  # (scenario, slot, n, tag)

    # A: SANITY 4 tasks n=8,32,16,40 single doorbell
    for i, n in enumerate([8, 32, 16, 40]):
        tag = 0x1111 + i
        ra = RES_POOL + i * 8
        put_desc(i, DATA_POOL, WGT_POOL, ra, n, tag)
        res_map[('A', i)] = ra
        tasks_meta.append(('A', i, n, tag))

    # B: REARM 2 tasks n=8
    for i, tag in enumerate([0xAAAA, 0xBBBB]):
        slot = 4 + i
        ra = RES_POOL + slot * 8
        put_desc(slot, DATA_POOL, WGT_POOL, ra, 8, tag)
        res_map[('B', i)] = ra
        tasks_meta.append(('B', slot, 8, tag))

    # C: SAT n=700 -> clamp 512 (descriptor NOT preloaded in file: it would
    #    overwrite slot 0 needed by A's task0. TB writes it at runtime in C.)
    res_map[('C', 0)] = RES_POOL + 0x400
    tasks_meta.append(('C', 0, 700, 0xC0DE))

    # W: WRAP 256 tasks n=2, tags 0x0000..0x00FF in slots 0..255.
    #    NOT preloaded into the file (would clobber A/B/C slots 0..5 before those
    #    scenarios run): the TB programmatically writes slots 0..255 descriptors
    #    before scenario W, and rewrites slots 0..3 to tasks 256..259
    #    (tags 0x0100..0x0103) after the first pass -> proves wrap + re-fetch.
    tasks_meta.extend(('W', i, 2, i & 0xFFFF) for i in range(256))
    tasks_meta.extend(('W', 256 + i, 2, (0x0100 + i) & 0xFFFF) for i in range(4))

    # write memory init
    with open(os.path.join(_THIS, "sched32_mem_init.hex"), "w") as f:
        for addr in sorted(mem):
            f.write(f"{addr:08x} {mem[addr]:016x}\n")

    # expected results per distinct n (all-ones dot)
    distinct_n = sorted({t[2] for t in tasks_meta})
    exp = {}
    for n in distinct_n:
        eff = min(n, MAX_N_TOTAL)
        exp[n] = ref_dot(eff)
        t = TFloat.from_bits(((exp[n] & ((1 << 40) - 1)) << 8) | ((exp[n] >> 40) & 0xFF))
        print(f"n={n} (eff={eff}): bits={exp[n]:012x} value={t.to_float():.9g}")

    with open(os.path.join(_THIS, "sched32_expected.hex"), "w") as f:
        for n in distinct_n:
            f.write(f"{exp[n]:012x}\n")
    # map n -> expected bits
    with open(os.path.join(_THIS, "sched32_exp_by_n.hex"), "w") as f:
        for n in distinct_n:
            f.write(f"{n} {exp[n]:012x}\n")

    with open(os.path.join(_THIS, "sched32_tasks.csv"), "w", newline="") as f:
        cw = csv.writer(f)
        cw.writerow(["scen", "slot", "n", "tag"])
        for row in tasks_meta:
            cw.writerow([row[0], row[1], row[2], f"{row[3]:04x}"])

    print(f"ONE(1.0)={ONE:012x}")
    print(f"NUM_MAC={NUM_MAC} MAX_N_TOTAL={MAX_N_TOTAL}")
    print(f"tasks={len(tasks_meta)}, mem entries={len(mem)}")
    print(f"expected per n: { {n: f'{exp[n]:012x}' for n in distinct_n} }")


if __name__ == "__main__":
    main()