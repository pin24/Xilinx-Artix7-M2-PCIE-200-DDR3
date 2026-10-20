#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mailbox_check.py — мини-проверка канала чтения completion-mailbox на железе.

Валидирует host-инфраструктуру device-side completion mailbox (WAITW-аналог,
см. pytorch_layer/xdma_driver.py::CompletionMailbox и
docs/device-prog-2026-10-20.md, секция «Completion mailbox»).

Это НЕ настоящий device-side триггер: статус-слово в DRAM пишет сам HOST через
write_dma (движок ждёт RTL, п.2/4). Цель — убедиться, что
  (1) адрес mailbox-слота свободен и не пересекается с desc/comp/result/selftest;
  (2) write_flag + read_status (запись слова через write_dma, чтение через
      read_dma одного 64-битного слова) возвращают тот же LSW;
  (3) read_status с ожиданием конкретного значения и таймаутом ведёт себя
      корректно (в т.ч. таймаут при «движок не пишет»).

Использование:
    python scripts/mailbox_check.py            # авто-детект устройства
    python scripts/mailbox_check.py --base 0x120000
    python scripts/mailbox_check.py --no-status # только round-trip, без чтения статус-слота
"""
from __future__ import annotations
import os
import sys
import time
import argparse
import struct

_RL = os.path.dirname(os.path.abspath(__file__))
for _p in (os.path.join(_RL, "..", "pytorch_layer"),):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from xdma_driver import (  # noqa: E402
    XdmaError, CompletionMailbox, MAILBOX_OFF,
    MAILBOX_FLAG_OFF, MAILBOX_STATUS_OFF, MAILBOX_STATUS_DONE, MAILBOX_STRIDE,
    SCHED_DESC_OFF, SCHED_COMP_OFF,
)


def _open_device(dev: str | None):
    """Открыть плату: XdmaWinDma (Windows, \\\\.\\XDMA0dma) или XdmaLinux."""
    if sys.platform.startswith("win"):
        from test_dma_win import XdmaWinDma
        return XdmaWinDma(base=dev or r"\\.\XDMA0dma")
    from xdma_driver import XdmaLinux
    return XdmaLinux(base=dev or "/dev/xdma0")


def _check_no_overlap(base: int) -> None:
    """Проверить, что mailbox-слоты не пересекаются с desc/comp/data/selftest.

    Занятые регионы DDR3 (docs/ADDRESS_MAP.md §6): таблица дескрипторов
    [0x0010_0000, +32 КБ), завершения [0x0011_0000, +16 КБ), data/weights
    планировщика [0x0020_0000, +8 МБ), selftest [0x0100_0000, …).
    """
    occupied = [
        ("desc",      SCHED_DESC_OFF, SCHED_DESC_OFF + 0x8000),                 # +32 КБ
        ("comp",      SCHED_COMP_OFF, SCHED_COMP_OFF + 0x4000),                 # +16 КБ
        ("data+weights", 0x0020_0000, 0x0020_0000 + (8 << 20)),                 # +8 МБ
        ("selftest", 0x0100_0000,     0x0100_0000 + (4 << 20)),                 # +4 МБ
    ]
    slot_lo = base
    slot_hi = base + MAILBOX_STRIDE
    conflicts = [name for name, a_lo, a_hi in occupied
                 if slot_lo < a_hi and a_lo < slot_hi]
    if conflicts:
        free_from = SCHED_COMP_OFF + 0x4000        # конец области завершений
        free_to = 0x0020_0000                      # начало data планировщика
        raise XdmaError(
            f"mailbox base 0x{base:X} пересекается с регионами: "
            f"{', '.join(conflicts)}. Свободный промежуток: "
            f"0x{free_from:X}..0x{free_to:X} (и выше 0x{free_to + (8 << 20):X} "
            f"до selftest 0x0100_0000). Рекомендованный адрес: 0x0012_0000.")
    print(f"  адрес mailbox 0x{base:X}: свободен (вне desc/comp/data/selftest) — OK")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", type=lambda s: int(s, 0), default=MAILBOX_OFF,
                    help=f"смещение mailbox-слота в DDR3 (по умолч. 0x{MAILBOX_OFF:X})")
    ap.add_argument("--dev", default=None, help="устройство (по умолч. авто)")
    ap.add_argument("--no-status", action="store_true",
                    help="проверить только write_flag/read_status round-trip, "
                         "без отдельного шага ожидания статус-слота")
    args = ap.parse_args(argv)

    try:
        dev = _open_device(args.dev)
    except Exception as e:
        print(f"ERROR: не могу открыть устройство: {e}")
        print("  — драйвер установлен? плата видна? (XDMA0dma на Windows / /dev/xdma0)")
        return 1

    try:
        mb = CompletionMailbox(dev, base_addr=args.base)
        _check_no_overlap(args.base)

        # --- 1. write_flag: host пишет флаг готовности ---
        flag = 0xCAFE_0001
        mb.write_flag(flag)
        rb = dev.read_dma(args.base + MAILBOX_FLAG_OFF, 8)
        got_flag = struct.unpack("<Q", rb[:8])[0]
        ok_flag = got_flag == (flag & 0xFFFFFFFFFFFFFFFF)
        print(f"write_flag(0x{flag:X}): readback=0x{got_flag:016X} "
              f"{'OK' if ok_flag else 'FAIL'}")
        if not ok_flag:
            return 2

        # --- 2. read_status: ждём конкретное значение (пишем сами как «движок») ---
        status = MAILBOX_STATUS_DONE
        dev.write_dma(args.base + MAILBOX_STATUS_OFF, struct.pack("<Q", status))
        # addr передаём как ОТНОСИТЕЛЬНОЕ смещение от base (read_status сам
        # складывает его с base через CompletionMailbox._slot).
        got = mb.read_status(addr=MAILBOX_STATUS_OFF,
                             timeout_ms=3000.0, expected=status)
        ok_status = got == status
        print(f"read_status(expect 0x{status:X}): got LSW=0x{got:X} "
              f"{'OK' if ok_status else 'FAIL'}")
        if not ok_status:
            return 2

        # --- 3. (опц.) таймаут при свободном слоте (движок не пишет) ---
        if not args.no_status:
            clear_rel = MAILBOX_STATUS_OFF + MAILBOX_STRIDE   # относительное смещение
            dev.write_dma(args.base + clear_rel, struct.pack("<Q", 0))  # слот свободен
            t0 = time.monotonic()
            try:
                mb.read_status(addr=clear_rel, timeout_ms=500.0, expected=0)
                print("  ! read_status на свободном слоте не поднял таймаут — FAIL")
                return 2
            except XdmaError:
                dt = (time.monotonic() - t0) * 1e3
                print(f"  read_status на свободном слоте: таймаут через {dt:.0f} мс — OK")

        print("mailbox_check: ВСЁ OK")
        return 0
    finally:
        try:
            dev.close()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())