#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""probe_engine_regs.py — ТОЛЬКО ЧТЕНИЕ. Диагностика XDMA H2C/C2H и DDR3-чтения.

Аудит 2026-10-21 (rerun). Скрипт НЕ пишет в плату: в нём нет ни одного
WriteFile / WRITE_REGISTER, все handle открываются с GENERIC_READ.

Что читается
------------
1) config-BAR через узел \\control (драйвер: file_io.c:147-149 -> configBarIdx;
   ReadBarToRequest file_io.c:305-356 читает ЛЮБОЕ смещение BAR):
     H2C_0 : identifier 0x00, control 0x04, status 0x40, completedDescCount 0x48,
             alignments 0x4C
     C2H_0 : те же +0x1000
     SGDMA : firstDescLo/Hi/Adj 0x4080/84/88 (H2C), 0x5080/84/88 (C2H)
     IRQ   : channelIntEnable 0x2010, channelIntRequest 0x2044,
             channelIntPending 0x204C
     CONFIG: msiEnable 0x3014, pcieWidth 0x3018
   ВАЖНО: 0x44/0x1044 (statusRC) — read-and-clear, по умолчанию НЕ читаются;
   включаются только флагом --allow-readclear (осознанное решение оператора).
2) AXI-Lite через \\user (--tdot): MAGIC 0x23068, CORE_PARAMS 0x23064
   (смещения = addr - 0x4000_0000, см. test_dma_win.py:171-186).
3) c2h-чтение DDR3 (--verify-ddr3): сверка 64 Б по 0x0100_0000 с эталонным
   LCG-паттерном прошлого selftest (xdma_driver.py:1384) и hex-dump областей
   дескрипторов 0x0010_0000 / завершений 0x0011_0000 (xdma_driver.py:916-917).
   Это проверяет, что c2h возвращает РЕАЛЬНЫЕ данные DDR3, а не нули от
   преждевременного завершения поллинга (dma_engine.c:1566/1592).
4) IOCTL_XDMA_DIAG_GET (--diag, индексы 0x06, xdma_public.h:71) на h2c_0 и c2h_0:
   progDmaCalls / bytesTransferred. Только чтение диагностических полей
   (file_io.c:655-671).

Примеры
-------
    python probe_engine_regs.py                 # регистры + IRQ + diag
    python probe_engine_regs.py --verify-ddr3   # + проверка чтения DDR3
    python probe_engine_regs.py --tdot          # + MAGIC/CORE_PARAMS ядра

Коды возврата: 0 — всё прочитано; 2 — устройство/узел недоступен.
"""
from __future__ import annotations

import argparse
import ctypes
import struct
import sys
from ctypes import wintypes

DEV_BASE = r"\\.\XDMA0dma"
GENERIC_READ = 0x80000000
OPEN_EXISTING = 3
FILE_FLAG_OVERLAPPED = 0x40000000
ERROR_IO_PENDING = 997
WAIT_TIMEOUT = 258

IOCTL_XDMA_DIAG_GET = (0x22 << 16) | (0x06 << 2)
XDMA_DIAG_FMT = "<IIQ"

# ---- engine / block offsets (libxdma/reg.h:41-47, 119-147, 150-212) ----
ENG_ID = 0x00
ENG_CONTROL = 0x04
ENG_STATUS = 0x40
ENG_STATUS_RC = 0x44          # read-and-clear: только по флагу
ENG_COMPLETED = 0x48
ENG_ALIGN = 0x4C
SGDMA_FIRSTDESC_LO = 0x80     # + SGDMA_BLOCK_OFFSET 0x4000
SGDMA_FIRSTDESC_HI = 0x84
SGDMA_FIRSTDESC_ADJ = 0x88
SGDMA_OFF_H2C = 0x4000
SGDMA_OFF_C2H = 0x5000
IRQ_CH_INT_ENABLE = 0x2010
IRQ_CH_INT_REQUEST = 0x2044
IRQ_CH_INT_PENDING = 0x204C
CFG_MSI_ENABLE = 0x3014
CFG_PCIE_WIDTH = 0x3018

CTRL_BITS = [
    (0, "RUN"), (1, "IE_DESC_STOPPED"), (2, "IE_DESC_COMPLETED"),
    (3, "IE_ALIGN"), (4, "IE_MAGIC"), (5, "IE_INVALID_LEN"),
    (6, "IE_IDLE_STOPPED"), (25, "NON_INCR_ADDR"), (26, "POLL_MODE"),
    (31, "RST"),
]
STATUS_BITS = [
    (0, "BUSY"), (1, "DESC_STOPPED"), (2, "DESC_COMPLETED"),
    (3, "ALIGN_MISMATCH"), (4, "MAGIC_STOPPED"), (5, "FETCH_STOPPED"),
    (6, "IDLE_STOPPED"),
]
STATUS_ERR_RANGES = [(9, 5, "READ_ERROR"), (14, 5, "WRITE_ERROR"), (19, 5, "DESC_ERROR")]
ALIGN_FIELDS = [("addr_bits", 0x000000FF), ("granularity", 0x0000FF00), ("align_bytes", 0x00FF0000)]


class OVERLAPPED(ctypes.Structure):
    _fields_ = [
        ("Internal", ctypes.c_void_p),
        ("InternalHigh", ctypes.c_void_p),
        ("Offset", wintypes.DWORD),
        ("OffsetHigh", wintypes.DWORD),
        ("hEvent", wintypes.HANDLE),
    ]


def _decode(value: int, table, err_ranges) -> str:
    on = [name for bit, name in table if value & (1 << bit)]
    for lo, width, name in err_ranges:
        field = (value >> lo) & ((1 << width) - 1)
        if field:
            on.append(f"{name}={field:#x}")
    return " ".join(on) if on else "-"


class EngineProbe:
    """Read-only доступ к узлам драйвера \\\\.\\XDMA0dma."""

    def __init__(self, base: str = DEV_BASE):
        self.k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.k32.CreateFileW.restype = wintypes.HANDLE
        self.k32.CreateFileW.argtypes = [
            wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
            wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        self.k32.ReadFile.argtypes = [
            wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
        self.k32.GetOverlappedResult.argtypes = [
            wintypes.HANDLE, ctypes.c_void_p, ctypes.POINTER(wintypes.DWORD),
            wintypes.BOOL]
        self.k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.k32.CreateEventW.restype = wintypes.HANDLE
        self.k32.CreateEventW.argtypes = [
            ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR]
        self.k32.CloseHandle.argtypes = [wintypes.HANDLE]
        self.k32.DeviceIoControl.argtypes = [
            wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD,
            ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
            ctypes.c_void_p]
        self.base = base
        self._handles: dict[str, int] = {}
        self._ev = self.k32.CreateEventW(None, True, False, None)
        if not self._ev:
            raise OSError("CreateEventW failed")

    # ------------------------------------------------------------------ open
    def open(self, node: str) -> int:
        if node in self._handles:
            return self._handles[node]
        path = self.base + node
        # GENERIC_READ: запись физически невозможна на уровне доступа к объекту
        h = self.k32.CreateFileW(path, GENERIC_READ, 0, None, OPEN_EXISTING,
                                 FILE_FLAG_OVERLAPPED, None)
        if not h or h == ctypes.c_void_p(-1).value:
            err = ctypes.get_last_error()
            raise OSError(f"cannot open {path}: WinError {err}")
        self._handles[node] = h
        return h

    def close(self) -> None:
        for h in list(self._handles.values()):
            try:
                self.k32.CloseHandle(h)
            except Exception:
                pass
        self._handles.clear()
        if self._ev:
            self.k32.CloseHandle(self._ev)
            self._ev = 0

    # ------------------------------------------------------------------ read
    def read(self, node: str, offset: int, length: int, timeout_ms: int = 3000) -> bytes:
        h = self.open(node)
        ov = OVERLAPPED()
        ov.Offset = offset & 0xFFFFFFFF
        ov.OffsetHigh = (offset >> 32) & 0xFFFFFFFF
        ov.hEvent = self._ev
        self.k32.ResetEvent(self._ev)
        buf = ctypes.create_string_buffer(length)
        got = wintypes.DWORD(0)
        ok = self.k32.ReadFile(h, buf, length, ctypes.byref(got), ctypes.byref(ov))
        if not ok:
            err = ctypes.get_last_error()
            if err != ERROR_IO_PENDING:
                raise OSError(f"ReadFile {node}+0x{offset:X}: WinError {err}")
            if self.k32.WaitForSingleObject(self._ev, timeout_ms) != 0:
                raise TimeoutError(f"read {node}+0x{offset:X} not completed in {timeout_ms} ms")
            if not self.k32.GetOverlappedResult(h, ctypes.byref(ov), ctypes.byref(got), False):
                raise OSError(f"overlapped {node}+0x{offset:X}: WinError {ctypes.get_last_error()}")
        return bytes(buf.raw[:got.value])

    def rd32(self, node: str, offset: int) -> int:
        return struct.unpack("<I", self.read(node, offset, 4))[0]

    # ------------------------------------------------------------------ ioctl
    def diag(self, node: str, timeout_ms: int = 2000) -> dict | None:
        """IOCTL_XDMA_DIAG_GET: progDmaCalls / bytesTransferred (только чтение)."""
        h = self.open(node)
        ov = OVERLAPPED()
        ov.hEvent = self._ev
        self.k32.ResetEvent(self._ev)
        out = ctypes.create_string_buffer(16)
        ret = wintypes.DWORD(0)
        ok = self.k32.DeviceIoControl(h, IOCTL_XDMA_DIAG_GET, None, 0,
                                      out, 16, ctypes.byref(ret), ctypes.byref(ov))
        if not ok:
            err = ctypes.get_last_error()
            if err != ERROR_IO_PENDING:
                return {"error": f"WinError {err}"}
            if self.k32.WaitForSingleObject(self._ev, timeout_ms) != 0:
                return {"error": f"IOCTL не завершился за {timeout_ms} мс (очередь занята)"}
            if not self.k32.GetOverlappedResult(h, ctypes.byref(ov), ctypes.byref(ret), False):
                return {"error": f"WinError {ctypes.get_last_error()}"}
        calls, _res, btr = struct.unpack(XDMA_DIAG_FMT, out.raw[:16])
        return {"progDmaCalls": calls, "bytesTransferred": btr}


def dump_engine(p: EngineProbe, name: str, base: int, sg_base: int, allow_rc: bool) -> None:
    ident = p.rd32(r"\control", base + ENG_ID)
    ctrl = p.rd32(r"\control", base + ENG_CONTROL)
    stat = p.rd32(r"\control", base + ENG_STATUS)
    done = p.rd32(r"\control", base + ENG_COMPLETED)
    align = p.rd32(r"\control", base + ENG_ALIGN)
    fdesc_lo = p.rd32(r"\control", sg_base + SGDMA_FIRSTDESC_LO)
    fdesc_hi = p.rd32(r"\control", sg_base + SGDMA_FIRSTDESC_HI)
    fdesc_adj = p.rd32(r"\control", sg_base + SGDMA_FIRSTDESC_ADJ)

    print(f"\n[{name}]")
    print(f"  identifier       0x{ident:08X}   (ожидается маска 0x1FC0xxxx, reg.h:34-35)")
    print(f"  control          0x{ctrl:08X}   {_decode(ctrl, CTRL_BITS, [])}")
    print(f"  status           0x{stat:08X}   {_decode(stat, STATUS_BITS, STATUS_ERR_RANGES)}")
    print(f"  completedDesc    0x{done:08X} ({done})  накопительный, RO")
    fields = " ".join(f"{n}={((align & m) >> (8 * i))}" for i, (n, m) in enumerate(ALIGN_FIELDS))
    print(f"  alignments       0x{align:08X}   {fields}")
    print(f"  firstDescLo/Hi   0x{fdesc_hi:08X}{fdesc_lo:08X}  adj={fdesc_adj}")
    if allow_rc:
        rc = p.rd32(r"\control", base + ENG_STATUS_RC)
        print(f"  statusRC         0x{rc:08X}   <-- READ-AND-CLEAR (прочитано осознанно)")
    else:
        print("  statusRC         пропущен (read-and-clear; включается --allow-readclear)")


def verify_ddr3(p: EngineProbe, off: int = 0x0100_0000, dump_offs=(0x0010_0000, 0x0011_0000)) -> bool:
    """c2h-чтение и сверка: возвращает True, если DDR3-чтение вернуло реальные данные."""
    ok_real = False
    print(f"\n[DDR3 read via c2h_0]  0x{off:07X}")
    try:
        raw = p.read(r"\c2h_0", off, 64)
    except Exception as exc:
        print(f"  ERROR: {exc}")
        return False
    expect = bytes(((i * 2654435761) >> 24) & 0xFF for i in range(64))
    print(f"  read    : {raw.hex()}")
    print(f"  expect  : {expect.hex()}   (LCG прошлого selftest, xdma_driver.py:1384)")
    if raw == expect:
        print("  => PATTERN MATCH: DDR3-чтение возвращает РЕАЛЬНЫЕ данные, AXI-R путь жив")
        ok_real = True
    elif not any(raw):
        print("  => ВСЕ НУЛИ: либо область перезаписана, либо поллинг завершился "
              "преждевременно (см. ROOTCAUSE_RERUN.md, гипотеза H7)")
    else:
        print("  => данные не совпали с эталоном (область могла быть перезаписана) — "
              "смотреть hex-dump ниже на осмысленность")

    for off2 in dump_offs:
        try:
            d = p.read(r"\c2h_0", off2, 64)
        except Exception as exc:
            print(f"\n  dump 0x{off2:07X}: ERROR {exc}")
            continue
        words = struct.unpack("<8Q", d)
        print(f"\n  dump 0x{off2:07X}:")
        print(f"    {d.hex()}")
        print("    u64: " + " ".join(f"0x{w:016X}" for w in words))
        if any(d):
            ok_real = True
    return ok_real


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="READ-ONLY диагностика XDMA H2C/C2H + DDR3")
    ap.add_argument("--dev", default=DEV_BASE)
    ap.add_argument("--verify-ddr3", action="store_true",
                    help="c2h-чтение 0x01000000 и сверка с эталонным паттерном")
    ap.add_argument("--tdot", action="store_true", help="прочитать MAGIC/CORE_PARAMS ядра")
    ap.add_argument("--allow-readclear", action="store_true",
                    help="прочитать 0x44/0x1044 (statusRC). ВНИМАНИЕ: read-and-clear")
    args = ap.parse_args(argv)

    p = EngineProbe(args.dev)
    try:
        p.open(r"\control")
    except OSError as exc:
        print(f"FATAL: {exc}\nПодсказка: узел создаётся драйвером oem191 при живом устройстве.")
        return 2

    print("=" * 78)
    print("XDMA engine READ-ONLY probe (запись в плату не выполняется)")
    print("=" * 78)
    dump_engine(p, "H2C_0 (host -> DDR3)", 0x0000, SGDMA_OFF_H2C, args.allow_readclear)
    dump_engine(p, "C2H_0 (DDR3 -> host)", 0x1000, SGDMA_OFF_C2H, args.allow_readclear)

    print("\n[IRQ block 0x2000]")
    en = p.rd32(r"\control", IRQ_CH_INT_ENABLE)
    rq = p.rd32(r"\control", IRQ_CH_INT_REQUEST)
    pd = p.rd32(r"\control", IRQ_CH_INT_PENDING)
    print(f"  channelIntEnable  0x{en:08X}   (bit0=H2C0, bit1=C2H0)")
    print(f"  channelIntRequest 0x{rq:08X}")
    print(f"  channelIntPending 0x{pd:08X}")

    print("\n[config block 0x3000]")
    msi = p.rd32(r"\control", CFG_MSI_ENABLE)
    wid = p.rd32(r"\control", CFG_PCIE_WIDTH)
    print(f"  msiEnable         0x{msi:08X}")
    print(f"  pcieWidth/ctl     0x{wid:08X}")

    print("\n[IOCTL_XDMA_DIAG_GET]  (progDmaCalls=0 => EvtProgramDma не вызывался)")
    for node in (r"\h2c_0", r"\c2h_0"):
        try:
            print(f"  {node:8s} {p.diag(node)}")
        except Exception as exc:
            print(f"  {node:8s} ERROR {exc}")

    if args.tdot:
        print("\n[tdot AXI-Lite via \\user]")
        try:
            magic = p.rd32(r"\user", 0x40023068 - 0x40000000)
            params = p.rd32(r"\user", 0x40023064 - 0x40000000)
            print(f"  MAGIC         0x{magic:08X} (ожидается 0x54444F54)")
            print(f"  CORE_PARAMS   0x{params:08X} (NUM_MAC={params & 0xFF}, "
                  f"ADDERS={(params >> 8) & 0xFF})")
        except Exception as exc:
            print(f"  ERROR {exc}")

    if args.verify_ddr3:
        verify_ddr3(p)

    print("\nГотово. Ни одной записи в плату не выполнено.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
