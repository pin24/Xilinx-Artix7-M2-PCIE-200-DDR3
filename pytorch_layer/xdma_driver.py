"""Драйвер XDMA для доступа к троичному ускорителю (TFloat48) на FPGA.

Инкапсулирует взаимодействие хоста с картой:
  - регистры tdot_axi4   (AXI-Lite, через XDMA control / xdma_user на BAR)
  - DDR3 (XDMA M_AXI, 0x8000_0000) — векторы data/weights и результат
    (в DFX-сборке — ТОЛЬКО через DMA-каналы h2c/c2h, см. комментарий ниже).

Два бэкенда:
  - Linux  : /dev/xdma0_control (регистры) + /dev/xdma0_h2c_0|c2h_0 (DDR3 DMA).
  - Windows: утилита xdma_rw (exe/xdma_rw): регистры по адресу, DDR3 — DMA-канал.

Формат данных в DDR3 (согласовано с tdot_axi4.sv):
  каждый TFloat48 занимает 64-битное слово, младшие 48 бит = число:
    data[i]     по адресу data_addr    + i*8
    weights[i]  по адресу weights_addr + i*8
    результат   по адресу result_addr  (младшие 48 бит)

Регистры tdot_axi4 (32-бит, байтовый адрес, адресная база REG_BASE):
  0x00 CTRL   бит0 GO
  0x04 STATUS бит0 BUSY, бит1 DONE
  0x08 N_IN
  0x0C RES0 = result[31:0], 0x10 RES1 = {16'h0, result[47:32]}  (48-битный результат)
  0x14/0x18 DATA_ADDR_LO/HI
  0x1C/0x20 WEIGHTS_ADDR_LO/HI
  0x24/0x28 RESULT_ADDR_LO/HI
  0x2C/0x30 CORE_RES0/CORE_RES1

  Планировщик (ring-buffer команд в DDR3 + IRQ, см. tdot_axi4.sv):
  0x40 SCHED_CTRL  бит0 sched_en, бит1 irq_en, бит2 flush, бит3 irq_ack
  0x44 SCHED_WPTR  хостовый указатель записи (8 бит, кольцо mod 256)
  0x48 SCHED_RPTR  RO указатель чтения (8 бит)
  0x4C/0x50 DESC_BASE_LO/HI   база таблицы дескрипторов (DDR3, полный AXI)
  0x54/0x58 COMP_BASE_LO/HI   база области завершений (DDR3, полный AXI)
  0x5C SCHED_STATUS  RO бит0 sched_busy, бит1 irq_pending
  0x60 DONE_CNT      RO счётчик завершённых задач (16 бит)
"""
from __future__ import annotations
import os, subprocess, struct, time, threading

# Границы AXI-окна (согласовано с driver/driver.c FIX-1 и FIX-11):
#   AXI-Lite [0x4000_0000 .. 0x7FFF_FFFF] — GPIO/TDOT/ICAP/XADC регистры (BAR0)
#   DDR3     [0x8000_0000 ..]            — окно DDR3
# ВАЖНО (docs/ADDRESS_MAP.md 1.2): в DFX-сборке ВТОРОГО BAR-моста к DDR3 НЕТ —
# BAR2 занят таблицей MSI-X, и драйвер (FIX-11) намеренно НЕ маппит его как
# DDR3-окно. DDR3 на хосте доступна ТОЛЬКО через DMA-каналы (h2c/c2h):
# в XdmaLinux — /dev/xdma0_h2c_0|c2h_0, в XdmaWindows — `xdma_rw.exe ... h2c_0`.
# Для DDR3 хост передаёт СМЕЩЕНИЯ (write_dma/read_dma от DDR3_BASE), не MMIO.
# Полные AXI-адреса используются только для AXI-Lite (регистры).
AXI_LITE_BASE = 0x4000_0000   # начало AXI-Lite окна (BAR0)
DDR3_BASE     = 0x8000_0000   # база DDR3 (от неё отсчитываются смещения DMA)
DDR3_SIZE     = 0x1000_0000   # окно DDR3 = 256 МБ; защита от переполнения (2026-10-23)

# адресная база AXI-Lite регистров ядра. [FLAT] BD содержит ТОЛЬКО:
#   M00 GPIO 0x40020000, M03 TDOT 0x40023000, M05 XADC 0x46000000,
#   DataMover MM2S 0x40010000 / S2MM 0x40018000, DDR3 0x80000000.
# [DFX]-ONLY (в FLAT BD НЕ существуют, обращение вернёт ошибку BAR):
#   DFX sock 0x40022000, ICAP 0x40024000, SPI 0x40025000.
REG_BASE  = 0x4002_3000      # tdot_axi4 регистры (FLAT + DFX)
ICAP_BASE = 0x4002_4000      # [DFX-only] ICAP-контроллер (в FLAT BD нет)
GPIO_BASE = 0x4002_0000      # axi_gpio
HWICAP_BASE = 0x4000_1000    # [DFX-only legacy] axi_hwicap
DFX_SOCK_BASE = 0x4002_2000  # [DFX-only] dfx_socket/decouple_shutdown_ctrl
SPI_BASE = 0x4002_5000       # [DFX-only] SPI-over-PCIe (hot-flash без JTAG)
# legacy alias (модульно совместим со старым именем)
DDR_BASE = DDR3_BASE

# ---- CHANNEL-RESET 2026-10-22: IOCTL_XDMA_CHANNEL_RESET (inc/xdma_public.h) ----
# CTL_CODE(FILE_DEVICE_UNKNOWN, 0x7, METHOD_BUFFERED, FILE_ANY_ACCESS) = 0x22001C
IOCTL_CHANNEL_RESET = (0x22 << 16) | (0 << 14) | (0x7 << 2) | 0
CHANNEL_RESET_NOW = 0x00000001      # XDMA_CHANNEL_RESET_FLAG_NOW
CHANNEL_RESET_AUTO_ON = 0x00000002  # XDMA_CHANNEL_RESET_FLAG_AUTO_ON
CHANNEL_RESET_AUTO_OFF = 0x00000004  # XDMA_CHANNEL_RESET_FLAG_AUTO_OFF


def _tf48_to_bits(t) -> int:
    """TFloat48 -> 48-битное целое (совпадает с to_bits48 в verify)."""
    return ((t.e_int & 0xFF) << 40) | (t.m_int & ((1 << 40) - 1))


class XdmaError(RuntimeError):
    """Ошибка взаимодействия с XDMA-устройством."""


class XdmaDevice:
    """Абстракция над конкретным драйвером: read/write по байтовому адресу.

    Данные в DDR3 передаются через DMA-каналы h2c/c2h: write_dma/read_dma
    принимают СМЕЩЕНИЕ внутри окна DDR3 (от 0x8000_0000), т.к. в DFX-сборке
    MMIO-моста к DDR3 нет (docs/ADDRESS_MAP.md §1.2). Базовая реализация
    маршрутизирует через MMIO read/write — этим пользуется mock-устройство
    в verify_fpga_backend.py; XdmaLinux/XdmaWindows переопределяют методы
    настоящими DMA-каналами.
    """

    def read(self, addr: int, length: int) -> bytes:
        raise NotImplementedError

    def write(self, addr: int, data: bytes) -> None:
        raise NotImplementedError

    def write_dma(self, ddr_off: int, data: bytes) -> None:
        """DMA-запись data в DDR3 по смещению ddr_off (от 0x8000_0000)."""
        self.write(DDR3_BASE + ddr_off, data)

    def read_dma(self, ddr_off: int, length: int) -> bytes:
        """DMA-чтение length байт из DDR3 по смещению ddr_off."""
        return self.read(DDR3_BASE + ddr_off, length)


class XdmaLinux(XdmaDevice):
    """Linux: /dev/xdma0_control (BAR0, AXI-Lite) и /dev/xdma0_user (BAR2, DDR3).

    Хост шлёт ПОЛНЫЕ AXI-адреса (0x4000_xxxx для регистров, 0x8000_xxxx для DDR3).
    Маршрутизация по двум устройствам:
      AXI_LITE_BASE <= addr < DDR3_BASE  →  /dev/xdma0_control,  offset = addr - AXI_LITE_BASE
      addr >= DDR3_BASE                  →  /dev/xdma0_user,     offset = addr - DDR3_BASE
    """

    # Один syscall в DMA-узел — до 1 МиБ; драйвер сам делит трансфер на
    # дескрипторы (адрес в дескрипторе кратен 4 байтам).
    DMA_CHUNK = 1 << 20

    def __init__(self, base: str = "/dev/xdma0"):
        self.ctl = base + "_control"
        self.usr = base + "_user"
        self.h2c = base + "_h2c_0"
        self.c2h = base + "_c2h_0"
        # usr ОПЦИОНАЛЕН: в DFX-сборке второй PCIe BAR не сконфигурирован,
        # весь AXI-Lite (0x4000_0000+) доступен через _control. usr — только
        # MMIO-доступ к DDR3 легаси-сборки. Канонический путь данных в DDR3 —
        # DMA-каналы h2c_0/c2h_0 (см. docs/ADDRESS_MAP.md §1.2).
        if not os.path.exists(self.ctl):
            raise XdmaError(f"XDMA-устройство не найдено: {self.ctl}")
        self.has_usr = os.path.exists(self.usr)
        self.has_h2c = os.path.exists(self.h2c)
        self.has_c2h = os.path.exists(self.c2h)

    def _route(self, addr: int) -> tuple[str, int]:
        """Вернуть (devpath, bar_offset) по полному AXI-адресу."""
        if AXI_LITE_BASE <= addr < DDR3_BASE:
            return self.ctl, addr - AXI_LITE_BASE
        if addr >= DDR3_BASE:
            if not self.has_usr:
                raise XdmaError(
                    f"Адрес 0x{addr:08X} требует /dev/xdma0_user (BAR2/DDR3). "
                    f"В DFX-сборке второй BAR не сконфигурирован: передавайте "
                    f"данные в DDR3 через DMA-каналы (h2c/c2h) — "
                    f"см. docs/ADDRESS_MAP.md §1.2")
            return self.usr, addr - DDR3_BASE
        raise XdmaError(f"Некорректный AXI-адрес 0x{addr:08X} "
                        f"(должен быть >= 0x{AXI_LITE_BASE:08X})")

    def read(self, addr: int, length: int) -> bytes:
        dev, offset = self._route(addr)
        with open(dev, "rb", buffering=0) as f:
            f.seek(offset)
            return f.read(length)

    def write(self, addr: int, data: bytes) -> None:
        dev, offset = self._route(addr)
        with open(dev, "wb", buffering=0) as f:
            f.seek(offset)
            f.write(data)

    def _dma_dev(self, devpath: str, present: bool, what: str) -> str:
        """Вернуть путь DMA-узла или падение на usr-MMIO (легаси-сборка).

        Приоритет: h2c/c2h (канонический DMA-режим) → usr (BAR2 легаси) →
        понятная ошибка с подсказкой.
        """
        if present:
            return devpath
        if self.has_usr:
            return self.usr          # легаси-сборка с BAR2: MMIO-фолбэк
        raise XdmaError(
            f"DMA-узел {devpath} не найден, а usr ({self.usr}) отсутствует "
            f"(DFX-сборка без BAR2). Загрузите модуль xdma и проверьте, что "
            f"устройство создало узлы h2c_0/c2h_0: ls /dev/xdma0_* ({what})")

    def write_dma(self, ddr_off: int, data: bytes) -> None:
        """DMA-запись в DDR3 через /dev/xdma0_h2c_0 (host → card).

        Смещение ddr_off — внутри окна DDR3 (0x8000_0000); lseek задаёт
        стартовый адрес в DDR, драйвер сам режет трансфер на дескрипторы.
        Трансферы кратны 4 байтам (ограничение адресации дескриптора),
        хвост дополняется нулями. Фолбэк легаси-сборки: usr-узел (BAR2),
        offset в нём равен ddr_off — тот же цикл корректен.
        """
        if not (self.has_h2c or self.has_usr):
            self._dma_dev(self.h2c, False, "h2c write")   # -> XdmaError
        dev = self.h2c if self.has_h2c else self.usr
        with open(dev, "wb", buffering=0) as f:
            for off in range(0, len(data), self.DMA_CHUNK):
                chunk = data[off:off + self.DMA_CHUNK]
                pad = (-len(chunk)) % 4
                if pad:
                    chunk += b"\x00" * pad
                f.seek(ddr_off + off)
                f.write(chunk)

    def read_dma(self, ddr_off: int, length: int) -> bytes:
        """DMA-чтение из DDR3 через /dev/xdma0_c2h_0 (card → host).

        Фолбэк легаси-сборки — usr-узел (BAR2) тем же циклом.
        """
        if not (self.has_c2h or self.has_usr):
            self._dma_dev(self.c2h, False, "c2h read")    # -> XdmaError
        dev = self.c2h if self.has_c2h else self.usr
        out = bytearray()
        with open(dev, "rb", buffering=0) as f:
            for off in range(0, length, self.DMA_CHUNK):
                n = min(self.DMA_CHUNK, length - off)
                rd = n + ((-n) % 4)
                f.seek(ddr_off + off)
                out += f.read(rd)[:n]
        return bytes(out)


class XdmaWinDriver(XdmaDevice):
    r"""Windows-бэкенд через ШТАТНЫЙ драйвер проекта (driver/driver.c, \\.\XDMA0).

    Контракт (FIX-1): file offset = ПОЛНЫЙ AXI-адрес; драйвер сам маршрутизирует:
      AXI_LITE_BASE <= addr < DDR3_BASE  -> BAR0 (вычитает AXI_LITE_BASE)
      addr >= DDR3_BASE                  -> BAR2 (вычитает 0x80000000)
    Регистры — ReadFile/WriteFile с OVERLAPPED (4-байтные, выровненные).
    Не требует xdma_rw.exe. DMA (h2c/c2h) этот драйвер не умеет —
    write_dma/read_dma поднимают XdmaError (для DMA — XdmaWindows/xdma_rw).
    """

    def __init__(self, devpath: str = r"\\.\XDMA0"):
        import ctypes
        from ctypes import wintypes
        self._c = ctypes
        self._w = wintypes
        self.devpath = devpath
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
        # HANDLE — 64-битный указатель: без явных argtypes ctypes усечёт его
        # до c_int и CloseHandle закроет чужой/невалидный handle.
        k32.CloseHandle.argtypes = [wintypes.HANDLE]
        k32.CloseHandle.restype = wintypes.BOOL

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
        h = k32.CreateFileW(devpath, GENERIC_RW, 0, None, OPEN_EXISTING,
                            FILE_FLAG_OVERLAPPED, None)
        if not h or h == INVALID:
            raise XdmaError(f"не удалось открыть {devpath}: "
                            f"WinError {ctypes.get_last_error()}")
        self._h = h
        self._ev = k32.CreateEventW(None, True, False, None)
        if not self._ev:
            k32.CloseHandle(h)
            self._h = None
            raise XdmaError("CreateEventW failed")

    def close(self) -> None:
        """Закрыть handle устройства и OVERLAPPED-event (идемпотентно).

        Безопасен при частичной инициализации и при повторных вызовах:
        недостающие/уже закрытые handle пропускаются, ошибки не всплывают.
        """
        for name in ("_h", "_ev"):
            h = getattr(self, name, None)
            if not h:
                continue
            setattr(self, name, None)
            try:
                self._k32.CloseHandle(h)
            except Exception:
                pass

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    def _xfer(self, is_write: bool, addr: int, data: bytes, length: int) -> bytes:
        c = self._c
        ov = self._ov_t()
        ov.Offset = addr & 0xFFFFFFFF
        ov.OffsetHigh = (addr >> 32) & 0xFFFFFFFF
        ov.hEvent = self._ev
        self._k32.ResetEvent(self._ev)
        n = c.wintypes.DWORD(0)
        if is_write:
            buf = c.create_string_buffer(data, len(data))
            ok = self._k32.WriteFile(self._h, buf, len(data), c.byref(n), c.byref(ov))
        else:
            buf = c.create_string_buffer(length)
            ok = self._k32.ReadFile(self._h, buf, length, c.byref(n), c.byref(ov))
        if not ok:
            err = c.get_last_error()
            if err != 997:  # ERROR_IO_PENDING
                raise XdmaError(f"I/O error at 0x{addr:X}: WinError {err}")
            if self._k32.WaitForSingleObject(self._ev, 10000) != 0:
                raise XdmaError(f"timeout at 0x{addr:X}")
            done = c.wintypes.DWORD(0)
            if not self._k32.GetOverlappedResult(self._h, c.byref(ov),
                                                 c.byref(done), False):
                raise XdmaError(f"overlapped failed at 0x{addr:X}: "
                                f"WinError {c.get_last_error()}")
            n = done
        else:
            done = c.wintypes.DWORD(0)
            self._k32.GetOverlappedResult(self._h, c.byref(ov), c.byref(done), False)
            n = done
        return bytes(buf.raw[:n.value])

    def read(self, addr: int, length: int) -> bytes:
        return self._xfer(False, addr, b"", length)

    def write(self, addr: int, data: bytes) -> None:
        self._xfer(True, addr, data, len(data))

    def write_dma(self, ddr_off: int, data: bytes) -> None:
        raise XdmaError("DMA (h2c) не поддерживается штатным драйвером — "
                        "используйте XdmaWindows/xdma_rw или Linux-путь (R-05)")

    def read_dma(self, ddr_off: int, length: int) -> bytes:
        raise XdmaError("DMA (c2h) не поддерживается штатным драйвером — "
                        "используйте XdmaWindows/xdma_rw или Linux-путь (R-05)")


class XdmaWindows(XdmaDevice):
    r"""Windows: вызывает xdma_rw.exe (из XDMA_Driver_App).

    После FIX-1 (driver/driver.c) у драйвера единая точка входа `\\.\XDMA0`
    (без суффиксов `\control`/`\user`); драйвер САМ маршрутизирует по offset:
      AXI_LITE_BASE <= addr < DDR3_BASE  →  BAR0 (вычитает AXI_LITE_BASE внутри)
      addr >= DDR3_BASE                  →  BAR2 (вычитает 0x80000000 внутри)
    Поэтому хост шлёт ПОЛНЫЕ AXI-адреса в `xdma_rw.exe <DEVNODE> <op> <ADDR> ...`.

    Если используется upstream-xdma_rw.exe с жёсткими devnode-суффиксами
    (`control`/`user`), передайте devnode явно и при необходимости нормализуйте
    addr (минус AXI_LITE_BASE/DDR3_BASE) перед вызовом — но это не требуется
    для проекта, т.к. driver.c FIX-1 даёт единый symlink `\\.\XDMA0`.
    """

    def __init__(self, tool: str = "xdma_rw", devnode: str = "XDMA0"):
        self.tool = tool
        self.devnode = devnode

    def _run(self, op: str, addr: int, length: int) -> bytes:
        cmd = [self.tool, self.devnode, op, f"0x{addr:X}", "-l", str(length or 4)]
        r = subprocess.run(cmd, capture_output=True)
        if r.returncode != 0:
            raise XdmaError(f"xdma_rw не выполнился: {r.stderr.decode(errors='replace')}")
        return r.stdout

    def read(self, addr: int, length: int) -> bytes:
        return self._run("read", addr, length)

    def write(self, addr: int, data: bytes) -> None:
        # xdma_rw.exe ожидает байты как отдельные аргументы (LE: data[0] идёт первым).
        vals = " ".join(f"{b}" for b in data)
        cmd = [self.tool, self.devnode, "write", f"0x{addr:X}", *vals.split()]
        r = subprocess.run(cmd, capture_output=True)
        if r.returncode != 0:
            raise XdmaError(f"xdma_rw write не выполнился: {r.stderr.decode(errors='replace')}")

    def _run_channel(self, channel: str, op: str, off: int, length: int,
                     data: bytes | None = None) -> bytes:
        """Вызов xdma_rw.exe в DMA-канал (h2c_N/c2h_N).

        Синтаксис (windows_xdma): xdma_rw.exe <devnode> <h2c_N|c2h_N>
        <read|write> <hex_offset> [-l N | -f file]. Запись больших буферов
        идёт через временный файл (-f), чтение возвращает stdout инструмента.
        """
        cmd = [self.tool, self.devnode, channel, op, f"0x{off:X}"]
        path = None
        if data is not None:
            import tempfile
            with tempfile.NamedTemporaryFile(delete=False, suffix=".bin") as tf:
                tf.write(data)
                path = tf.name
            cmd += ["-f", path]
        else:
            cmd += ["-l", str(length or 4)]
        try:
            r = subprocess.run(cmd, capture_output=True)
        finally:
            if path:
                os.unlink(path)
        if r.returncode != 0:
            raise XdmaError(f"xdma_rw {channel} {op} не выполнился: "
                            f"{r.stderr.decode(errors='replace')}")
        return r.stdout

    def write_dma(self, ddr_off: int, data: bytes) -> None:
        """DMA-запись в DDR3 через канал h2c_0 (offset — от 0x8000_0000)."""
        self._run_channel("h2c_0", "write", ddr_off, len(data), data=data)

    def read_dma(self, ddr_off: int, length: int) -> bytes:
        """DMA-чтение из DDR3 через канал c2h_0 (offset — от 0x8000_0000)."""
        return self._run_channel("c2h_0", "read", ddr_off, length)


# ============================================================================
# XdmaWinUpstream - upstream Xilinx XDMA 2017 driver, per-node ctypes access
# ============================================================================
# Uses device nodes from xdma_driver_win_src_2017/inc/xdma_public.h:
#   \\.\XDMA0\control -> BAR0 (config) - AXI-Lite registers, offset = BAR-relative
#   \\.\XDMA0\user    -> BAR2 (user)   - optional, usually absent in DFX build
#   \\.\XDMA0\h2c_0   -> H2C DMA channel - host -> DDR3
#   \\.\XDMA0\c2h_0   -> C2H DMA channel - DDR3 -> host
#
# Host-side address math: registers pass FULL AXI address minus AXI_LITE_BASE
# (0x40000000) to the control node; DMA channels take CARD-side DDR3 address
# as-is, and write_dma/read_dma pass СМЕЩЕНИЕ (ddr_off) WITHOUT adding
# DDR3_BASE (0x80000000) — matches ADDRESS_MAP.md §1.2 and other backends.
# Reference: file_io.c:ReadBarToRequest/WriteBarFromRequest.
# ============================================================================
class XdmaWinUpstream(XdmaDevice):
    AXI_LITE_BASE = 0x40000000
    DDR3_BASE = 0x80000000
    # BUG-071: align with test_dma_win.XdmaWinDma.DMA_CHUNK — biggest single
    # WDF packet (8 MiB = XDMA_MAX_TRANSFER_SIZE), fits XDMA_MAX_DESC_COUNT=2048
    # SG elements at 4 KiB fragmentation.
    DMA_CHUNK = 1 << 20

    def __init__(self, base=r"\\.\XDMA0"):
        import ctypes
        from ctypes import wintypes
        self._c = ctypes
        self._w = wintypes
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
        # CHANNEL-RESET 2026-10-22: binding для soft_reset_h2c() (IOCTL на h2c-узле).
        k32.DeviceIoControl.argtypes = [
            wintypes.HANDLE,            wintypes.DWORD,
            ctypes.c_void_p,            wintypes.DWORD,   # in buffer / size
            ctypes.c_void_p,            wintypes.DWORD,   # out buffer / size
            ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]

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

        def _open(path):
            h = k32.CreateFileW(path, GENERIC_RW, 0, None, OPEN_EXISTING,
                                FILE_FLAG_OVERLAPPED, None)
            if not h or h == INVALID:
                raise XdmaError(f"cannot open {path}: WinError {ctypes.get_last_error()}")
            return h

        # Периферия (TDOT/GPIO/XADC) живёт в user-BAR (\user). \control (config-BAR,
        # 64KB, движковые регистры XDMA) в этом драйвере может НЕ создаваться —
        # открываем его ОПЦИОНАЛЬНО; для периферии обязателен \user.
        self._ctl = None
        try:
            self._ctl = _open(self.base + "\\control")
        except XdmaError:
            self._ctl = None
        try:
            self._usr = _open(self.base + "\\user")
        except XdmaError:
            self._usr = None
        if self._usr is None and self._ctl is None:
            raise XdmaError(f"no usable BAR handle on {base}")
        self._h2c = _open(self.base + "\\h2c_0")
        self._c2h = _open(self.base + "\\c2h_0")
        self._ev = k32.CreateEventW(None, True, False, None)
        if not self._ev:
            raise XdmaError("CreateEventW failed")
        self._k32.CloseHandle.argtypes = [wintypes.HANDLE]   # FIX-R3 2026-10-20
        self._k32.CloseHandle.restype = wintypes.BOOL

    def close(self) -> None:
        """Закрыть все handle (идемпотентно, безопасно при частичной инициализации)."""
        for name in ("_ctl", "_usr", "_h2c", "_c2h", "_ev"):
            h = getattr(self, name, None)
            if not h:
                continue
            setattr(self, name, None)
            try:
                self._k32.CloseHandle(h)
            except Exception:
                pass

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

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

    def read_config(self, offset: int, length: int = 4) -> bytes:
        r"""Чтение из config-BAR (\control) драйвера XDMA напрямую (смещение от начала
        конфиг-регистра). Периферию так НЕ читать (она в \user): тут только XDMA
        движковые/конфиг-регистры (напр. pcieWidth@0x1C). Возвращает raw bytes."""
        if self._ctl is None:
            raise XdmaError("config-BAR (\control) недоступен")
        return self._xfer(self._ctl, False, offset, b"", length)

    def read(self, addr, length):
        if not (self.AXI_LITE_BASE <= addr < 0x80000000):
            raise XdmaError(f"addr 0x{addr:X} not in AXI-Lite range")
        # Периферия (TDOT/GPIO/XADC) живёт в user-BAR (AXI-Lite 128MB),
        # а НЕ в config-BAR (\control, 64KB config-regs). Только \user
        # промаппливает AXI-Lite окно; \control не достаёт периферию.
        h = self._usr if self._usr is not None else self._ctl
        return self._xfer(h, False, addr - self.AXI_LITE_BASE, b"", length)

    def write(self, addr, data):
        if not (self.AXI_LITE_BASE <= addr < 0x80000000):
            raise XdmaError(f"addr 0x{addr:X} not in AXI-Lite range")
        h = self._usr if self._usr is not None else self._ctl
        self._xfer(h, True, addr - self.AXI_LITE_BASE, data, len(data))

    def _chk_ddr(self, ddr_off, length):
        """Guard от переполнения DDR3: смещение+длина обязаны быть в окне 256 МБ."""
        if ddr_off is None or ddr_off < 0 or length <= 0:
            raise ValueError(f"DMA: bad offset/len {ddr_off}+{length}")
        if ddr_off + length > DDR3_SIZE:
            raise ValueError(f"DMA: {ddr_off}+{length} выходит за окно DDR3 "
                             f"{DDR3_SIZE}")

    def write_dma(self, ddr_off, data):
        # HOST contract: clean raw DDR3 offset (from 0x80000000), like
        # XdmaLinux.write_dma and ADDRESS_MAP §6. The DRIVER adds the AXI base
        # centrally (dma_engine.c EngineProgramDma, XDMA_DDR3_AXI_BASE).
        self._chk_ddr(ddr_off, len(data))
        off = 0
        while off < len(data):
            chunk = data[off:off + self.DMA_CHUNK]
            self._xfer(self._h2c, True, ddr_off + off, chunk, len(chunk))
            off += len(chunk)

    def read_dma(self, ddr_off, length):
        self._chk_ddr(ddr_off, length)
        out = bytearray()
        off = 0
        while off < length:
            chunk = min(self.DMA_CHUNK, length - off)
            out += self._xfer(self._c2h, False, ddr_off + off, b"", chunk)
            off += chunk
        return bytes(out)

    # ---- CHANNEL-RESET 2026-10-22 ----
    # Ручной безопасный сброс h2c-канала (IOCTL_XDMA_CHANNEL_RESET на h2c-узле).
    # Аппаратную работу выполняет ДРАЙВЕР в ядре (XDMA_EngineResetChannel):
    # host здесь регистры НЕ пишет, только шлёт IOCTL — т.е. метод read-only по
    # отношению к железу. Используется как fallback, когда host перехватил
    # таймаут write_dma, но движок остался залипшим (BUSY) и до следующего
    # переноса нужен разблокирующий сброс без power-cycle. Драйвер также
    # делает авто-сброс на таймауте (channelResetOnTimeout, по умолчанию TRUE).
    def soft_reset_h2c(self, auto_on=None):
        """Сбросить h2c-канал. auto_on=True/False — переключить политику
        авто-сброса драйвера на таймауте; None — оставить без изменений.
        НЕ выполняется на железе сейчас (запись в плату запрещена)."""
        if self._h2c is None:
            raise XdmaError("h2c channel handle is None (driver node not open)")
        flags = CHANNEL_RESET_NOW
        if auto_on is True:
            flags |= CHANNEL_RESET_AUTO_ON
        elif auto_on is False:
            flags |= CHANNEL_RESET_AUTO_OFF
        from ctypes import byref
        inbuf = (self._c.c_ulong * 1)(flags & 0xFFFFFFFF)
        done = self._c.wintypes.DWORD(0)
        ok = self._k32.DeviceIoControl(
            self._h2c, IOCTL_CHANNEL_RESET,
            inbuf, 4, None, 0, byref(done), None)
        if not ok:
            raise XdmaError(
                f"IOCTL_XDMA_CHANNEL_RESET(flags=0x{flags:X}) failed: "
                f"WinError {self._c.get_last_error()}")
        return done.value

class TdotCore:
    """Управление ядром tdot_axi4 через XDMA."""

    def __init__(self, dev: XdmaDevice, num_mac: int = 32, ddr_base: int = DDR_BASE):
        self.dev = dev
        self.num_mac = num_mac
        self.ddr = ddr_base
        # Теневое состояние OBS_CTRL: RTL пишет freeze_q уровнем (wdata_q[1]),
        # а CLEAR (wdata_q[0]) — импульс с самоочисткой (tdot_axi4.sv:329-338),
        # поэтому слепая запись 0x1/0x2 сбрасывает соседний бит. Храним ТОЛЬКО
        # бит FREEZE (0x0/0x2); бит CLEAR сюда не попадает никогда.
        self._obs_ctrl = 0

    # ---- регистры ----
    def _reg_w(self, off: int, val: int) -> None:
        self.dev.write(REG_BASE + off, struct.pack("<I", val & 0xFFFFFFFF))

    def _reg_r(self, off: int) -> int:
        return struct.unpack("<I", self.dev.read(REG_BASE + off, 4))[0]

    def set_addrs(self, data_addr: int, weights_addr: int, result_addr: int) -> None:
        """Программирует data/weights/result адреса в RTL.

        Параметры da/wa/ra — СМЕЩЕНИЯ внутри DDR3 (в байтах, от 0x8000_0000).
        RTL (tdot_axi4.sv) читает `data_start_reg` как ПОЛНЫЙ AXI-адрес для
        M_AXI_ARADDR — значит, надо писать DDR3_BASE + offset, иначе RTL уйдёт
        читать из BRAM (0x0..0x1FFF) вместо DDR3.
        """
        full_da = DDR3_BASE + data_addr
        full_wa = DDR3_BASE + weights_addr
        full_ra = DDR3_BASE + result_addr
        # [FLAT] P1-align guard: RTL burst INCR требует кратности 8 (8-байт слово
        # TFloat48); невыровненный адрес -> partial первый beat, данные смещены.
        if (full_da & 7) or (full_wa & 7) or (full_ra & 7):
            raise XdmaError(
                f"адрес не кратен 8: data={full_da:#x} weights={full_wa:#x} "
                f"result={full_ra:#x} - RTL burst требует 8-байтного выравнивания")
        self._reg_w(0x14, full_da & 0xFFFFFFFF)            # DATA_ADDR_LO
        self._reg_w(0x18, (full_da >> 32) & 0xFFFFFFFF)    # DATA_ADDR_HI
        self._reg_w(0x1C, full_wa & 0xFFFFFFFF)            # WEIGHTS_ADDR_LO
        self._reg_w(0x20, (full_wa >> 32) & 0xFFFFFFFF)    # WEIGHTS_ADDR_HI
        self._reg_w(0x24, full_ra & 0xFFFFFFFF)            # RESULT_ADDR_LO
        self._reg_w(0x28, (full_ra >> 32) & 0xFFFFFFFF)    # RESULT_ADDR_HI

    def set_n(self, n: int) -> None:
        self._reg_w(0x08, n)

    def start(self) -> None:
        # FIX 2026-10-20 (OBS/GO safety, source-grounded): when sched_en=1 the RTL
        # blocks the legacy GO pulse (go_accept = go_pulse && !busy_q && !sched_en_q),
        # so start() would be a silent no-op -> OBS stays 0 and the result is garbage.
        # Never do that silently: if the scheduler is active, fail fast and let the
        # caller decide (disable sched via set_sched(False) or use TdotScheduler).
        if (self._reg_r(SCHED_CTRL) & 0x1):
            raise XdmaError("legacy GO disabled: scheduler active (sched_en=1). "
                            "Call core.set_sched(False) before legacy dot(), or use "
                            "TdotScheduler for scheduler-driven tasks.")
        self._reg_w(0x00, 0x1)  # GO

    def set_sched(self, on: bool) -> None:
        """Enables/disables the HW scheduler (SCHED_CTRL bit0) explicitly.

        Safe only when no scheduler batch is in flight (engine idle, ring empty).
        Use this to switch the core between scheduler mode (on) and the legacy
        GO dot path (off)."""
        v = self._reg_r(SCHED_CTRL) & ~0x1
        self._reg_w(SCHED_CTRL, v | (1 if on else 0))

    def status(self) -> tuple:
        s = self._reg_r(0x04)
        return bool(s & 1), bool(s & 2)   # (busy, done)

    def wait_done(self, timeout_ms: float = 5000.0) -> None:
        t0 = time.monotonic()
        while True:
            busy, done = self.status()
            if done:
                return
            if (time.monotonic() - t0) * 1000 > timeout_ms:
                raise XdmaError(f"timeout ожидания DONE ({timeout_ms} мс; "
                                f"последний STATUS: busy={busy} done={done})")
            time.sleep(0.0001)   # 100 мкс — PCIe round-trip всё равно дольше

    def read_result_reg(self) -> int:
        """RES0 = result[31:0], RES1 = {16'h0, result[47:32]} — 48-битный результат.

        RTL (tdot_axi4.sv:523-524):
          res0_reg <= core_result[31:0];              // полные 32 бита
          res1_reg <= {16'h0, core_result[47:32]};    // только мл. 16 бит значимы
        """
        res0 = self._reg_r(0x0C) & 0xFFFFFFFF          # RES0 = result[31:0]
        res1 = self._reg_r(0x10) & 0xFFFF              # RES1 = {16'h0, result[47:32]}
        result = ((res1 & 0xFFFF) << 32) | (res0 & 0xFFFFFFFF)
        return result  # 48 бит

    def read_core_result_reg(self) -> int:
        """CORE_RES0 = result[31:0], CORE_RES1 = {16'h0, result[47:32]}.

        RTL (tdot_axi4.sv:251-252) — это зеркала core_result БЕЗ защёлок res0_reg/res1_reg.
        Полезно для отладки: если RES0/RES1 и CORE_RES0/CORE_RES1 совпадают —
        защёлки работают корректно. Если различаются — race condition в CS_WAIT.

        AUDIT-05 (NOTE): CORE_RES0/1 зарезервированы для debug, не используются
        в основном потоке dot() — только для верификации.
        """
        cres0 = self._reg_r(0x2C) & 0xFFFFFFFF         # CORE_RES0 = result[31:0]
        cres1 = self._reg_r(0x30) & 0xFFFF             # CORE_RES1 = {16'h0, result[47:32]}
        return ((cres1 & 0xFFFF) << 32) | (cres0 & 0xFFFFFFFF)

    # ---- наблюдаемость (OBS, Task 35; за образец — openTPU, Apache-2.0) ----
    # Адреса в main-карте СДВИНУТЫ относительно ветки XDMA_DDR3_TMUL на +0x8:
    # в main 0x64/0x68 заняты CORE_PARAMS/MAGIC, поэтому OBS начинаются с 0x6C.
    # Все методы АДДИТИВНЫЕ: существующее поведение TdotCore не меняется.
    OBS_CTRL         = 0x6C   # W: bit0 CLEAR (импульс), bit1 FREEZE (уровень)
    OBS_BUILD_ID     = 0x70   # RO: git-коммит битстрима (32'h0 = не передан)
    OBS_CAPS         = 0x74   # RO: [7:0] NUM_MAC, [11:8] ADDERS,
                              #     [15:12] log2(BURST_RD_LEN), [16] SCHED,
                              #     [31:24] версия REGMAP
    OBS_CYCLES_LO    = 0x78   # RO, 64-бит free-running
    OBS_CYCLES_HI    = 0x7C
    OBS_BUSY         = 0x80   # RO тактов busy_q=1
    OBS_MEM          = 0x84   # RO тактов фазы памяти (RD_DATA/RD_WEIGHTS/FETCH)
    OBS_LOAD         = 0x88   # RO тактов CS_LOAD
    OBS_COMPUTE      = 0x8C   # RO тактов CS_RUN/CS_WAIT/CS_ACCUM_WAIT
    OBS_AR           = 0x90   # RO AXI4 read-транзакций
    OBS_BEAT         = 0x94   # RO принятых 64-бит слов
    OBS_AR_STALL     = 0x98   # RO тактов AR-бэкпрешера
    OBS_R_WAIT       = 0x9C   # RO тактов ожидания данных (аналог STARVE)
    OBS_WR           = 0xA0   # RO AXI4 write-транзакций
    OBS_JOB          = 0xA4   # RO запущенных задач
    OBS_FIFO_FULL    = 0xA8   # RO тактов fifo_full (по дизайну 0)
    OBS_SNAP         = 0xAC   # W: любое значение = атомарный снимок
    OBS_SHADOW_BASE  = 0xB0   # RO: 13 слов теней (CYCLES_LO/HI + 11 счётчиков)

    _OBS_ORDER = ["cycles_lo", "cycles_hi", "busy", "mem", "load", "compute",
                  "ar", "beat", "ar_stall", "r_wait", "wr", "job", "fifo_full"]

    def read_build_id(self) -> int:
        """BUILD_ID битстрима (первые 8 hex git-коммита; 0 = не передан)."""
        return self._reg_r(self.OBS_BUILD_ID)

    def read_caps(self) -> dict:
        """CAPS: конфигурация битстрима, читаемая из железа."""
        v = self._reg_r(self.OBS_CAPS)
        return {
            "regmap_version": (v >> 24) & 0xFF,
            "sched":          bool((v >> 16) & 1),
            "log2_burst":     (v >> 12) & 0xF,
            "adders":         (v >> 8) & 0xF,
            "num_mac":        v & 0xFF,
        }

    def obs_clear(self) -> None:
        """Обнулить все OBS-счётчики (импульс CLEAR).

        FREEZE (бит1) сохраняется: пишем сохранённое состояние + импульс.
        Бит CLEAR в self._obs_ctrl НЕ залипает — RTL гасит его сам."""
        self._reg_w(self.OBS_CTRL, self._obs_ctrl | 0x1)

    def obs_freeze(self, on: bool) -> None:
        """Пауза событийного счёта (CYCLES продолжает идти).

        Обновляем только бит1 в сохранённом состоянии, чтобы не потерять
        текущий режим (и не выдать случайный импульс CLEAR)."""
        self._obs_ctrl = 0x2 if on else 0x0
        self._reg_w(self.OBS_CTRL, self._obs_ctrl)

    def obs_snap(self) -> None:
        """Атомарно защёлкнуть все счётчики в теневые регистры."""
        self._reg_w(self.OBS_SNAP, 0x1)

    def obs_read(self) -> dict:
        """Прочитать все счётчики (последовательно; для консистентного
        снимка вызывайте obs_snap() и читайте obs_read_shadow())."""
        r = lambda off: self._reg_r(off)
        # CYCLES 64-бит: HI->LO->HI с повтором при переносе (иначе кадр с ошибкой
        # ±2^32 каждые ~34 с @125 МГц, если LO переполнился между чтениями).
        hi = r(self.OBS_CYCLES_HI)
        lo = r(self.OBS_CYCLES_LO)
        if r(self.OBS_CYCLES_HI) != hi:   # был перенос LO — перечитываем пару
            hi = r(self.OBS_CYCLES_HI)
            lo = r(self.OBS_CYCLES_LO)
        return {
            "cycles":     (hi << 32) | lo,
            "busy":       r(self.OBS_BUSY),
            "mem":        r(self.OBS_MEM),
            "load":       r(self.OBS_LOAD),
            "compute":    r(self.OBS_COMPUTE),
            "ar":         r(self.OBS_AR),
            "beat":       r(self.OBS_BEAT),
            "ar_stall":   r(self.OBS_AR_STALL),
            "r_wait":     r(self.OBS_R_WAIT),
            "wr":         r(self.OBS_WR),
            "job":        r(self.OBS_JOB),
            "fifo_full":  r(self.OBS_FIFO_FULL),
        }

    def obs_read_shadow(self) -> dict:
        """Теневые регистры после obs_snap(): консистентный атомарный снимок."""
        vals = [self._reg_r(self.OBS_SHADOW_BASE + 4 * i)
                for i in range(len(self._OBS_ORDER))]
        d = dict(zip(self._OBS_ORDER, vals))
        d["cycles"] = (d.pop("cycles_hi") << 32) | d.pop("cycles_lo")
        return d

    # ---- данные ----
    def write_tf48(self, addr: int, bits_list) -> None:
        """Раскладывает список 48-битных TFloat48 по 8 байт/элемент."""
        buf = bytearray()
        for b in bits_list:
            buf += struct.pack("<Q", b & 0xFFFFFFFFFFFF)
        # DMA-путь (h2c_0): в DFX-сборке MMIO-моста к DDR3 нет; mock-устройство
        # наследует базовую реализацию write_dma поверх MMIO — verify работает.
        self.dev.write_dma(addr, bytes(buf))

    def read_tf48(self, addr: int) -> int:
        return struct.unpack("<Q", self.dev.read_dma(addr, 8))[0] & 0xFFFFFFFFFFFF

    # ---- 6-байт packing (TFloat48 = ровно 6 байт; экономия 25% DDR3/PCIe) ----
    # Экономия: пара data+weights = 12 байт вместо 16 -> PCIe-потолок +33%.
    # ТРЕБУЕТ от RTL: burst-адрес i*6 (не i*8) и word-straddle barrel
    # (элементы пересекают 64-битные слова). RTL tdot_axi4 сейчас читает i*8,
    # 6 не кратна 8 -> packed-AXI с выравниванием. Это отдельная RTL-задача.
    def pack_tf48(self, bits_list) -> bytes:
        buf = bytearray()
        for b in bits_list:
            buf += struct.pack("<Q", b & 0xFFFFFFFFFFFF)[:6]
        return bytes(buf)

    def unpack_tf48(self, buf: bytes, n: int) -> list:
        out = []
        for i in range(n):
            out.append(int.from_bytes(buf[i*6:(i+1)*6], "little"))
        return out

    def write_tf48_packed(self, addr: int, bits_list) -> None:
        self.dev.write_dma(addr, self.pack_tf48(bits_list))

    def read_tf48_packed(self, addr: int, n: int) -> list:
        return self.unpack_tf48(self.dev.read_dma(addr, n * 6), n)

    # ---- высокоуровневый вызов ----
    def dot(self, data_bits, weights_bits, data_addr: int = 0x0,
            weights_addr: int = 0x1000, result_addr: int = 0x2000) -> int:
        """Записывает data/weights в DDR3, запускает ядро, возвращает результат.

        data_addr/weights_addr/result_addr — СМЕЩЕНИЯ внутри DDR3 (от DDR3_BASE).
        """
        n = len(data_bits)
        if n == 0 or len(weights_bits) != n or n > self.num_mac:
            raise ValueError(f"ожидается 1..{self.num_mac} пар, получено {n}")
        self.write_tf48(data_addr, data_bits)
        self.write_tf48(weights_addr, weights_bits)
        self.set_addrs(data_addr, weights_addr, result_addr)
        self.set_n(n)
        self.start()
        self.wait_done()
        return self.read_tf48(result_addr)


# ---------------------------------------------------------------------------
# Аппаратный планировщик: ring-buffer команд в DDR3 + doorbell + IRQ
# (RTL: tdot_axi4.sv CS_FETCH_DESC/CS_SCHED_KICK/CS_CMP1..3; regs 0x40..0x60)
# ---------------------------------------------------------------------------
SCHED_CTRL     = 0x40   # bit0 sched_en, bit1 irq_en, bit2 flush, bit3 irq_ack
SCHED_WPTR     = 0x44
SCHED_RPTR     = 0x48   # RO
SCHED_DESC_LO  = 0x4C
SCHED_DESC_HI  = 0x50
SCHED_COMP_LO  = 0x54
SCHED_COMP_HI  = 0x58
SCHED_STATUS   = 0x5C   # RO: bit0 sched_busy, bit1 irq_pending
SCHED_DONE_CNT = 0x60   # RO: 16-bit счётчик завершённых задач

# Дескриптор 32 Б (4×64b LE): W0 data_addr, W1 weights_addr, W2 result_addr
# (полные AXI-адреса, помещаются в 32 бита), W3 {16'h0, n_total, tag}.
# Завершение 16 Б (2×64b LE): W0 {tag[15:0], result[47:0]},
# W1 {48'h0, passes[7:0], status[7:0]}.
DESC_STRIDE = 32
COMP_STRIDE = 16

# Слои DDR3 под планировщик (в стороне от данных ядра 0x0..0x4000
# и selftest-паттерна 0x0100_0000; docs/ADDRESS_MAP.md §6)
SCHED_DESC_OFF = 0x0010_0000   # таблица дескрипторов (1024 × 32 Б = 32 КБ) // RING-1024
SCHED_COMP_OFF = 0x0011_0000   # область завершений   (1024 × 16 Б = 16 КБ) // RING-1024
SCHED_RING_DEPTH = 256               # аппаратное кольцо (1024 после прошивки RING-1024)

# Device-side completion mailbox (WAITW-аналог, openTPU). Адрес выбран в
# свободном промежутке DDR3 между областью завершений (0x0011_4000) и
# регионом data планировщика (0x0020_0000) — не пересекается ни с desc/comp/
# result, ни с selftest-паттерном 0x0100_0000 (docs/ADDRESS_MAP.md §6).
# Формат и протокол — docs/device-prog-2026-10-20.md §"Completion mailbox".
MAILBOX_OFF = 0x0012_0000      # base завершения-статуса в DDR3 (смещение от 0x8000_0000)
MAILBOX_FLAG_OFF  = 0x00       # флаг готовности host (движок читает/не трогает)
MAILBOX_STATUS_OFF = 0x08      # статус-слово завершения, пишет движок (64-бит LSW)
MAILBOX_STRIDE = 0x10          # шаг слота, чтобы флаг и статус никогда не пересекались
MAILBOX_STATUS_FREE = 0x0      # 0 = слот свободен (движок ещё не писал)
MAILBOX_STATUS_DONE = 0x1      # 1 = батч завершён, result валиден


class TdotScheduler:
    """Батчевый запуск dot-задач через аппаратный планировщик.

    Поток: submit() наливает дескрипторы DMA h2c и пишет WPTR (doorbell) ->
    железо само выбирает задачи, long-dot (n_total > NUM_MAC) раскладывает
    на проходы, пишет результаты и completion -> wait() ждёт IRQ
    (/dev/xdma0_events_0) или поллит RPTR -> collect() читает завершения c2h.
    """

    def __init__(self, dev: XdmaDevice, num_mac: int = 32,
                 ring_depth: int = SCHED_RING_DEPTH,
                 desc_off: int = SCHED_DESC_OFF,
                 comp_off: int = SCHED_COMP_OFF):
        if num_mac not in (8, 16, 32):
            raise ValueError(f"num_mac={num_mac}: ожидается 8/16/32")
        self.dev = dev
        self.num_mac = num_mac
        self.depth = ring_depth
        self.mask = ring_depth - 1   # кольцевая маска указателей (mod depth)
        self.desc_off = desc_off
        self.comp_off = comp_off
        self._wptr = 0            # локальная копия WPTR (хостовая)
        self._rptr_done = 0       # сколько завершений уже забрано collect()
        # RST 2026-10-20 (robust init): определить-сброс кольца. Раньше init мог
        # оставлять в desc-памяти «битые» дескрипторы от прошлых прогонов, и движок
        # сам продвигал RPTR к старому WPTR (показывая ложное «кольцо полно»).
        # Действия: (1) sched_en=0 — стоп; (2) flush — RPTR->0 (только в CS_IDLE);
        # (3) SCHED_WPTR=0 — обнулить аппаратный WPTR; (4) sched_en=1.
        self._reg_w(SCHED_CTRL, 0)                       # stop
        time.sleep(0.001)
        self._reg_w(SCHED_CTRL, 1 << 2)                  # flush (самоочистка)
        time.sleep(0.001)
        self._reg_w(SCHED_CTRL, 0)                       # снять flush
        self._reg_w(SCHED_WPTR, 0)                       # hw wptr = 0
        time.sleep(0.001)
        self._wptr = 0
        self._rptr_done = 0
        self._reg_w(SCHED_DESC_LO, (DDR3_BASE + desc_off) & 0xFFFFFFFF)
        self._reg_w(SCHED_DESC_HI, ((DDR3_BASE + desc_off) >> 32) & 0xFFFFFFFF)
        self._reg_w(SCHED_COMP_LO, (DDR3_BASE + comp_off) & 0xFFFFFFFF)
        self._reg_w(SCHED_COMP_HI, ((DDR3_BASE + comp_off) >> 32) & 0xFFFFFFFF)
        self._reg_w(SCHED_CTRL, 0x1)                     # sched_en=1 (движок работает)
        # Защита от перемешивания очереди: кольцо — ОДИН hardware-движок, но
        # данные могут подаваться с разных каналов/потоков. Любая submit/wait/
        # collect-последовательность выполняется атомарно, чтобы дескрипторы и
        # doorbell одной партии не вклинились между другой.
        self._lock = threading.RLock()

    # ---- регистры ----
    def _reg_w(self, off: int, val: int) -> None:
        self.dev.write(REG_BASE + off, struct.pack("<I", val & 0xFFFFFFFF))

    def _reg_r(self, off: int) -> int:
        return struct.unpack("<I", self.dev.read(REG_BASE + off, 4))[0]

    # ---- запуск ----
    def submit(self, jobs, data_base: int = 0x0020_0000) -> int:
        """jobs: iterable (data_bits, weights_bits, result_off, tag).

        ... (см. для конвейера dot_batch: data_base задаёт блок данных этой
        партии; разные sub-батчи используют РАЗНЫЕ блоки, чтобы не затирать
        данные, которые движок ещё читает.)
        """
        jobs = list(jobs)
        if not jobs:
            return 0
        # FIX 2026-10-14 (планировщик, обёртка кольца): при ровно depth задачах
        # wptr/rptr обнуляются (mod depth) — различить 0 от depth невозможно,
        # wait() ложно «успевает», collect падает с done==0. Запрещаем пакеты
        # размером >= depth (максимум depth-1).
        if len(jobs) >= self.depth:
            raise ValueError(f"{len(jobs)} задач >= глубины кольца {self.depth} "
                             f"(обёртка mod {self.depth} невозможна; максимум "
                             f"{self.depth - 1} задач за пакет)")
        rptr = self._reg_r(SCHED_RPTR) & self.mask          # RING-1024 2026-10-20
        pending = (self._wptr - rptr) & self.mask           # RING-1024 2026-10-20
        if pending + len(jobs) > self.depth:
            raise ValueError(f"кольцо переполнено: pending={pending}, "
                             f"новых={len(jobs)}, глубина={self.depth}; "
                             f"вызовите collect()/wait()")
        # Проход 1: пакуем данные+веса всех задач в ОДИН буфер (данные, затем веса)
        # и запоминаем метаданные дескрипторов. FIX-AUDIT-VS 2026-10-20 (packed
        # submit): каждый host-IOCTL XdmaWinDma стоит ~15 мс, поэтому минимизируем
        # число вызовов.
        data_blob = bytearray()
        w_blob = bytearray()
        meta = []                      # (n, tag, result_off)
        for idx, (data_bits, weights_bits, result_off, tag) in enumerate(jobs):
            n = len(data_bits)
            if n == 0 or len(weights_bits) != n:
                raise ValueError(f"job {idx}: пусто/размеры не совпадают")
            if n > 16 * self.num_mac:
                raise ValueError(f"job {idx}: n={n} > MAX_N_TOTAL="
                                 f"{16 * self.num_mac} (сатурация в RTL)")
            data_blob += _pack_tf48(data_bits)
            w_blob += _pack_tf48(weights_bits)
            meta.append((n, tag & 0xFFFF, result_off))
        # Проход 2: дескрипторы (веса лежат сразу после всего блока данных)
        totalD = len(data_blob)
        off = 0
        blob = bytearray()
        for n, tag, result_off in meta:
            data_off = data_base + off
            weights_off = data_base + totalD + off
            off += n * 8
            blob += struct.pack("<QQQQ",
                                (DDR3_BASE + data_off) & 0xFFFFFFFFFFFF,
                                (DDR3_BASE + weights_off) & 0xFFFFFFFFFFFF,
                                (DDR3_BASE + result_off) & 0xFFFFFFFFFFFF,
                                ((n & 0xFFFF) << 16) | tag)
        # 1 DMA на данные+веса + 1 на дескрипторы = минимум вызовов за батч
        if data_blob:
            self.dev.write_dma(data_base, bytes(data_blob) + bytes(w_blob))
        # запись дескрипторов с учётом wrap кольца (максимум двумя кусками)
        start = self._wptr % self.depth
        first = min(len(jobs), self.depth - start)
        self.dev.write_dma(self.desc_off + start * DESC_STRIDE,
                           bytes(blob[:first * DESC_STRIDE]))
        if first < len(jobs):
            self.dev.write_dma(self.desc_off,
                               bytes(blob[first * DESC_STRIDE:]))
        self._wptr = (self._wptr + len(jobs)) & self.mask   # RING-1024 2026-10-20
        self._reg_w(SCHED_WPTR, self._wptr)          # doorbell
        return len(jobs)

    # ---- ожидание ----
    def wait(self, count: int | None = None, timeout_ms: float = 5000.0,
             use_events: bool = True) -> int:
        """Ждать завершения count задач (по умолчанию — всех поставленных).

        Приоритет: блокирующее чтение /dev/xdma0_events_0 (IRQ при
        опустошении очереди), иначе поллинг RPTR каждые 200 мкс.
        Возвращает число незабранных завершений.
        """
        if count is None:
            count = (self._wptr - (self._reg_r(SCHED_RPTR) & self.mask)) & self.mask   # RING-1024 2026-10-20
        # FIX-PIPELINE 2026-10-20: при конвейере движок может выполнить БОЛЬШЕ,
        # чем count (следующий sub-батч уже в полёте) — RPTR «перешагивает»
        # точный target. Завершаемся, когда сделано >= count (mod 256).
        t0 = time.monotonic()
        events = "/dev/xdma0_events_0"
        while True:
            rptr = self._reg_r(SCHED_RPTR) & self.mask            # RING-1024 2026-10-20
            if ((rptr - self._rptr_done) & self.mask) >= count:   # RING-1024 2026-10-20
                return (self._wptr - rptr) & self.mask
            if (time.monotonic() - t0) * 1000.0 > timeout_ms:
                raise XdmaError(
                    f"таймаут ожидания планировщика ({timeout_ms} мс): "
                    f"RPTR={rptr}, сделано={(rptr - self._rptr_done) & self.mask}, "  # RING-1024 2026-10-20
                    f"ждали {count}; STATUS=0x{self._reg_r(SCHED_STATUS):X}")
            if use_events and os.path.exists(events) and os.access(events, os.R_OK):
                try:
                    with open(events, "rb", buffering=0) as f:
                        f.read(4)            # блокируется до IRQ
                except OSError:
                    pass                     # драйвер без user-IRQ — поллинг
            else:
                time.sleep(0.0002)

    # ---- приём результатов ----
    def collect(self, n: int | None = None):
        """Читать завершения (RPTR..), возвращать список словарей
        {tag, result_bits, status, passes}. result_bits — 48-битный TFloat48."""
        rptr = self._reg_r(SCHED_RPTR) & self.mask           # RING-1024 2026-10-20
        done = (rptr - self._rptr_done) & self.mask            # RING-1024 2026-10-20
        if n is None:
            n = done
        if n > done:
            raise XdmaError(f"запрошено {n} завершений, готово {done}")
        out = []
        left = n
        while left > 0:
            idx = self._rptr_done % self.depth
            chunk = min(left, self.depth - idx)       # до wrap кольца
            raw = self.dev.read_dma(self.comp_off + idx * COMP_STRIDE,
                                    chunk * COMP_STRIDE)
            for k in range(chunk):
                w0, w1 = struct.unpack_from("<QQ", raw, k * COMP_STRIDE)
                out.append({
                    "tag": (w0 >> 48) & 0xFFFF,
                    "result_bits": w0 & 0xFFFFFFFFFFFF,
                    "status": w1 & 0xFF,
                    "passes": (w1 >> 8) & 0xFF,
                })
            self._rptr_done = (self._rptr_done + chunk) & self.mask   # RING-1024 2026-10-20
            left -= chunk
        return out

    # ---- удобный батч ----
    def dot_batch(self, pairs, timeout_ms: float = 5000.0):
        """pairs: [(data_bits, weights_bits), ...] — пакет dot с автотегами.

        FIX-PIPELINE 2026-10-20: окно пиlпелинга ограничено глубиной кольца
        (2 sub-батча <= depth-1), поэтому большие батчи быстрее гнать min-числом
        ДЛИННЫХ submit'ов (~1000 задач/под при depth=1024) — фиксированные
        ~60 мс на подвызов амортизируются на больше задач. Резyльтаты в порядке
        подачи. // RING-1024 2026-10-20
        """
        if not pairs:
            return []
        CH = self.depth - 6       # задач на sub-батч (запас под depth-1)
        subs = [pairs[k:k + CH] for k in range(0, len(pairs), CH)]
        gidx = 0
        def make_jobs(s):
            nonlocal gidx
            jobs = []
            for d, w in s:
                jobs.append((d, w, 0x00A0_0000 + gidx * 8, gidx & 0xFFFF))
                gidx += 1
            return jobs
        out = []
        with self._lock:                  # атомарно весь батч
            for jobs in (make_jobs(s) for s in subs):
                self.submit(jobs)
                self.wait(len(jobs), timeout_ms=timeout_ms)
                comps = self.collect(len(jobs))
                for c in comps:
                    if c["status"] != 0:
                        raise XdmaError(f"задача tag={c['tag']}: status={c['status']}")
                    out.append(c["result_bits"])
        return out


# ---------------------------------------------------------------------------
# Device-side completion mailbox (WAITW-аналог, openTPU). Это host-инфраструктура
# синхронизации «на батч вместо per-task»: вместо ~15мс host-IOCTL на каждую
# задачу движок сам пишет одно статус-слово в DRAM-mailbox, а host читает ОДНО
# слово в конце батча. Сейчас движок ЕЩЁ НЕ пишет статус (это будущий RTL,
# п.2/4 device-prog-2026-10-20.md) — данный класс задаёт документированную точку,
# куда движок будет писать, и валидирует канал чтения на текущей плате
# (см. scripts/mailbox_check.py). NB: НЕ меняет существующие методы
# TdotScheduler/TdotCore — только аддитивная надстройка.
# ---------------------------------------------------------------------------
class CompletionMailbox:
    """Документированная точка device-side синхронизации в DRAM.

    Слоты (смещения от base_addr, stride 0x10 — см. MAILBOX_OFF):
      +0x00  flag : host пишет «флаг готовности» (движок может читать, чтобы
                    узнать, что host вооружил батч); host не ждёт его в рантайме
                    (это просто сигнал готовности, не обязан двигаться).
      +0x08  status: STATUS-слово завершения. Пишет ДВИЖОК (будущий RTL), как
                    только батч полностью обработан. 0 = свободно (движок не
                    трогал), != 0 (обычно MAILBOX_STATUS_DONE=1) = батч готов.

    Поддержка ввода-вывода — через существующий DMA-канал read_dma/write_dma
    (c2h/h2c): addr здесь — СМЕЩЕНИЕ внутри окна DDR3, как и везде в драйвере.
    """

    def __init__(self, dev: XdmaDevice, base_addr: int = MAILBOX_OFF,
                 poll_us: float = 200.0):
        """dev — XdmaDevice; base_addr — смещение mailbox-слота в DDR3 (от 0x80000000)."""
        self.dev = dev
        self.base = base_addr
        self.poll_us = poll_us

    def _slot(self, off: int) -> int:
        return self.base + off

    # ---- host -> mailbox ----
    def write_flag(self, word: int = MAILBOX_STATUS_DONE) -> None:
        """Host пишет «флаг готовности» в слот flag (+0x00).

        Передаёт движку сигнал, что параметры и данные батча выложены и host
        вооружён ждать статус. Движок пока ничего не пишет — этот слот оставлен
        как пассивный маркер (движок может читать его как подтверждение arming).
        """
        self.dev.write_dma(self._slot(MAILBOX_FLAG_OFF),
                           struct.pack("<Q", word & 0xFFFFFFFFFFFFFFFF))

    # ---- mailbox -> host (ожидание статуса движка) ----
    def read_status(self, addr: int = MAILBOX_STATUS_OFF,
                    timeout_ms: float = 5000.0,
                    expected: int = MAILBOX_STATUS_DONE) -> int:
        """Дождаться, пока движок запишет статус в слот (на WAITW-манер openTPU).

        addr — смещение статус-слота внутри DDR3 (по умолч. base+0x08);
        читаем ОДНО 64-битное слово через read_dma и берём LSW. Поллинг с шагом
        poll_us (~200 мкс) до наступления срока timeout_ms. Возвращает прочитанное
        слово статуса (LSW). expected=0 означает «ждать любое ненулевое значение»;
        иначе — ждать именно == expected.
        """
        if not (self._is_off(addr)):
            raise XdmaError(f"mailbox: недопустимый статус-адрес 0x{addr:X}")
        t0 = time.monotonic()
        while True:
            raw = self.dev.read_dma(self._slot(addr), 8)
            lsw = struct.unpack("<Q", raw[:8])[0] & 0xFFFFFFFF
            if expected:
                if lsw == expected:
                    return lsw
            elif lsw != 0:
                return lsw
            if (time.monotonic() - t0) * 1000.0 > timeout_ms:
                raise XdmaError(
                    f"mailbox таймаут ({timeout_ms} мс): статус-слово по 0x"
                    f"{self._slot(addr):X} всё ещё 0x{lsw:X} "
                    f"(ожидалось {'!= 0' if not expected else hex(expected)})")
            time.sleep(self.poll_us / 1e6)

    @staticmethod
    def _is_off(addr: int) -> bool:
        """Статус-слот — это неотрицательное смещение от base_addr."""
        return isinstance(addr, int) and addr >= 0


# ---------------------------------------------------------------------------
# DeviceProgRunner — host-драйвер программного режима (DEVPROG_EN=1).
#
# Управляет аппаратным интерпретатором device_prog поверх кольца tdot
# (rtl/integration/tdot_axi4.sv + rtl/integration/device_prog.sv). Хост
# заливает в DDR3 данные и 32-байтную таблицу юнитов, программирует регистры
# DP_* (0xE4..0xF0), дёргает GO и ждёт completion-mailbox (16 Б) в DDR3.
#
# АДРЕСНАЯ СЕМАНТИКА (сверено с RTL — см. отчёт):
#   * data_bytes / table_bytes / out_base / mbox_off — СМЕЩЕНИЯ внутри окна
#     DDR3 (отсчитываются от 0x8000_0000), как во всём драйвере: через них
#     идут write_dma/read_dma (DMA-каналы h2c/c2h).
#   * регистры DP_DATA_BASE/DP_TABLE_BASE/DP_MBOX_BASE принимают ПОЛНЫЕ AXI-
#     адреса (DDR3_BASE + смещение). device_prog.sv использует data_base/
#     table_base/mailbox_base как абсолютные адреса для M_AXI_ARADDR/AWADDR
#     (fetch_addr = table_base + u_idx*32 + fetch_cnt*8, поиск задачи идёт по
#     data_base / out_addr, mailbox пишется по mailbox_base/+8). Поэтому при
#     записи в регистры добавляем DDR3_BASE, как это делает TdotCore.set_addrs.
#   * CompletionMailbox читает статус через read_dma по СМЕЩЕНИЮ (base_addr —
#     DDR3-offset), поэтому mbox_off передаём как есть.
# ---------------------------------------------------------------------------
class DeviceProgRunner:
    """Программный запуск одной программы device_prog на плате."""

    # Регистры программного режима (смещения от reg_base; tdot_axi4.sv §0xE4..0xF0).
    DP_CTRL        = 0xE4   # W: bit0=go (импульс), [31:16]=n_units
    DP_DATA_BASE   = 0xE8   # W: база данных (полный AXI адрес, DDR)
    DP_TABLE_BASE  = 0xEC   # W: база таблицы юнитов (полный AXI адрес, DDR)
    DP_MBOX_BASE   = 0xF0   # W: база completion-mailbox (полный AXI адрес, DDR)
    DP_STAT        = 0xF4   # R: {8'd0, fifo_level, stall_code[15:0], wdog_active, complete, active} (6'd61)

    def __init__(self, dev: XdmaDevice, num_mac: int = 32, reg_base: int = REG_BASE):
        self.dev = dev
        self.num_mac = num_mac
        self.reg_base = reg_base

    # ---- регистры программного режима ----
    def _reg_w(self, off: int, val: int) -> None:
        self.dev.write(self.reg_base + off, struct.pack("<I", val & 0xFFFFFFFF))

    def _reg_r(self, off: int) -> int:
        return struct.unpack("<I", self.dev.read(self.reg_base + off, 4))[0]

    def state(self) -> dict:
        """Прочитать DP_CTRL (6'd57): [31:16]=n_units, bit0=dprog_active.

        Полезно для диагностики, «активно ли программное ядро». При
        DEVPROG_EN=0 регистры инертны и active всегда 0."""
        v = self._reg_r(self.DP_CTRL)
        return {"active": bool(v & 0x1), "n_units": (v >> 16) & 0xFFFF}

    def run(self, data_bytes, table_bytes, n_units, out_base, out_bytes,
            timeout_ms: float = 5000.0, mbox_off: int = MAILBOX_OFF,
            data_base: int | None = None, table_base: int | None = None) -> bytes:
        """Залить данные+таблицу, запустить программу и вернуть результат.

        data_bytes/table_bytes — сырые байты (готовит пользователь);
        n_units — число 32-байтных юнитов в table_bytes;
        out_base — смещение результата внутри DDR3; out_bytes — сколько прочесть;
        mbox_off — смещение completion-mailbox в DDR3 (по умолч. MAILBOX_OFF);
        data_base/table_base — смещения данных и таблицы юнитов внутри DDR3
            (как и out_base — СМЕЩЕНИЯ). Если не заданы, выбираются заведомо
            свободные регионы выше области результата (0x00A0_0000 result).

        Возвращает out_bytes байт результата (raw, без распаковки).
        """
        if n_units <= 0 or n_units > 0xFFFF:
            raise ValueError(f"n_units={n_units}: ожидается 1..0xFFFF")
        if len(table_bytes) != n_units * 32:
            raise ValueError(
                f"table_bytes={len(table_bytes)} Б != n_units*32 = {n_units * 32} Б "
                f"(каждый юнит ровно 32 байта = 4 слова по 64 бит)")
        if not data_bytes:
            raise ValueError("data_bytes пуст")
        if out_bytes <= 0:
            raise ValueError(f"out_bytes={out_bytes}: ожидается > 0")

        # Базы, если не заданы: берём свободные смещения в стороне от result
        # и от занятых регионов планировщика (0x0010_0000/0x0011_0000/0x0020_0000).
        if data_base is None:
            data_base = 0x00B0_0000
        if table_base is None:
            table_base = 0x0013_0000      # свободный промежуток после comp-области

        # a. DMA — смещения внутри DDR3 (канал h2c).
        self.dev.write_dma(mbox_off, b"\x00" * 16)        # сброс mailbox-слота
        self.dev.write_dma(data_base, data_bytes)
        self.dev.write_dma(table_base, table_bytes)

        # b. Регистры: данные/таблица/mailbox — ПОЛНЫЕ AXI-адреса, GO = n_units|1.
        #    (только старшие 32 бита фиксируются; полный адрес умещается в них).
        self._reg_w(self.DP_DATA_BASE,  (DDR3_BASE + data_base) & 0xFFFFFFFF)
        self._reg_w(self.DP_TABLE_BASE, (DDR3_BASE + table_base) & 0xFFFFFFFF)
        self._reg_w(self.DP_MBOX_BASE,  (DDR3_BASE + mbox_off) & 0xFFFFFFFF)
        self._reg_w(self.DP_CTRL, ((n_units & 0xFFFF) << 16) | 0x1)

        # c. Ожидание completion-mailbox. Статус в LSW (младшие 8 бит):
        #    0 = успех, !=0 = abort/ошибка (BUG-085: abort пишет status=1).
        mb = CompletionMailbox(self.dev, base_addr=mbox_off)
        try:
            lsw = mb.read_status(timeout_ms=timeout_ms, expected=0)
        except XdmaError as exc:
            # FIX BUG-085: на таймаут mailbox — диагностика DP_STAT вместо вечного ожидания.
            raise XdmaError(f"{exc}; DP_STAT diagnose: {self.diagnose()}") from exc
        status = lsw & 0xFF
        if status != 0:
            # FIX BUG-085: завершено с ошибкой — НЕ отдавать результат как валидный.
            raise XdmaError(
                f"device_prog завершил с ошибкой: status=0x{status:02X} "
                f"(mailbox LSW=0x{lsw:08X}); DP_STAT diagnose: {self.diagnose()}")

        # d. Чтение результата (только при status==0).
        return self.dev.read_dma(out_base, out_bytes)

    def diagnose(self) -> dict:
        """Прочитать DP_STAT (0xF4 = 6'd61) для диагностики после таймаута/ошибки.

        Поле: {8'd0, fifo_level[7:0], stall_code[15:0], wdog_active, complete, active}.
        stall_code: 0xA5A5 = рwdog-стой; 0xAB01 = abort (BUG-085).
        """
        v = self._reg_r(self.DP_STAT)
        return {
            "active": bool(v & 0x1),
            "complete": bool(v & 0x2),
            "wdog_active": bool(v & 0x4),
            "stall_code": (v >> 3) & 0xFFFF,    # фактические позиции rdata (tdot_axi4.sv:526-527)
            "fifo_level": (v >> 19) & 0xFF,
        }


def _pack_tf48(bits_list) -> bytes:
    buf = bytearray()
    for b in bits_list:
        buf += struct.pack("<Q", b & 0xFFFFFFFFFFFF)
    return bytes(buf)


# ---------------------------------------------------------------------------
# Самопроверка DMA-пути на железе:
#   python xdma_driver.py --selftest            # паттерн h2c/c2h + замер МБ/с
#   python xdma_driver.py --selftest --dot      # + один вызов TdotCore.dot
#   python xdma_driver.py --selftest --dot --sched 16   # + планировщик (16+1 задач)
# ---------------------------------------------------------------------------
def _selftest(argv=None) -> int:
    import argparse
    import time as _time

    ap = argparse.ArgumentParser(
        description="Самопроверка DMA-пути (h2c/c2h) XDMA → DDR3")
    ap.add_argument("--size", type=lambda x: int(x, 0), default=4 << 20,
                    help="объём тестового буфера (по умолчанию 4 МиБ)")
    ap.add_argument("--off", type=lambda x: int(x, 0), default=0x01000000,
                    help="смещение в DDR3 в стороне от данных ядра "
                         "(по умолчанию 0x01000000 = 16 МиБ)")
    ap.add_argument("--dot", action="store_true",
                    help="дополнительно выполнить один вызов TdotCore.dot")
    ap.add_argument("--sched", type=lambda x: int(x, 0), default=0, metavar="K",
                    help="дополнительно прогнать K задач через аппаратный "
                         "планировщик (по умолчанию 16)")
    args = ap.parse_args(argv)

    try:
        dev = XdmaLinux()
    except (XdmaError, NameError):
        dev = XdmaWindows()
    kind = type(dev).__name__
    print(f"устройство: {kind}; h2c={getattr(dev, 'has_h2c', '-')} "
          f"c2h={getattr(dev, 'has_c2h', '-')} usr={getattr(dev, 'has_usr', '-')}")

    # 1. Паттерн: запись → чтение → сверка (детерминированный LCG-паттерн)
    buf = bytes(((i * 2654435761) >> 24) & 0xFF for i in range(args.size))
    t0 = _time.monotonic()
    dev.write_dma(args.off, buf)
    t1 = _time.monotonic()
    rb = dev.read_dma(args.off, args.size)
    t2 = _time.monotonic()
    if rb != buf:
        # показать первый рассинхрон
        i = next((k for k, (x, y) in enumerate(zip(buf, rb)) if x != y),
                 min(len(buf), len(rb)))
        raise XdmaError(f"паттерн не сошёлся: первый расход на смещении "
                        f"0x{i:X} (write=0x{buf[i]:02X} read=0x{rb[i]:02X})")
    h2c_mbs = args.size / (t1 - t0) / (1 << 20)
    c2h_mbs = args.size / (t2 - t1) / (1 << 20)
    print(f"паттерн {args.size >> 20} МиБ: OK; h2c {h2c_mbs:.0f} МиБ/с, "
          f"c2h {c2h_mbs:.0f} МиБ/с")

    # 2. (опционально) Один dot через ядро: 8 пар 1.0*1.0 -> 8.0
    if args.dot:
        from fpga_backend import FpgaBackend, DDR_DATA, DDR_WEIGHTS, DDR_RESULT
        fb = FpgaBackend(mode="cpu", n=8)
        bits = [fb._to_bits48(v) for v in [1.0] * 8]
        core = TdotCore(dev, num_mac=32)
        res_bits = core.dot(bits, bits,
                            data_addr=DDR_DATA, weights_addr=DDR_WEIGHTS,
                            result_addr=DDR_RESULT)
        got = fb._bits_to_float(res_bits)
        if abs(got - 8.0) > 0.05:
            raise XdmaError(f"dot(1.0 x 8) = {got!r}, ожидалось 8.0")
        print(f"dot(1.0 × 8) = {got:.4f}: OK")

    # 3. (опционально) Аппаратный планировщик: K задач + один long-dot
    if args.sched:
        k = args.sched
        from fpga_backend import FpgaBackend
        fb = FpgaBackend(mode="cpu", n=32)
        one = [fb._to_bits48(v) for v in [1.0] * 32]
        two = [fb._to_bits48(v) for v in [1.0] * 64]   # long-dot: 2 прохода
        pairs = [(one, one)] * k
        pairs.append((two, two))                       # n=64 > NUM_MAC=32
        sched = TdotScheduler(dev, num_mac=32)
        t3 = _time.monotonic()
        res = sched.dot_batch(pairs)
        dt = (_time.monotonic() - t3) * 1e3
        for i, rb in enumerate(res):
            expected = 64.0 if i == k else 32.0
            got = fb._bits_to_float(rb)
            if abs(got - expected) > 0.5:
                raise XdmaError(f"планировщик job {i}: {got!r}, "
                                f"ожидалось {expected}")
        print(f"планировщик: {k + 1} задач (вкл. long-dot 64) за {dt:.1f} мс "
              f"({dt / (k + 1) * 1000:.0f} мкс/задача): OK")
    return 0


if __name__ == "__main__":
    import sys as _sys
    _sys.exit(_selftest())
