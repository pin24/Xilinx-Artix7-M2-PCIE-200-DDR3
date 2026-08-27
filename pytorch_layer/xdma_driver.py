"""Драйвер XDMA для доступа к троичному ускорителю (TFloat48) на FPGA.

Инкапсулирует взаимодействие хоста с картой:
  - регистры tdot_axi4   (AXI-Lite, через XDMA control / xdma_user на BAR)
  - DDR3 (XDMA M_AXI, 0x8000_0000) — векторы data/weights и результат.

Два бэкенда:
  - Linux  : файлы устройства /dev/xdma0_control, /dev/xdma0_user (dma).
  - Windows: утилита xdma_rw (exe/xdma_rw), читает/пишет BAR по адресу.

Формат данных в DDR3 (согласовано с tdot_axi4.sv):
  каждый TFloat48 занимает 64-битное слово, младшие 48 бит = число:
    data[i]     по адресу data_addr    + i*8
    weights[i]  по адресу weights_addr + i*8
    результат   по адресу result_addr  (младшие 48 бит)

Регистры tdot_axi4 (32-бит, байтовый адрес, адресная база REG_BASE):
  0x00 CTRL   бит0 GO
  0x04 STATUS бит0 BUSY, бит1 DONE
  0x08 N_IN
  0x0C RES0, 0x10 RES1  (результат [15:0] и [47:32])
  0x14/0x18 DATA_ADDR_LO/HI
  0x1C/0x20 WEIGHTS_ADDR_LO/HI
  0x24/0x28 RESULT_ADDR_LO/HI
  0x2C/0x30 CORE_RES0/CORE_RES1
"""
from __future__ import annotations
import os, subprocess, struct

# адресная база AXI-Lite регистров ядра (из BD: в пределах BAR 64K)
REG_BASE = 0x4000_1000      # tdot_axi4 регистры
ICAP_BASE = 0x4000_2000     # ICAP-контроллер
GPIO_BASE = 0x4000_0000     # axi_gpio (не используется)
# адресация данных в DDR3 (из BD: MIG memmap на 0x8000_0000)
DDR_BASE = 0x8000_0000


def _tf48_to_bits(t) -> int:
    """TFloat48 -> 48-битное целое (совпадает с to_bits48 в verify)."""
    return ((t.e_int & 0xFF) << 40) | (t.m_int & ((1 << 40) - 1))


class XdmaError(RuntimeError):
    print("XdmaError")
    pass


class XdmaDevice:
    """Абстракция над конкретным драйвером: read/write по байтовому адресу."""

    def read(self, addr: int, length: int) -> bytes:
        raise NotImplementedError

    def write(self, addr: int, data: bytes) -> None:
        raise NotImplementedError


class XdmaLinux(XdmaDevice):
    """Linux: /dev/xdma0_control (BAR/regs) и /dev/xdma0_user (DDR3)."""

    def __init__(self, base: str = "/dev/xdma0"):
        self.ctl = base + "_control"
        self.usr = base + "_user"
        for p in (self.ctl, self.usr):
            if not os.path.exists(p):
                raise XdmaError(f"XDMA-устройство не найдено: {p}")

    def read(self, addr: int, length: int) -> bytes:
        # регистры идём через control (офсет внутри BAR), DDR3 через user
        dev = self.ctl if addr < 0x100000 else self.usr
        with open(dev, "rb", buffering=0) as f:
            f.seek(addr)
            return f.read(length)

    def write(self, addr: int, data: bytes) -> None:
        dev = self.ctl if addr < 0x100000 else self.usr
        with open(dev, "wb", buffering=0) as f:
            f.seek(addr)
            f.write(data)


class XdmaWindows(XdmaDevice):
    """Windows: вызывает xdma_rw.exe (из XDMA_Driver_App)."""

    def __init__(self, tool: str = "xdma_rw", devnode: str = "control"):
        self.tool = tool
        self.devnode = devnode

    def _run(self, args, length=None):
        cmd = [self.tool, self.devnode, args, f"{0x0}", "-l", str(length or 4)]
        r = subprocess.run(cmd, capture_output=True)
        if r.returncode != 0:
            raise XdmaError(f"xdma_rw не выполнился: {r.stderr.decode(errors='replace')}")
        return r.stdout

    def read(self, addr: int, length: int) -> bytes:
        return self._run("read", length)

    def write(self, addr: int, data: bytes) -> None:
        vals = " ".join(f"{b}" for b in data)
        cmd = [self.tool, self.devnode, "write", f"{0x0}", *vals.split()]
        r = subprocess.run(cmd, capture_output=True)
        if r.returncode != 0:
            raise XdmaError(f"xdma_rw write не выполнился: {r.stderr.decode(errors='replace')}")


class TdotCore:
    """Управление ядром tdot_axi4 через XDMA."""

    def __init__(self, dev: XdmaDevice, num_mac: int = 32, ddr_base: int = DDR_BASE):
        self.dev = dev
        self.num_mac = num_mac
        self.ddr = ddr_base

    # ---- регистры ----
    def _reg_w(self, off: int, val: int) -> None:
        self.dev.write(REG_BASE + off, struct.pack("<I", val & 0xFFFFFFFF))

    def _reg_r(self, off: int) -> int:
        return struct.unpack("<I", self.dev.read(REG_BASE + off, 4))[0]

    def set_addrs(self, data_addr: int, weights_addr: int, result_addr: int) -> None:
        self._reg_w(0x14, data_addr & 0xFFFFFFFF)
        self._reg_w(0x18, data_addr >> 32)
        self._reg_w(0x1C, weights_addr & 0xFFFFFFFF)
        self._reg_w(0x20, weights_addr >> 32)
        self._reg_w(0x24, result_addr & 0xFFFFFFFF)
        self._reg_w(0x28, result_addr >> 32)

    def set_n(self, n: int) -> None:
        self._reg_w(0x08, n)

    def start(self) -> None:
        self._reg_w(0x00, 0x1)  # GO

    def status(self) -> tuple:
        s = self._reg_r(0x04)
        return bool(s & 1), bool(s & 2)   # (busy, done)

    def wait_done(self, timeout_ms: float = 5000.0) -> None:
        import time
        t0 = time.time()
        while True:
            busy, done = self.status()
            if done:
                return
            if not busy and done is False:
                # ни busy ни done — не началось, подождём ещё
                pass
            if (time.time() - t0) * 1000 > timeout_ms:
                raise XdmaError("timeout ожидания DONE")

    def read_result_reg(self) -> int:
        lo = self._reg_r(0x0C) & 0xFFFF
        hi = self._reg_r(0x10) & 0xFFFF
        # регистры хранят [15:0] и [47:32]; [31:16] теряется -> читаем из DDR3
        return (hi << 32) | lo

    # ---- данные ----
    def write_tf48(self, addr: int, bits_list) -> None:
        """Раскладывает список 48-битных TFloat48 по 8 байт/элемент."""
        buf = bytearray()
        for b in bits_list:
            buf += struct.pack("<Q", b & 0xFFFFFFFFFFFF)
        self.dev.write(self.ddr + addr, bytes(buf))

    def read_tf48(self, addr: int) -> int:
        return struct.unpack("<Q", self.dev.read(self.ddr + addr, 8))[0] & 0xFFFFFFFFFFFF

    # ---- высокоуровневый вызов ----
    def dot(self, data_bits, weights_bits, data_addr: int = 0x0,
            weights_addr: int = 0x1000, result_addr: int = 0x2000) -> int:
        """Записывает data/weights в DDR3, запускает ядро, возвращает результат."""
        n = len(data_bits)
        if len(weights_bits) != n or n > self.num_mac:
            raise ValueError(f"ожидается до {self.num_mac} пар, получено {n}")
        self.write_tf48(data_addr, data_bits)
        self.write_tf48(weights_addr, weights_bits)
        self.set_addrs(data_addr, weights_addr, result_addr)
        self.set_n(n)
        self.start()
        self.wait_done()
        return self.read_tf48(result_addr)
