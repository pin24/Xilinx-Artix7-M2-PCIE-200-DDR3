"""Reference generator for tdot scheduler emulation test.

Computes expected 48-bit TFloat48 results via the SAME reference used by
verify_tdot_axi4.py (dot_ref_raw) for all-1.0 vectors of varying lengths.
Writes expected_sched.hex (one result per task) and prints decimals.
"""
import os, sys, struct
_THIS = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.abspath(os.path.join(_THIS, "..", ".."))
sys.path.insert(0, RTL)
sys.path.insert(0, os.path.abspath(os.path.join(RTL, "..", "ternary_sw")))
import verify_tdot_axi4 as V
from block.tfloat48 import TFloat


def to_bits48(t):
    return ((t.e_int & 0xFF) << 40) | (t.m_int & ((1 << 40) - 1))


def ref_dot(n):
    a = [to_bits48(TFloat.from_float(1.0)) for _ in range(n)]
    b = [to_bits48(TFloat.from_float(1.0)) for _ in range(n)]
    return V.dot_ref_raw(a, b)


def main():
    tasks = [8, 16, 24]
    out = []
    for n in tasks:
        bits = ref_dot(n)
        out.append(bits)
        t = TFloat.from_bits(((bits & ((1 << 40) - 1)) << 8) | ((bits >> 40) & 0xFF))
        val = t.to_float()
        print(f"n={n}: bits={bits:012x}  value={val:.9g}  (expected {n})")
    with open(os.path.join(_THIS, "expected_sched.hex"), "w") as f:
        for b in out:
            f.write(f"{b:012x}\n")
    print("Wrote expected_sched.hex (", len(out), "results )")


if __name__ == "__main__":
    main()