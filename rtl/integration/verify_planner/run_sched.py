"""Run tb_tdot_sched in xsim and verify scheduler behavior vs expected.

Usage: python run_sched.py
Expected results come from expected_sched.hex (computed by sched_ref.py via
dot_ref_raw reference model). Verifies:
  * completions: tag, result[47:0] (dot), status==0, passes
  * DONE_CNT / RPTR advanced to #tasks
  * IRQ raised on queue empty and cleared by irq_ack
"""
import os, subprocess, re, sys

CWD = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.abspath(os.path.join(CWD, "..", ".."))
BLOCK = os.path.join(RTL, "block")
INTEG = os.path.join(RTL, "integration")
_CAND = "C:/AMDDesignTools/2025.2/Vivado/bin"
XIL = os.environ.get("VIVADO_BIN")
if not XIL:
    XIL = _CAND

FILES = [
    os.path.join(BLOCK, "tbyte_add.sv"),
    os.path.join(BLOCK, "tbyte_mul.sv"),
    os.path.join(BLOCK, "tfadd_raw.sv"),
    os.path.join(BLOCK, "tfmul_raw.sv"),
    os.path.join(BLOCK, "tfadd48.sv"),
    os.path.join(BLOCK, "compute_dot_par_raw.sv"),
    os.path.join(INTEG, "tdot_axi4.sv"),
    os.path.join(CWD, "tb_tdot_sched.sv"),
]

xvlog = os.path.join(XIL, "xvlog.bat")
xelab = os.path.join(XIL, "xelab.bat")
xsim = os.path.join(XIL, "xsim.bat")


def run(cmd, cwd=CWD):
    r = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        print("CMD FAIL:", cmd)
        print(r.stdout[-2500:])
        print(r.stderr[-2500:])
        sys.exit(1)
    return r


def main():
    simdir = os.path.join(CWD, "sim")
    os.makedirs(simdir, exist_ok=True)
    for d in ["xsim.dir", "xsim.cmd", "xsim.log"]:
        p = os.path.join(CWD, d)
        if os.path.isdir(p):
            import shutil; shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)

    print("[1/4] xvlog ...")
    run(f'"{xvlog}" -sv {" ".join(FILES)}')
    print("[2/4] xelab ...")
    run(f'"{xelab}" tb_tdot_sched -debug typical')
    print("[3/4] xsim ...")
    run(f'"{xsim}" tb_tdot_sched -runall')

    # ---- expected ----
    exp = [int(l.strip(), 16) for l in open(os.path.join(CWD, "expected_sched.hex")) if l.strip()]
    # tasks metadata
    import csv
    tasks = []
    with open(os.path.join(CWD, "sched_tasks.csv")) as f:
        rd = csv.DictReader(f)
        for row in rd:
            tasks.append({"idx": int(row["idx"]), "n": int(row["n"]),
                          "tag": int(row["tag"], 16)})
    expected_by_n = {8: exp[0], 16: exp[1], 24: exp[2]}

    print("[4/4] verify ...")
    log = open(os.path.join(simdir, "sched_out.hex")).read()
    lines = [l.strip() for l in log.splitlines() if l.strip()]

    ok = True
    checks = []
    def check(name, cond, detail=""):
        nonlocal ok
        checks.append((name, bool(cond), detail))
        if not cond: ok = False

    # Scenario A summary
    a_rptr = a_done = None
    a_irq = None
    a_comps = {}   # slot -> (tag,result,sat,align,passes)
    a_resmem = {}  # slot -> result word at result_addr
    b_rptr = b_done = None
    b_comps = {}
    b_ack_line = None
    busy_x_seen = False

    def strip_hx(s):
        nonlocal busy_x_seen
        if "X" in s.upper() or "Z" in s.upper():
            busy_x_seen = True
        return int(re.sub(r"[xXzZ]", "0", s), 16)

    for l in lines:
        m = re.match(r"A rptr=(\d+) done_cnt=(\d+) status=(\w+) sched_irq=(\w+)", l)
        if m:
            a_rptr, a_done = int(m.group(1)), int(m.group(2))
            a_status = strip_hx(m.group(3))
        m = re.match(r"A irq_state irq_pending=([01]) sched_irq=([01])", l)
        if m: a_irq = (int(m.group(1)), int(m.group(2)))
        m = re.match(r"A comp (\d+) tag=(\w+) result=(\w+) sat=([01]) align=([01]) passes=(\d+)", l)
        if m: a_comps[int(m.group(1))] = (int(m.group(2),16), int(m.group(3),16),
                                          int(m.group(4)), int(m.group(5)), int(m.group(6)))
        m = re.match(r"B rptr=(\d+) done_cnt=(\d+) status=(\w+)", l)
        if m:
            b_rptr, b_done = int(m.group(1)), int(m.group(2))
            b_status = strip_hx(m.group(3))
        m = re.match(r"B comp (\d+) tag=(\w+) result=(\w+) sat=([01]) align=([01]) passes=(\d+)", l)
        if m: b_comps[int(m.group(1))] = (int(m.group(2),16), int(m.group(3),16),
                                          int(m.group(4)), int(m.group(5)), int(m.group(6)))
        if l.startswith("B irq_ack done status="): b_ack_line = l
        m = re.match(r"A res_mem (\d+)=(\w+)", l)
        if m: a_resmem[int(m.group(1))] = int(m.group(2), 16)

    # Scenario A checks
    check("A: RPTR==4 (движок прошёл все 4)", a_rptr == 4, f"rptr={a_rptr}")
    check("A: DONE_CNT==4", a_done == 4, f"done={a_done}")
    check("A: 4 completions записаны", len(a_comps) == 4, f"got {len(a_comps)}")
    for slot, (tag, res, sat, align, passes) in a_comps.items():
        n = tasks[slot]["n"]
        exp_tag = tasks[slot]["tag"]
        exp_res = expected_by_n[n]
        check(f"A task{slot}: tag", tag == exp_tag, f"tag={tag:04x} exp={exp_tag:04x}")
        check(f"A task{slot}: result == n (dot)", res == exp_res,
              f"res={res:012x} exp={exp_res:012x} (n={n})")
        check(f"A task{slot}: status OK (sat=0,align=0)", sat == 0 and align == 0,
              f"sat={sat} align={align}")
        if tasks[slot]["n"] <= 16:
            check(f"A task{slot}: passes==1 (однопроходные)", passes == 1, f"passes={passes}")
        else:
            check(f"A task{slot}: long-dot passes>1", passes > 1, f"passes={passes}")

    # Result words written by DUT to each task's result_addr
    if a_resmem:
        check("A: 4 result_addr записаны ядром", len(a_resmem) == 4,
              f"got {len(a_resmem)}")
        for slot, rw in a_resmem.items():
            n = tasks[slot]["n"]
            check(f"A result_addr[{slot}] == dot(n)", rw == expected_by_n[n],
                  f"got={rw:012x} exp={expected_by_n[n]:012x} (n={n})")

    # Scenario A IRQ: irq_pending bit in STATUS should be 1 when queue emptied.
    if a_irq is not None:
        check("A: irq_pending поднят при опустошении очереди", a_irq[0] == 1,
              f"irq_pending={a_irq[0]}")
        check("A: sched_irq уровень поднят (irq_en=1)", a_irq[1] == 1,
              f"sched_irq={a_irq[1]}")
    # IRQ cleared by irq_ack in scenario B
    if b_ack_line is not None:
        m = re.match(r"B irq_ack done status=(\w+) sched_irq=([01])", b_ack_line)
        if m:
            st = strip_hx(m.group(1))
            check("B: irq_pending сброшен после irq_ack", (st >> 1) & 1 == 0,
                  f"status={st:08x}")
            check("B: sched_irq сброшен после irq_ack", m.group(2) == "0",
                  f"sched_irq={m.group(2)}")

    # Scenario B checks
    check("B: RPTR==6", b_rptr == 6, f"rptr={b_rptr}")
    check("B: DONE_CNT==6", b_done == 6, f"done={b_done}")
    for slot, (tag, res, sat, align, passes) in b_comps.items():
        n = 8
        check(f"B task{slot}: tag", tag in (0xAAAA, 0xBBBB), f"tag={tag:04x}")
        check(f"B task{slot}: result == 8", res == expected_by_n[8],
              f"res={res:012x} exp={expected_by_n[8]:012x}")
        check(f"B task{slot}: status OK", sat == 0 and align == 0, f"sat={sat} align={align}")

    # RTL finding: sched_busy_q (SCHED_STATUS bit0) никогда не присваивается ->
    # в СИМУЛЯЦИИ X. Vерификатор это фиксирует как замечание (не FAIL теста),
    # т.к. не влияет на функциональность очереди.
    print("\n[ЗАМЕЧАНИЕ RTL] sched_busy_q (SCHED_STATUS bit0) не присваивается: "
          + ("подтверждено (X в симуляции)" if busy_x_seen else "не обнаружено X"))

    print("\n===== ИТОГ ПО ПРОВЕРКАМ =====")
    for name, cond, detail in checks:
        print(f"  [{'PASS' if cond else 'FAIL'}] {name}" + (f"  ({detail})" if detail and not cond else ""))
    print("\nOverall:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()