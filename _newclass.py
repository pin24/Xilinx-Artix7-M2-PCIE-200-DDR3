# ============================================================================
# Upstream Xilinx XDMA 2017 driver (ctypes direct, per-node access)
# ============================================================================
# Device nodes (from xdma_driver_win_src_2017/inc/xdma_public.h):
#   r"\\.\XDMA0\control" -> BAR0 (config bar)  - AXI-Lite registers
#   r"\\.\XDMA0\user"    -> BAR2 (user bar)    - if present
#   r"\\.\XDMA0\h2c_0"   -> DMA H2C channel 0  - host -> DDR3
#   r"\\.\XDMA0\c2h_0"   -> DMA C2H channel 0  - DDR3 -> host
#
# Addressing: BAR-relative (OVERLAPPED.Offset = byte offset in the BAR, NOT
# the full AXI address). So subtract AXI_LITE_BASE=0x40000000 for registers.
# For DMA channels the offset is the DDR3 offset from DDR3_BASE=0x80000000,
# matching our ADDRESS_MAP.md.
#
# Reference: xdma_driver_win_src_2017/sys/file_io.c:ReadBarToRequest,
# WriteBarFromRequest; xdma_driver_win_src_2017/inc/xdma_public.h.
# ============================================================================
class XdmaWinUpstream(XdmaDevice):
    AXI_LITE_BASE = 0x40000000
    DDR3_BASE = 0x80000000
    DMA_CHUNK = 1 << 20

    def __init__(self, base=None):
        import ctypes
        from ctypes import wintypes
        self._c = ctypes
        self._w = wintypes
        self.base = base if base else "\\\\?\\\\"  # placeholder, set below
        # standard path r"\\.\XDMA0"
        if base is None:
            self.base = "\\\\" + ".\\\\" + "XDMA0"
        else:
            self.base = base
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self._k32 = k32
        k32.CreateFileW.restype = wintypes.HANDLE
        k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                    ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                                    wintypes.HANDLE]
        k32.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                                 ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
        k32.WriteFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                                  ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
        k32.GetOverlappedResult.argtypes = [wintypes.HANDLE, ctypes.c_void_p,
                                            ctypes.POINTER(wintypes.DWORD), wintypes.BOOL]
        k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        k32.ResetEvent.argtypes = [wintypes.HANDLE]
        k32.CreateEventW.restype = wintypes.HANDLE
        k32.CreateEventW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL,
                                     wintypes.LPCWSTR]

        class _OVERLAPPED(ctypes.Structure):
            _fields_ = [("Internal", ctypes.c_void_p),
                        ("InternalHigh", ctypes.c_void_p),
                        ("Offset", wintypes.DWORD),
                        ("OffsetHigh", wintypes.DWORD),
                        ("hEvent", wintypes.HANDLE)]
        self._ov_t = _OVERLAPPED

        GENERIC_RW = 0x80000000 | 0x40000000
        OPEN_EXISTING, FILE_FLAG_OVERLAPPED = 3, 0x40000000
        INVALID = ctypes.c_void_p(-1).value
        S = "\\\\"

        def _open(path):
            h = k32.CreateFileW(path, GENERIC_RW, 0, None, OPEN_EXISTING,
                                FILE_FLAG_OVERLAPPED, None)
            if not h or h == INVALID:
                raise XdmaError(f"cannot open {path}: WinError {ctypes.get_last_error()}")
            return h

        self._ctl = _open(self.base + S + "control")
        try:
            self._usr = _open(self.base + S + "user")
        except XdmaError:
            self._usr = None
        self._h2c = _open(self.base + S + "h2c_0")
        self._c2h = _open(self.base + S + "c2h_0")
        self._ev = k32.CreateEventW(None, True, False, None)
        if not self._ev:
            raise XdmaError("CreateEventW failed")

    def _xfer(self, h, is_write, offset, data, length):
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
            if err != 997:
                raise XdmaError(f"I/O error at 0x{offset:X}: WinError {err}")
            if self._k32.WaitForSingleObject(self._ev, 10000) != 0:
                raise XdmaError(f"timeout at 0x{offset:X}")
            done = c.wintypes.DWORD(0)
            if not self._k32.GetOverlappedResult(h, c.byref(ov), c.byref(done), False):
                raise XdmaError(f"overlapped failed at 0x{offset:X}")
            n = done
        else:
            done = c.wintypes.DWORD(0)
            self._k32.GetOverlappedResult(h, c.byref(ov), c.byref(done), False)
            n = done
        return bytes(buf.raw[:n.value])

    def read(self, addr, length):
        if not (self.AXI_LITE_BASE <= addr < 0x80000000):
            raise XdmaError(f"addr 0x{addr:X} not in AXI-Lite range")
        return self._xfer(self._ctl, False, addr - self.AXI_LITE_BASE, b"", length)

    def write(self, addr, data):
        if not (self.AXI_LITE_BASE <= addr < 0x80000000):
            raise XdmaError(f"addr 0x{addr:X} not in AXI-Lite range")
        self._xfer(self._ctl, True, addr - self.AXI_LITE_BASE, data, len(data))

    def write_dma(self, ddr_off, data):
        full = self.DDR3_BASE + ddr_off
        off = 0
        while off < len(data):
            chunk = data[off:off + self.DMA_CHUNK]
            self._xfer(self._h2c, True, full + off, chunk, len(chunk))
            off += len(chunk)

    def read_dma(self, ddr_off, length):
        full = self.DDR3_BASE + ddr_off
        out = bytearray()
        off = 0
        while off < length:
            chunk = min(self.DMA_CHUNK, length - off)
            out += self._xfer(self._c2h, False, full + off, b"", chunk)
            off += chunk
        return bytes(out)

