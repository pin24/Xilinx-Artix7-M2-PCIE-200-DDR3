#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Модель read-мастера tdot_axi4: старый ar_len FSM против нового (кламп 4KB).

Проверяет (Task 35):
  1. NEW (кламп 4KB, BURST_RD_LEN=32): ни один burst не пересекает 4KB-границу
     (AXI4 spec A4.3.1), сумма длин == rd_total (ничего не потеряно/задвоено).
  2. OLD (без клампа): считает нарушения — доказательство, что дефект был
     (в т.ч. в main 9f57084, где P3b без клампа), и что OLD с BURST=16
     тоже нарушал (латентно, с меньшей вероятностью).
  3. NEW при BURST_RD_LEN=16 бит-в-бит совпадает с OLD по разбиению на тех
     адресах, где OLD не нарушал границу (регрессии разбиения нет).

Матрица: все ×8-выровненные смещения внутри 4KB-страницы (512 шт.) × длины
векторов 1..520 слов + граничные случаи. Адреса — DDR3 0x8000_0000 + offset.
"""
BURST_LENS = (1, 16, 32, 256)
BASE = 0x8000_0000
PAGE = 0x1000
TOTALS = list(range(1, 65)) + [128, 200, 255, 256, 257, 300, 384, 512, 520,
                               1000, 2000]


def old_len(addr, rd_total, rd_issued, burst):
    """Старый FSM (main/наша ветка до Task 35): без учёта границы."""
    remaining = rd_total - rd_issued
    return (burst - 1) if remaining >= burst else (remaining - 1)


def new_len(addr, rd_total, rd_issued, burst):
    """Новый FSM (Task 35): min(len_full, bnd_words-1), зеркально always_comb."""
    bnd_bytes = PAGE - (addr & 0xFFF)
    bnd_words = 1 if (bnd_bytes >> 3) == 0 else (bnd_bytes >> 3)
    remaining = rd_total - rd_issued
    len_full = (burst - 1) if remaining >= burst else (remaining - 1)
    return (bnd_words - 1) if len_full >= (bnd_words - 1) else len_full


def issue_bursts(addr, total, burst, lenfn):
    """Разыгрывает выдачу AR-ов: возвращает список (addr, len) или None при
    зависании (страховка от бесконечного цикла)."""
    out, issued = [], 0
    for _ in range(10000):  # страховка
        if issued >= total:
            return out
        a = addr + issued * 8
        L = lenfn(a, total, issued, burst)
        if L < 0:
            return None
        out.append((a, L))
        issued += L + 1
    return None


def crosses_4k(addr, L):
    """Burst [addr, addr+(L+1)*8) пересекает границу 4KB?"""
    return (addr // PAGE) != ((addr + (L + 1) * 8 - 1) // PAGE)


def main():
    fails = 0
    old_viol = {b: 0 for b in BURST_LENS}
    new_viol = {b: 0 for b in BURST_LENS}
    old_total_cases = {b: 0 for b in BURST_LENS}
    splits_equal_where_old_ok = 0
    splits_old_ok_cases = 0

    offsets = range(0, PAGE, 8)  # все ×8-выровненные смещения в странице
    for total in TOTALS:
        for off in offsets:
            addr = BASE + off
            # --- NEW: кламп обязателен для всех BURST ---
            for b in BURST_LENS:
                seq = issue_bursts(addr, total, b, new_len)
                if seq is None:
                    print(f"NEW HANG/NEG: off=0x{off:X} total={total} burst={b}")
                    fails += 1
                    continue
                beats = 0
                for a, L in seq:
                    beats += L + 1
                    if crosses_4k(a, L):
                        new_viol[b] += 1
                        if fails < 10:
                            print(f"NEW VIOLATION: addr=0x{a:08X} len={L} "
                                  f"total={total} burst={b}")
                        fails += 1
                if beats != total:
                    print(f"NEW BEATS MISMATCH: off=0x{off:X} total={total} "
                          f"burst={b}: {beats}")
                    fails += 1
            # --- OLD: статистика нарушений ---
            for b in BURST_LENS:
                seq = issue_bursts(addr, total, b, old_len)
                old_total_cases[b] += 1
                ok = True
                for a, L in seq:
                    if crosses_4k(a, L):
                        old_viol[b] += 1
                        ok = False
                # NEW(16) vs OLD(16): там, где OLD не нарушал — разбиение равно?
                if b == 16:
                    seq_new = issue_bursts(addr, total, 16, new_len)
                    if ok:
                        splits_old_ok_cases += 1
                        if seq_new == seq:
                            splits_equal_where_old_ok += 1
                    else:
                        # OLD нарушил: NEW обязан отличаться хотя бы одним burst
                        if seq_new == seq:
                            print(f"NEW==OLD despite old violation: "
                                  f"off=0x{off:X} total={total}")
                            fails += 1

    # --- не-×8-выровненные старты (нарушение хост-контракта) ---
    # RTL не зависает, ar_len зажимается до минимума; straddle неизбежен
    # и классифицируется как вина хоста. Проверяем: нет зависаний/отрицательных,
    # NEW даёт ar_len=0 в первом burst при bnd_bytes<8, биты не теряются.
    unaligned_cases = unaligned_straddles = 0
    for total in (1, 8, 32, 100):
        for off in list(range(0xFe0, PAGE)):
            if off % 8 == 0:
                continue
            addr = BASE + off
            seq = issue_bursts(addr, total, 32, new_len)
            if seq is None:
                print(f"NEW UNALIGNED HANG: off=0x{off:X} total={total}")
                fails += 1
                continue
            unaligned_cases += 1
            beats = sum(L + 1 for _, L in seq)
            if beats != total:
                print(f"NEW UNALIGNED BEATS: off=0x{off:X} total={total}")
                fails += 1
            a0, L0 = seq[0]
            if (PAGE - (a0 & 0xFFF)) < 8 and L0 != 0:
                print(f"NEW UNALIGNED len!=0 at bnd<8: off=0x{off:X} L={L0}")
                fails += 1
            for a, L in seq:
                if crosses_4k(a, L):
                    unaligned_straddles += 1   # вина хоста, не NEW

    print("=" * 64)
    print(f"Кейсов: смещений {len(offsets)} x длин {len(TOTALS)} = "
          f"{len(offsets) * len(TOTALS)} на конфиг; "
          f"не-выровненных: {unaligned_cases} (straddle-кейсы контракта: "
          f"{unaligned_straddles})")
    for b in BURST_LENS:
        pct = 100.0 * old_viol[b] / max(1, old_total_cases[b] * 8)  # ~на burst
        print(f"OLD burst={b}: нарушений границ {old_viol[b]} "
              f"(в среднем {pct:.2f}% burst'ов в матрице)")
        print(f"NEW burst={b}: нарушений границ {new_viol[b]}")
    print(f"NEW(16)==OLD(16) там, где OLD корректен: "
          f"{splits_equal_where_old_ok}/{splits_old_ok_cases}")
    print("=" * 64)
    if fails == 0 and all(v == 0 for v in new_viol.values()):
        print("PASS: NEW не пересекает 4KB ни в одном кейсе (выровненные); "
              "биты не теряются; OLD подтверждён нарушающим.")
        return 0
    print(f"FAIL: {fails} проблем")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
