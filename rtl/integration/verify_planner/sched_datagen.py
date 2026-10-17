"""Generate memory init hex for tdot scheduler emulation test.

Writes C:/Temp/gigatool/sched_mem_init.hex with lines "<addr8hex> <data64hex>"
for descriptor table, data/weights vectors (all 1.0), to be loaded into the
AXI memory model by tb_tdot_sched.sv. Also writes expected_sched.hex (already
done by sched_ref.py) and the task list metadata (n/tag/result_addr) to
sched_tasks.csv for the verifier.
"""
import os, sys, struct, csv
_THIS = os.path.dirname(os.path.abspath(__file__))
_RTL = os.path.abspath(os.path.join(_THIS, "..", ".."))
sys.path.insert(0, _RTL)
sys.path.insert(0, os.path.abspath(os.path.join(_RTL, "..", "ternary_sw")))
from block.tfloat48 import TFloat

ONE = ((TFloat.from_float(1.0).e_int & 0xFF) << 40) | \
      (TFloat.from_float(1.0).m_int & ((1 << 40) - 1))

# memory layout
DESC_BASE   = 0x0000_0000
DATA_BASE   = 0x0000_1000
WGT_BASE    = 0x0000_2000
RES_BASE    = 0x0000_3000
COMP_BASE   = 0x0000_4000

# tasks: (n, tag, data_off, wgt_off, res_off)
TASKS = [
    (8,  0x1111, DATA_BASE + 0x000, WGT_BASE + 0x000, RES_BASE + 0x000),
    (16, 0x2222, DATA_BASE + 0x100, WGT_BASE + 0x100, RES_BASE + 0x100),
    (8,  0x3333, DATA_BASE + 0x200, WGT_BASE + 0x200, RES_BASE + 0x200),
    (24, 0x4444, DATA_BASE + 0x300, WGT_BASE + 0x300, RES_BASE + 0x300),
]

mem = {}   # addr -> 64-bit value


def put64(addr, val):
    mem[addr] = val & 0xFFFFFFFFFFFFFFFF


def main():
    # descriptors (32B each, 4x64 words, LE)
    for i, (n, tag, d, w, r) in enumerate(TASKS):
        base = DESC_BASE + i * 32
        put64(base + 0, d)                       # W0 data_addr
        put64(base + 8, w)                       # W1 weights_addr
        put64(base + 16, r)                      # W2 result_addr
        put64(base + 24, (n << 16) | tag)        # W3 {n[15:0], tag[15:0]}

    # data/weights vectors, all 1.0
    for i, (n, tag, d, w, r) in enumerate(TASKS):
        for k in range(n):
            put64(d + k * 8, ONE)
            put64(w + k * 8, ONE)

    with open(os.path.join(_THIS, "sched_mem_init.hex"), "w") as f:
        for addr in sorted(mem):
            f.write(f"{addr:08x} {mem[addr]:016x}\n")

    with open(os.path.join(_THIS, "sched_tasks.csv"), "w", newline="") as f:
        cw = csv.writer(f)
        cw.writerow(["idx", "n", "tag", "result_addr"])
        for i, (n, tag, d, w, r) in enumerate(TASKS):
            cw.writerow([i, n, f"{tag:04x}", f"{r:08x}"])

    print(f"ONE(1.0)={ONE:012x}")
    print(f"tasks={len(TASKS)} descriptors, descriptors span "
          f"{DESC_BASE:08x}..{DESC_BASE+len(TASKS)*32-1:08x}, "
          f"comp at {COMP_BASE:08x}")
    print(f"mem entries={len(mem)}")


if __name__ == "__main__":
    main()