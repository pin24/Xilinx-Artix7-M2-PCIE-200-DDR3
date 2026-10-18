"""UNIT-верификация barrel packed6_rd.sv (6->8) на путь start_skip != 0 (Gap-1).

Интеграционные конфигурации (verify_tdot_axi4_packed6x.py) дают skip==0 всегда,
т.к. core требует NUM_MAC=2^k и 6*2^k == 0 mod 8 при k>=2; skip=2,6 (и полный
набор nbytes=8-skip на армиге) НЕДОСТИЖИМЫ через ядро. Этот скрипт гонит barrel
НАПРЯМУЮ (tb_packed6_rd.sv), питая 64-бит слова упакованного байт-потока со всеми
start_skip ∈ {0,2,4,6} и мелкими/нечётными n_elem, и сверяет выданные элементы с
эталоном elem_k = bytes[skip+6k : skip+6k+6] (little-endian 48 бит).

Покрывает: армиг при nbytes=8-skip (8,6,4,2); overlap-перечитывание слова на
границе чанка (skip>0); хвостовое слово нечётного чанка; emit РОВНО n_elem.
"""
from __future__ import annotations
import sys, os, subprocess

BLOCK = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(BLOCK, "sim")
sys.path.insert(0, BLOCK)

XIL = os.environ.get("VIVADO_BIN") or "C:/AMDDesignTools/2025.2/Vivado/bin"

BPE = 6
WORD_B = 8


def pack_elem_bytes(w48):
    return [(w48 >> (8 * j)) & 0xFF for j in range(BPE)]


def build_vectors():
    """Для каждого (skip, n_elem) собрать байт-поток и ожидаемые элементы.

    stream = [0]*skip + байты всех элементов; nwords = ceil((skip+6*n_elem)/8).
    Ожидание elem_k = stream[skip+6k : skip+6k+6] (little-endian 48 бит).
    """
    rnd = __import__("random").Random(20261018)
    tests = []  # (skip, n_elem, [elem48...])
    # покрыть все 4 skip; мелкие n_elem (1..7) дают и single- и multi-word чанки,
    # нечётные - частичное хвостовое слово.
    for skip in (0, 2, 4, 6):
        for ne in (1, 2, 3, 4, 5, 6, 7):
            tests.append((skip, ne, None))
    # пара больших для многословного чанка с overlap
    for skip in (2, 6):
        for ne in (9, 17, 41):
            tests.append((skip, ne, None))

    mem = {}
    testlines = []
    for t_id, (skip, ne, _) in enumerate(tests):
        # генерить 48-бит значения с вариативными байтами (каждый байт разный)
        elems = []
        for k in range(ne):
            base = (t_id * 131 + k * 7) & 0xFFFFF
            w = 0
            for j in range(BPE):
                w |= (((base + j * 13) & 0xFF) | ((k & 1) << 7)) << (8 * j)
            elems.append(w & ((1 << 48) - 1))
        tests[t_id] = (skip, ne, elems)

        stream = [0] * skip
        for w in elems:
            stream += pack_elem_bytes(w)
        nwords = (skip + BPE * ne + WORD_B - 1) // WORD_B
        # ВАЖНО: wbase — WORD-индекс (tb читает mem[wbase & 0xFFFF]). Слоты по 64 слова
        # на тест: адреса НЕ перекрываются (34 теста * 64 < 0xFFFF), иначе addr & 0xFFFF
        # даёт коллизии (прежняя ошибка: 0x1000*(id+1) переполняло 16 бит).
        wa = 64 * t_id
        for i in range(nwords):
            word = 0
            for b in range(WORD_B):
                idx = 8 * i + b
                if idx < len(stream):
                    word |= stream[idx] << (8 * b)
            mem[wa + i] = word
        testlines.append((t_id, ne, skip, nwords, wa))
    return mem, testlines, tests


def write_files():
    mem, testlines, tests = build_vectors()
    with open(os.path.join(SIM, "packed6rd_in.hex"), "w") as f:
        for wa in sorted(mem):
            f.write(f"{wa:08x} {mem[wa]:016x}\n")
    with open(os.path.join(SIM, "packed6rd_tests.txt"), "w") as f:
        for (id, ne, skip, nwords, wa) in testlines:
            f.write(f"{id} {ne} {skip} {nwords} {wa:08x}\n")
    return tests


def run_sim():
    import shutil
    for d in ["xsim.dir", "xsim.cmd", "xsim.log"]:
        p = os.path.join(BLOCK, d)
        if os.path.isdir(p):
            shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)
    xvlog = os.path.join(XIL, "xvlog.bat")
    xelab = os.path.join(XIL, "xelab.bat")
    xsim = os.path.join(XIL, "xsim.bat")

    files = ["tb_packed6_rd.sv", "packed6_rd.sv"]

    def run(cmd):
        r = subprocess.run(cmd, shell=True, cwd=BLOCK, capture_output=True, text=True)
        if r.returncode != 0:
            print("CMD FAIL:")
            print(r.stdout[-2500:])
            print(r.stderr[-2500:])
            sys.exit(1)
        return r

    print("[p6rd] xvlog/xelab/xsim ...")
    run(f'"{xvlog}" -sv {" ".join(files)}')
    run(f'"{xelab}" tb_packed6_rd -debug typical')
    run(f'"{xsim}" tb_packed6_rd -runall')
    return open(os.path.join(SIM, "packed6rd_out.hex")).read()


def verify(output, tests):
    emit = {}     # id -> {k: value48}
    drain = {}
    for l in output.splitlines():
        l = l.strip()
        if not l:
            continue
        p = l.split()
        if p[0] == "EMIT":
            emit.setdefault(int(p[1]), {})[int(p[2])] = int(p[3], 16)
        elif p[0] == "DRAIN":
            drain[int(p[1])] = int(p[2])

    checks = []
    ok = True
    for t_id, (skip, ne, elems) in enumerate(tests):
        got = emit.get(t_id, {})
        n_emit = drain.get(t_id, -1)
        # 1) ровно ne элементов
        if n_emit != ne:
            ok = False
            checks.append((f"gap1 test#{t_id} skip={skip} ne={ne}: emit_count=={ne}",
                           False, f"got {n_emit}"))
            continue
        if len(got) != ne:
            ok = False
            checks.append((f"gap1 test#{t_id} skip={skip} ne={ne}: ровно ne EMIT",
                           False, f"got {len(got)}"))
            continue
        # 2) каждый элемент бит-в-бит
        bad = []
        for k in range(ne):
            if got.get(k) != elems[k]:
                bad.append(k)
                ok = False
        checks.append((f"gap1 test#{t_id} (skip={skip}, ne={ne}): все элементы == эталон",
                       not bad,
                       (f"misaligned at {bad}" if bad else "")))
    return ok, checks


def main():
    os.makedirs(SIM, exist_ok=True)
    tests = write_files()
    out = run_sim()
    ok, checks = verify(out, tests)
    n_pass = sum(1 for _, c, _ in checks if c)
    print("\n===== packed6_rd barrel UNIT (Gap-1: skip 0/2/4/6) =====")
    for label, cond, detail in checks:
        print(f"  [{'PASS' if cond else 'FAIL'}] {label}" +
              (f"  ({detail})" if detail and not cond else ""))
    print(f"  --- packed6_rd: {'PASS' if ok else 'FAIL'} ({n_pass}/{len(checks)} проверок) ---")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()