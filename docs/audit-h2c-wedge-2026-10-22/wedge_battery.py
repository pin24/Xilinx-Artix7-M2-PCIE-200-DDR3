#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""wedge_battery.py — READ-ONLY батарейка доказательств после h2c-клина (BUG-081).

Запускать СРАЗУ после клина (timeout большой h2c) и ОБЯЗАТЕЛЬНО ДО:
  - любого soft_reset_h2c() / IOCTL_XDMA_CHANNEL_RESET (сброс обнуляет perfCtrl
    в XDMA_EngineResetChannel — dma_engine.c:1265 — и доказательства гибнут);
  - перезагрузки (reboot сбрасывает всю ткань).

Скрипт НЕ ПИШЕТ в плату вообще: все handle открываются с GENERIC_READ,
никаких WriteFile, регистры читаются через \\control (config BAR) и \\user
(AXI-Lite), опциональный readback — через узел \\c2h_0 (чтение DDR3).

Что собирает (по порядку убывания ценности):
  1) H2C_0: control(0x04), status RO(0x40 — НЕ read-clear!), completedDescCount
     (0x48), alignments(0x4C), PERF-счётчики (perfCtrl 0xC4, cycles 0xC8/CC,
     data 0xD0/D4, pending 0xD8/DC) — perfDat показывает, СКОЛЬКО байт движок
     реально вытолкал до клина (счётчики включаются драйвером при каждом
     EngineStart — dma_engine.c:1777-1778);
  2) C2H_0: те же регистры (здоров ли читатель);
  3) SGDMA: firstDescLo/Hi/Adj (0x4080/84/88, 0x5080/84/88);
  4) IRQ-блок: channelIntEnable/Request/Pending (0x2010/0x2044/0x204C);
  5) IOCTL_XDMA_DIAG_GET на h2c_0/c2h_0: progDmaCalls / bytesTransferred
     (кумулятивные с загрузки драйвера — снимайте «чистый» дамп после reboot
     для базы сравнения);
  6) --readback ADDR LEN: c2h-чтение региона записи (по умолчанию предлагается
     0x200000) — показывает, ДОКУДА физически дошли данные (фронт данных);
     опция рискованная: если клин в M00/MIG, c2h-чтение тоже зависнет (это
     само по себе дискриминатор) — поэтому движковые регистры читаются ПЕРВЫМИ;
  7) \\user: MAGIC(0x23068)/CORE_PARAMS(0x23064) — sanity AXI-Lite.

Классификация клина (печатается в конце):
  A. BUSY=1 + cdc заморожен + perfDat>0       -> busy-stuck на раунде N
     (N = cdc; байт ушло perfDat)             -> канал write AW/W/B или движок
  B. BUSY=1 + perfDat == размеру попытки       -> данные ушли, клин в
     end-of-chain/completion (фетч-конвейер/комплит)
  C. BUSY=0 + cdc < ожидаемого                 -> «тихая остановка» (другая
     ветка H2: движок сбросил RUN сам)
  D. c2h-readback завис/таймаут                -> M00/MIG wedged тоже (глубже
     движка); сравнить с успешным c2h до клина
  E. WRITE_ERROR-счётчики в status != 0        -> потеря write на AXI-стороне
     (регистр статуса 9..23 биты, PG195)

Примеры:
    python wedge_battery.py
    python wedge_battery.py --readback 0x200000 0x80000
    python wedge_battery.py --readback 0x200000 0x80000 --dump-dir C:\\Temp\\wedge

Коды возврата: 0 — батарея собрана; 2 — устройство недоступно.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import os
import struct
import sys
from ctypes import wintypes

DEV_BASE = r"\\.\XDMA0dma"
GENERIC_READ = 0x80000000
OPEN_EXISTING = 3
FILE_FLAG_OVERLAPPED = 0x40000000
ERROR_IO_PENDING = 997

IOCTL_XDMA_DIAG_GET = (0x22 << 16) | (0x06 << 2)
XDMA_DIAG_FMT = "<IIQ"

# ---- engine / block offsets (libxdma/reg.h:119-147, 150-212) ----
ENG_ID = 0x00
ENG_CONTROL = 0x04
ENG_STATUS = 0x40            # RO-копия статуса (НЕ read-clear; 0x44 — RC, не читаем)
ENG_COMPLETED = 0x48
ENG_ALIGN = 0x4C
ENG_PERF_CTRL = 0xC4
ENG_PERF_CYC_LO = 0xC8
ENG_PERF_CYC_HI = 0xCC
ENG_PERF_DAT_LO = 0xD0
ENG_PERF_DAT_HI = 0xD4
ENG_PERF_PND_LO = 0xD8
ENG_PERF_PND_HI = 0xDC
SGDMA_FIRSTDESC_LO = 0x80    # + база SGDMA-блока 0x4000(H2C) / 0x5000(C2H)
SGDMA_FIRSTDESC_HI = 0x84
SGDMA_FIRSTDESC_ADJ = 0x88
SGDMA_OFF_H2C = 0x4000
SGDMA_OFF_C2H = 0x5000
IRQ_CH_INT_ENABLE = 0x2010
IRQ_CH_INT_REQUEST = 0x2044
IRQ_CH_INT_PENDING = 0x204C

CTRL_BITS = [
    (0, "RUN"), (1, "IE_DESC_STOPPED"), (2, "IE_DESC_COMPLETED"),
    (3, "IE_ALIGN"), (4, "IE_MAGIC"), (5, "IE_INVALID_LEN"),
    (6, "IE_IDLE_STOPPED"), (25, "NON_INCR_ADDR"), (26, "POLL_MODE"),
    (31, "RST(reserved-PG195-v4.1)"),
]
STATUS_BITS = [
    (0, "BUSY"), (1, "DESC_STOPPED"), (2, "DESC_COMPLETED"),
    (3, "ALIGN_MISMATCH"), (4, "MAGIC_STOPPED"), (5, "FETCH_STOPPED"),
    (6, "IDLE_STOPPED"),
]
STATUS_ERR_RANGES = [(9, 5, "READ_ERROR"), (14, 5, "WRITE_ERROR"), (19, 5, "DESC_ERROR")]


def _decode(value: int, table, err_ranges) -> str:
    parts = [name for bit, name in table if value & (1 << bit)]
    for lo, width, name in err_ranges:
        cnt = (value >> lo) & ((1 << width) - 1)
        if cnt:
            parts.append(f"{name}={cnt}")
    return " ".join(parts) if parts else "-"


class OVERLAPPED(ctypes.Structure):
    _fields_ = [
        ("Internal", ctypes.c_void_p),
        ("InternalHigh", ctypes.c_void_p),
        ("Offset", wintypes.DWORD),
        ("OffsetHigh", wintypes.DWORD),
        ("hEvent", ctypes.c_void_p),
    ]


class EngineProbe:
    """GENERIC_READ-доступ к узлам драйвера. Запись физически невозможна."""

    def __init__(self, base: str = DEV_BASE):
        self.base = base
        self.k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.k32.CreateFileW.restype = ctypes.c_void_p
        self.k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD,
                                         wintypes.DWORD, ctypes.c_void_p,
                                         wintypes.DWORD, wintypes.DWORD,
                                         ctypes.c_void_p]
        self.k32.ReadFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                      wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
                                      ctypes.POINTER(OVERLAPPED)]
        self.k32.DeviceIoControl.argtypes = [ctypes.c_void_p, wintypes.DWORD,
                                             ctypes.c_void_p, wintypes.DWORD,
                                             ctypes.c_void_p, wintypes.DWORD,
                                             ctypes.POINTER(wintypes.DWORD),
                                             ctypes.POINTER(OVERLAPPED)]
        self._handles: dict[str, int] = {}
        self._ev = self.k32.CreateEventW(None, True, False, None)

    def open(self, node: str) -> int:
        if node in self._handles:
            return self._handles[node]
        path = self.base + node
        h = self.k32.CreateFileW(path, GENERIC_READ, 0, None, OPEN_EXISTING,
                                 FILE_FLAG_OVERLAPPED, None)
        if not h or h == ctypes.c_void_p(-1).value:
            raise OSError(f"cannot open {path}: WinError {ctypes.get_last_error()}")
        self._handles[node] = h
        return h

    def close(self) -> None:
        for h in self._handles.values():
            try:
                self.k32.CloseHandle(h)
            except Exception:
                pass
        self._handles.clear()
        if self._ev:
            self.k32.CloseHandle(self._ev)
            self._ev = None

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
                raise TimeoutError(f"read {node}+0x{offset:X} не завершён за {timeout_ms} мс")
            if not self.k32.GetOverlappedResult(h, ctypes.byref(ov), ctypes.byref(got), False):
                raise OSError(f"overlapped {node}+0x{offset:X}: WinError {ctypes.get_last_error()}")
        return bytes(buf.raw[:got.value])

    def rd32(self, node: str, offset: int) -> int:
        return struct.unpack("<I", self.read(node, offset, 4))[0]

    def diag(self, node: str, timeout_ms: int = 2000) -> dict:
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
                return {"error": f"IOCTL не завершён за {timeout_ms} мс"}
            if not self.k32.GetOverlappedResult(h, ctypes.byref(ov), ctypes.byref(ret), False):
                return {"error": f"WinError {ctypes.get_last_error()}"}
        calls, _res, btr = struct.unpack(XDMA_DIAG_FMT, out.raw[:16])
        return {"progDmaCalls": calls, "bytesTransferred": btr}


def dump_engine(p: EngineProbe, name: str, base: int, sg_base: int) -> dict:
    """Читает регистры одного движка; возвращает словарь для классификации."""
    out: dict = {}
    reads = [
        ("id", ENG_ID), ("control", ENG_CONTROL), ("status", ENG_STATUS),
        ("completed", ENG_COMPLETED), ("align", ENG_ALIGN),
        ("perfCtrl", ENG_PERF_CTRL), ("perfCycLo", ENG_PERF_CYC_LO),
        ("perfCycHi", ENG_PERF_CYC_HI), ("perfDatLo", ENG_PERF_DAT_LO),
        ("perfDatHi", ENG_PERF_DAT_HI), ("perfPndLo", ENG_PERF_PND_LO),
        ("perfPndHi", ENG_PERF_PND_HI),
    ]
    print(f"\n[{name}]  base 0x{base:04X}")
    for key, off in reads:
        try:
            v = p.rd32(r"\control", base + off)
            out[key] = v
            extra = ""
            if key == "control":
                extra = f"   {_decode(v, CTRL_BITS, [])}"
            elif key == "status":
                extra = f"   {_decode(v, STATUS_BITS, STATUS_ERR_RANGES)}"
            print(f"  {key:<12} 0x{off:04X}: 0x{v:08X}{extra}")
        except Exception as exc:
            print(f"  {key:<12} 0x{off:04X}: ERROR {exc}")
    for key, off in (("firstDescLo", SGDMA_FIRSTDESC_LO),
                     ("firstDescHi", SGDMA_FIRSTDESC_HI),
                     ("firstDescAdj", SGDMA_FIRSTDESC_ADJ)):
        try:
            v = p.rd32(r"\control", sg_base + off)
            out[key] = v
            print(f"  {key:<12} 0x{sg_base + off:04X}: 0x{v:08X}")
        except Exception as exc:
            print(f"  {key:<12} 0x{sg_base + off:04X}: ERROR {exc}")
    if {"perfDatLo", "perfDatHi"} <= out.keys():
        dat = out["perfDatHi"] << 32 | out["perfDatLo"]
        cyc = out["perfCycHi"] << 32 | out["perfCycLo"]
        pnd = out["perfPndHi"] << 32 | out["perfPndLo"]
        print(f"  => PERF: data={dat} байт, cycles={cyc}, pending={pnd} "
              f"(perfCtrl=0x{out.get('perfCtrl', 0):08X})")
        out["perfDat"] = dat
        out["perfCyc"] = cyc
        out["perfPnd"] = pnd
    return out


def do_readback(p: EngineProbe, addr: int, length: int, dump_dir: str | None) -> None:
    """c2h-чтение региона записи: фронт данных + дамп. Может зависнуть при
    клине M00/MIG — это тоже дискриминатор (движковые регистры уже сняты)."""
    print(f"\n[READBACK via \\c2h_0]  0x{addr:X}, {length} байт, чанками 4 КиБ ...")
    chunks: list[bytes] = []
    ok_chunks = 0
    try:
        remaining = length
        off = addr
        while remaining > 0:
            n = min(4096, remaining)
            chunks.append(p.read(r"\c2h_0", off, n, timeout_ms=5000))
            ok_chunks += 1
            off += n
            remaining -= n
    except Exception as exc:
        print(f"  ОСТАНОВЛЕНО на чанке {ok_chunks} (offset 0x{addr + ok_chunks * 4096:X}): {exc}")
        print("  => c2h/M00/MIG тоже не отвечает: клин ГЛУБЖЕ h2c-движка (ветка D)")
    if not chunks:
        print("  данных не получено")
        return
    blob = b"".join(chunks)
    last_nz = -1
    first_nz = -1
    for i, b in enumerate(blob):
        if b:
            last_nz = i
            if first_nz < 0:
                first_nz = i
    print(f"  получено {len(blob)} байт; первый non-zero @0x{first_nz:X}, "
          f"последний non-zero @0x{last_nz:X} ({'фронт данных виден' if last_nz >= 0 else 'область вся нулевая'})")
    print(f"  первые 64 Б: {blob[:64].hex()}")
    tail_off = max(0, len(blob) - 64)
    print(f"  последние 64 Б: {blob[tail_off:].hex()}")
    sha = hashlib.sha256(blob).hexdigest()
    print(f"  sha256: {sha}")
    if dump_dir:
        os.makedirs(dump_dir, exist_ok=True)
        path = os.path.join(dump_dir, f"wedge_readback_0x{addr:X}_{len(blob)}.bin")
        with open(path, "wb") as fh:
            fh.write(blob)
        print(f"  дамп: {path}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="READ-ONLY батарея после h2c-клина")
    ap.add_argument("--dev", default=DEV_BASE)
    ap.add_argument("--expect-bytes", type=int, default=0,
                    help="ожидаемый размер попытки h2c (для классификации B, напр. 524288)")
    ap.add_argument("--readback", nargs=2, type=lambda x: int(x, 0), metavar=("ADDR", "LEN"),
                    help="c2h-чтение региона записи после снятия регистров (напр. 0x200000 0x80000)")
    ap.add_argument("--dump-dir", default=None, help="куда сохранить readback-дамп")
    ap.add_argument("--skip-user", action="store_true", help="не трогать AXI-Lite probe")
    args = ap.parse_args(argv)

    print("=" * 78)
    print("wedge_battery — ТОЛЬКО ЧТЕНИЕ. Запустите ДО soft_reset_h2c()/reboot:")
    print("perf-счётчики гибнут при XDMA_EngineResetChannel (perfCtrl=0) и reboot.")
    print("=" * 78)

    p = EngineProbe(args.dev)
    h2c: dict = {}
    c2h: dict = {}
    try:
        try:
            p.open(r"\control")
        except OSError as exc:
            print(f"FATAL: {exc}")
            return 2

        h2c = dump_engine(p, "H2C_0 (host -> DDR3)", 0x0000, SGDMA_OFF_H2C)
        c2h = dump_engine(p, "C2H_0 (DDR3 -> host)", 0x1000, SGDMA_OFF_C2H)

        print("\n[IRQ block]")
        for name, off in (("channelIntEnable", IRQ_CH_INT_ENABLE),
                          ("channelIntRequest", IRQ_CH_INT_REQUEST),
                          ("channelIntPending", IRQ_CH_INT_PENDING)):
            try:
                print(f"  {name:<20} 0x{off:04X}: 0x{p.rd32(r'\\control', off):08X}")
            except Exception as exc:
                print(f"  {name:<20} 0x{off:04X}: ERROR {exc}")

        print("\n[DIAG]")
        for node in (r"\h2c_0", r"\c2h_0"):
            d = p.diag(node)
            print(f"  {node}: {d}")

        if not args.skip_user:
            print("\n[AXI-Lite sanity via \\user]")
            for name, off in (("MAGIC", 0x23068), ("CORE_PARAMS", 0x23064)):
                try:
                    v = p.rd32(r"\user", off)
                    print(f"  {name:<12} 0x{off:05X}: 0x{v:08X}")
                except Exception as exc:
                    print(f"  {name:<12} 0x{off:05X}: ERROR {exc}")

        if args.readback:
            do_readback(p, args.readback[0], args.readback[1], args.dump_dir)

        # -------- классификация --------
        print("\n" + "=" * 78)
        busy = h2c.get("status", 0) & 0x1
        cdc = h2c.get("completed", 0)
        dat = h2c.get("perfDat", 0)
        exp = args.expect_bytes
        print("КЛАССИФИКАЦИЯ (предварительная):")
        if busy and dat and exp and dat >= exp:
            print("  B: perfDat >= размера попытки при BUSY=1 — данные ушли в MIG, "
                  "клин в end-of-chain/completion (фетч-конвейер или B-обработка)")
        elif busy:
            print(f"  A: BUSY=1, cdc={cdc} (движок застрял на дескрипторе {cdc + 1}), "
                  f"perfDat={dat} байт — busy-stuck в write-канале (движок/SC-CDC/MIG)")
        elif not busy and exp and dat and dat < exp:
            print(f"  C: BUSY=0 при недописанных {exp - dat} байт — «тихая остановка»")
        else:
            print("  данных для однозначной классификации мало — сравните с базой "
                  "после reboot и сохраните вывод")
        wr_err = (h2c.get("status", 0) >> 14) & 0x1F
        if wr_err:
            print(f"  E: WRITE_ERROR-счётчик статуса H2C_0 = {wr_err} — потери write на AXI-стороне")
        print("Дальше: сохраните вывод в лог, потом (по команде owner) soft_reset_h2c/эксперименты.")
        return 0
    finally:
        p.close()


if __name__ == "__main__":
    sys.exit(main())
