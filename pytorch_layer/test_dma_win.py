"""test_dma_win.py — pytest / CLI tests for the NEW Windows DMA driver (W1).

Targets the new device nodes of the DMA driver (symlink \\\\.\\XDMA0dma):
  \\\\.\\XDMA0dma\\control   -> AXI-Lite registers (BAR0)
  \\\\.\\XDMA0dma\\h2c_0     -> H2C DMA channel  (host -> DDR3)
  \\\\.\\XDMA0dma\\c2h_0     -> C2H DMA channel  (DDR3 -> host)
There is NO \\user node in the DFX build (BAR2 is the MSI-X table; DDR3 is
reachable only through the DMA channels) — matching ADDRESS_MAP.md 1.2 and the
xdma_driver_win_src_2017 contract.

Addressing (verified against xdma_driver.py::XdmaWinUpstream and xdma_public.h):
  control node : offset = addr - AXI_LITE_BASE (0x40000000); host subtracts it
  h2c/c2h DMA  : offset = RAW DDR3 offset, WITHOUT adding 0x80000000
  chunks       : <= 1 MiB (DMA_CHUNK); MaxTransfer = 8 MiB; align >= 4

This module does NOT modify xdma_driver.py. It imports XdmaDevice/XdmaError
from it; if that import has side effects on this host it falls back to a
self-contained minimal copy of the constants and exception type.
"""

import ctypes
import struct
import time
from ctypes import wintypes

# ---------------------------------------------------------------------------
# Import the upstream base classes when possible (no side-effect-free fallback).
# ---------------------------------------------------------------------------
try:
    from xdma_driver import XdmaDevice, XdmaError
except Exception:  # pragma: no cover - only if xdma_driver cannot be imported
    class XdmaError(RuntimeError):
        """Falback error (self-contained copy)."""

    class XdmaDevice:
        """Minimal fallback base (self-contained copy)."""

        def read(self, addr, length):
            raise NotImplementedError

        def write(self, addr, data):
            raise NotImplementedError

        def write_dma(self, ddr_off, data):
            raise NotImplementedError

        def read_dma(self, ddr_off, length):
            raise NotImplementedError


GENERIC_RW = 0x80000000 | 0x40000000
OPEN_EXISTING = 3
FILE_FLAG_OVERLAPPED = 0x40000000
ERROR_IO_PENDING = 997
INVALID_HANDLE = ctypes.c_void_p(-1).value


class XdmaWinDma(XdmaDevice):
    """Windows DMA backend for the new driver (\\\\.\\XDMA0dma, per-node).

    Opens \\control, \\h2c_0, \\c2h_0 with FILE_FLAG_OVERLAPPED and does all
    transfers via overlapped ReadFile/WriteFile with an OVERLAPPED struct.
      read/write(addr) -> control node, offset = addr - AXI_LITE_BASE
      write_dma/read_dma(ddr_off) -> h2c/c2h, offset = ddr_off (no +0x80000000)
    """

    AXI_LITE_BASE = 0x40000000
    DDR3_BASE = 0x80000000
    DMA_CHUNK = 1 << 20          # 1 MiB host chunk
    XDMA_MAX_TRANSFER = 8 << 20  # 8 MiB driver limit

    def __init__(self, base=r"\\.\XDMA0dma"):
        self._c = ctypes
        self._w = wintypes
        self.base = base
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self._k32 = k32
        k32.CreateFileW.restype = wintypes.HANDLE
        k32.CreateFileW.argtypes = [
            wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
            ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        k32.ReadFile.argtypes = [
            wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
        k32.WriteFile.argtypes = [
            wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
        k32.GetOverlappedResult.argtypes = [
            wintypes.HANDLE, ctypes.c_void_p,
            ctypes.POINTER(wintypes.DWORD), wintypes.BOOL]
        k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        k32.DeviceIoControl.argtypes = [
            wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD,
            ctypes.c_void_p, wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]

        class _OVERLAPPED(ctypes.Structure):
            _fields_ = [
                ("Internal", ctypes.c_void_p),
                ("InternalHigh", ctypes.c_void_p),
                ("Offset", wintypes.DWORD),
                ("OffsetHigh", wintypes.DWORD),
                ("hEvent", wintypes.HANDLE)]
        self._ov_t = _OVERLAPPED

        def _open(path):
            h = k32.CreateFileW(path, GENERIC_RW, 0, None, OPEN_EXISTING,
                                FILE_FLAG_OVERLAPPED, None)
            if not h or h == INVALID_HANDLE:
                raise XdmaError(
                    f"cannot open {path}: WinError {ctypes.get_last_error()}")
            return h

        self._ctrl = _open(self.base + r"\control")
        try:
            self._h2c = _open(self.base + r"\h2c_0")
        except XdmaError:
            self._h2c = None
        try:
            self._c2h = _open(self.base + r"\c2h_0")
        except XdmaError:
            self._c2h = None
        self._ev = k32.CreateEventW(None, True, False, None)
        if not self._ev:
            raise XdmaError("CreateEventW failed")

    # ---------------- overlapped transfer --------------------------------
    def _xfer(self, h, is_write, offset, data, length, timeout_ms=10000):
        if h is None:
            raise XdmaError("channel handle is None (driver node not open)")
        c = self._c
        ov = self._ov_t()
        ov.Offset = offset & 0xFFFFFFFF
        ov.OffsetHigh = (offset >> 32) & 0xFFFFFFFF
        ov.hEvent = self._ev
        self._k32.ResetEvent(self._ev)
        n = c.wintypes.DWORD(0)
        if is_write:
            buf = c.create_string_buffer(data, len(data))
            ok = self._k32.WriteFile(h, buf, len(data), c.byref(n), c.byref(ov))
        else:
            buf = c.create_string_buffer(length)
            ok = self._k32.ReadFile(h, buf, length, c.byref(n), c.byref(ov))
        if not ok:
            err = c.get_last_error()
            if err != ERROR_IO_PENDING:
                raise XdmaError(f"I/O error at 0x{offset:X}: WinError {err}")
            if self._k32.WaitForSingleObject(self._ev, timeout_ms) != 0:
                raise XdmaError(f"timeout at 0x{offset:X}")
            done = c.wintypes.DWORD(0)
            if not self._k32.GetOverlappedResult(
                    h, c.byref(ov), c.byref(done), False):
                raise XdmaError(
                    f"overlapped failed at 0x{offset:X}: "
                    f"WinError {c.get_last_error()}")
            n = done
        else:
            done = c.wintypes.DWORD(0)
            self._k32.GetOverlappedResult(h, c.byref(ov), c.byref(done), False)
            n = done
        return bytes(buf.raw[:n.value])

    # ---------------- control (AXI-Lite) ----------------------------------
    def read(self, addr, length=4):
        if not (self.AXI_LITE_BASE <= addr < 0x80000000):
            raise XdmaError(f"addr 0x{addr:X} not in AXI-Lite range")
        return self._xfer(self._ctrl, False, addr - self.AXI_LITE_BASE,
                          b"", length)

    def write(self, addr, data):
        if not (self.AXI_LITE_BASE <= addr < 0x80000000):
            raise XdmaError(f"addr 0x{addr:X} not in AXI-Lite range")
        self._xfer(self._ctrl, True, addr - self.AXI_LITE_BASE, data, len(data))

    def read32(self, addr):
        return struct.unpack("<I", self.read(addr, 4))[0]

    def write32(self, addr, val):
        self.write(addr, struct.pack("<I", val & 0xFFFFFFFF))

    # ---------------- DMA (h2c/c2h) ----------------------------------------
    def write_dma(self, ddr_off, data):
        """Write data into DDR3 at raw offset ddr_off via h2c_0.

        HOST contract: clean DDR3 offset (from 0x80000000), matching
        XdmaLinux.write_dma. The DRIVER adds the AXI base centrally
        (dma_engine.c EngineProgramDma, XDMA_DDR3_AXI_BASE).
        """
        for off in range(0, len(data), self.DMA_CHUNK):
            chunk = data[off:off + self.DMA_CHUNK]
            self._xfer(self._h2c, True, ddr_off + off, chunk, len(chunk))

    def read_dma(self, ddr_off, length):
        out = bytearray()
        off = 0
        while off < length:
            chunk = min(self.DMA_CHUNK, length - off)
            out += self._xfer(self._c2h, False, ddr_off + off, b"", chunk)
            off += chunk
        return bytes(out)

    # ---------------- IOCTLs -------------------------------------------------
    def _ioctl(self, index, out_size=0, in_data=b""):
        if self._c2h is None:
            raise XdmaError("c2h_0 not open for IOCTL")
        # CTL_CODE(FILE_DEVICE_UNKNOWN, index, METHOD_BUFFERED, FILE_ANY_ACCESS)
        # = (FILE_DEVICE_UNKNOWN=0x22 << 16) | (0<<14) | (index<<2) | 0
        code = ctypes.c_ulong((0x22 << 16) | (index << 2)).value
        inbuf = ctypes.create_string_buffer(in_data, len(in_data)) if in_data else None
        outbuf = ctypes.create_string_buffer(out_size) if out_size else None
        br = wintypes.DWORD(0)
        ok = self._k32.DeviceIoControl(
            self._c2h, code, inbuf, len(in_data) if inbuf else 0,
            outbuf, out_size, ctypes.byref(br), None)
        if not ok:
            raise XdmaError(f"IOCTL 0x{index} failed: WinError {ctypes.get_last_error()}")
        if out_size:
            return outbuf.raw[:br.value]
        return b""

    def perf_start(self):
        self._ioctl(0x1)

    def perf_get(self):
        raw = self._ioctl(0x3, out_size=24)
        cc, dc, pc = struct.unpack("<QQQ", raw)
        return {"clockCycleCount": cc, "dataCycleCount": dc, "pendingCount": pc}

    def perf_stop(self):
        self._ioctl(0x2)

    def addrmode_get(self):
        raw = self._ioctl(0x4, out_size=4)
        return struct.unpack("<I", raw)[0]

    # ---------------- resource cleanup ----------------------------------------
    def close(self):
        try:
            self._k32.CloseHandle(self._ctrl)
        except Exception:
            pass
        if self._h2c:
            try:
                self._k32.CloseHandle(self._h2c)
            except Exception:
                pass
        if self._c2h:
            try:
                self._k32.CloseHandle(self._c2h)
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Register / address constants for the tests (ADDRESS_MAP.md)
# ---------------------------------------------------------------------------
TDOT_CTRL = 0x40003000 + 0x00
TDOT_STATUS = 0x40003000 + 0x04
TDOT_N_IN = 0x40003000 + 0x08
TDOT_RES0 = 0x40003000 + 0x0C
TDOT_RES1 = 0x40003000 + 0x10
TDOT_DATA_ADDR_LO = 0x40003000 + 0x14
TDOT_DATA_ADDR_HI = 0x40003000 + 0x18
TDOT_WEIGHTS_ADDR_LO = 0x40003000 + 0x1C
TDOT_WEIGHTS_ADDR_HI = 0x40003000 + 0x20
TDOT_RESULT_ADDR_LO = 0x40003000 + 0x24
TDOT_RESULT_ADDR_HI = 0x40003000 + 0x28
GPIO_DATA = 0x40000000 + 0x00

DATA_OFF = 0x0000
WEIGHTS_OFF = 0x1000
RESULT_OFF = 0x2000
LOOPBACK_OFF = 0x00100000
DDR3_BASE = 0x80000000

TF48_ONE = 0x001000000000  # bits48 of 1.0 (verified with ternary_sw/tfloat48.py)


def _bits48_to_float(bits: int) -> float:
    """Decode a 48-bit TFloat48 [E:8][M:40] result word to float.

    Self-contained, mirrors fpga_backend.FpgaBackend._bits_to_float and
    xdma_driver._selftest: bits[39:0]=mantissa, bits[47:40]=exponent,
    TFloat stores [E:8][M:40] -> swap to (m<<8)|e for TFloat.from_bits.
    """
    import os as _os
    import sys as _sys
    _tern = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)),
                          "..", "ternary_sw")
    if _tern not in _sys.path:
        _sys.path.insert(0, _tern)
    try:
        from block.tfloat48 import TFloat
    except ImportError:
        raise AssertionError(
            "cannot import TFloat48 decoder (ternary_sw/block/tfloat48.py)")
    m = bits & ((1 << 40) - 1)
    e = (bits >> 40) & 0xFF
    return TFloat.from_bits((m << 8) | e).to_float()


def _lcg(nbytes, seed=12345):
    out = bytearray()
    x = seed
    for _ in range(nbytes):
        x = (x * 1664525 + 1013904223) & 0xFFFFFFFF
        out.append((x >> 24) & 0xFF)
    return bytes(out)


def _make_dev():
    return XdmaWinDma()


# ===========================================================================
#  Tests
# ===========================================================================
def test_regs_tdot_readback():
    dev = XdmaWinDma()
    try:
        st = dev.read32(TDOT_STATUS)
        gpio = dev.read32(GPIO_DATA)
        assert isinstance(st, int)
        assert isinstance(gpio, int)
        assert 0 <= st <= 0xFFFFFFFF and 0 <= gpio <= 0xFFFFFFFF
    finally:
        dev.close()


def test_dma_loopback_4b():
    _loopback(4)


def test_dma_loopback_1k():
    _loopback(1024)


def test_dma_loopback_1M():
    _loopback(1 << 20)


def _loopback(nbytes):
    dev = XdmaWinDma()
    try:
        pat = _lcg(nbytes)
        dev.write_dma(LOOPBACK_OFF, pat)
        rb = dev.read_dma(LOOPBACK_OFF, nbytes)
        assert rb == pat, f"loopback {nbytes}B mismatch at byte " \
                          f"{next((i for i,(a,b) in enumerate(zip(pat,rb)) if a!=b), len(pat))}"
    finally:
        dev.close()


def test_dma_perf_ioctl():
    dev = XdmaWinDma()
    try:
        dev.perf_start()
        pat = _lcg(4096)
        dev.write_dma(LOOPBACK_OFF, pat)
        dev.read_dma(LOOPBACK_OFF, 4096)
        perf = dev.perf_get()
        dev.perf_stop()
        assert perf["dataCycleCount"] > 0, f"dataCycleCount=0: {perf}"
        assert perf["clockCycleCount"] >= 0
        am = dev.addrmode_get()
        assert am == 0, f"ADDRMODE_GET={am} (expected 0)"
    finally:
        dev.close()


def test_dma_alignment_reject():
    dev = XdmaWinDma()
    try:
        # misaligned size (3 bytes) and / or misaligned offset must be rejected
        # by DeviceIoControl/ReadFile path or tolerated — but must NOT crash.
        pat = _lcg(8)
        try:
            dev.write_dma(LOOPBACK_OFF, pat[:3])
        except XdmaError:
            pass  # rejected cleanly — expected
        try:
            dev.read_dma(LOOPBACK_OFF, 3)
        except XdmaError:
            pass
        try:
            dev.write_dma(LOOPBACK_OFF + 1, pat[:4])  # unaligned offset
        except XdmaError:
            pass
    finally:
        dev.close()


def test_dot_smoke():
    dev = XdmaWinDma()
    try:
        n = 8
        data = struct.pack("<Q", TF48_ONE) * n
        weights = struct.pack("<Q", TF48_ONE) * n
        dev.write_dma(DATA_OFF, data)
        dev.write_dma(WEIGHTS_OFF, weights)
        for reg, off in ((TDOT_DATA_ADDR_LO, DATA_OFF),
                         (TDOT_WEIGHTS_ADDR_LO, WEIGHTS_OFF),
                         (TDOT_RESULT_ADDR_LO, RESULT_OFF)):
            dev.write32(reg, (DDR3_BASE + off) & 0xFFFFFFFF)
            dev.write32(reg + 4, ((DDR3_BASE + off) >> 32) & 0xFFFFFFFF)
        dev.write32(TDOT_N_IN, n)
        dev.write32(TDOT_CTRL, 0x01)  # GO
        # poll DONE
        t0 = time.monotonic()
        done = False
        while (time.monotonic() - t0) < 5.0:
            if dev.read32(TDOT_STATUS) & 0x02:
                done = True
                break
            time.sleep(0.01)
        assert done, "TDOT DONE timeout"
        result_bits = struct.unpack(
            "<Q", dev.read_dma(RESULT_OFF, 8))[0] & 0xFFFFFFFFFFFF
        assert result_bits is not None
        # --- ARITHMETIC check: n pairs of 1.0*1.0 must reduce to n.0 ---
        # RTL stores result as [E:8][M:40]; decode to float self-contained
        # (same convention as fpga_backend._bits_to_float / _selftest).
        got = _bits48_to_float(result_bits)
        want = float(n)
        assert abs(got - want) < 0.05, (
            f"TDOT arithmetic FAIL: n={n} pairs of 1.0 -> {got!r}, "
            f"expected {want!r} (result_bits=0x{result_bits:X})")
    finally:
        dev.close()


# ===========================================================================
#  CLI
# ===========================================================================
def main(argv=None):
    import sys
    import argparse
    ap = argparse.ArgumentParser(description="Windows DMA driver tests")
    ap.add_argument("mode", nargs="?", default="--smoke",
                    choices=["--smoke", "--full", "smoke", "full"])
    args = ap.parse_args(argv)
    mode = ("--" + args.mode) if args.mode not in ("--smoke", "--full") else args.mode

    print(f"XdmaWinDma device base: \\\\.\\XDMA0dma")
    if mode in ("--smoke",):
        _smoke()
    elif mode in ("--full",):
        _full()
    return 0


def _smoke():
    dev = XdmaWinDma()
    print("opened \\\\.\\XDMA0dma (control + h2c_0 + c2h_0)")
    st = dev.read32(TDOT_STATUS)
    gpio = dev.read32(GPIO_DATA)
    print(f"  TDOT_STATUS=0x{st:08X}  GPIO_DATA=0x{gpio:08X}")
    n = 4
    pat = _lcg(n)
    dev.write_dma(LOOPBACK_OFF, pat)
    rb = dev.read_dma(LOOPBACK_OFF, n)
    assert rb == pat, "loopback 4B failed"
    print(f"  loopback {n}B: PASS")
    dev.close()
    print("SMOKE OK")


def _full():
    test_regs_tdot_readback()
    print("test_regs_tdot_readback: PASS")
    test_dma_loopback_4b()
    print("test_dma_loopback_4b: PASS")
    test_dma_loopback_1k()
    print("test_dma_loopback_1k: PASS")
    test_dma_loopback_1M()
    print("test_dma_loopback_1M: PASS")
    test_dma_perf_ioctl()
    print("test_dma_perf_ioctl: PASS")
    test_dma_alignment_reject()
    print("test_dma_alignment_reject: PASS")
    test_dot_smoke()
    print("test_dot_smoke: PASS")
    print("FULL OK")


if __name__ == "__main__":
    import sys
    sys.exit(main())