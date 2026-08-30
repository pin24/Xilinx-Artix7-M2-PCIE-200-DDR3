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
  0x0C RES0 = result[31:0], 0x10 RES1 = {16'h0, result[47:32]}  (48-битный результат)
  0x14/0x18 DATA_ADDR_LO/HI
  0x1C/0x20 WEIGHTS_ADDR_LO/HI
  0x24/0x28 RESULT_ADDR_LO/HI
  0x2C/0x30 CORE_RES0/CORE_RES1
"""
from __future__ import annotations
import os, subprocess, struct, time

# Границы AXI-окна (согласовано с driver/driver.c FIX-1):
#   BAR0 = AXI-Lite  [0x4000_0000 .. 0x7FFF_FFFF]  (GPIO/TDOT/ICAP/XADC regs)
#   BAR2 = DDR3      [0x8000_0000 .. ]             (data/weights/result)
# Хост шлёт ПОЛНЫЕ AXI-адреса. Драйвер Linux/Windows сам маршрутизирует по этим
# границам и вычитает базу BAR'а, чтобы получить offset внутри BAR-окна.
AXI_LITE_BASE = 0x4000_0000   # начало BAR0 (AXI-Lite): GPIO/TDOT/ICAP/XADC
DDR3_BASE     = 0x8000_0000   # начало BAR2 (DDR3)

# адресная база AXI-Lite регистров ядра (из BD: в пределах BAR 64K)
REG_BASE  = 0x4000_1000      # tdot_axi4 регистры
ICAP_BASE = 0x4000_2000      # ICAP-контроллер
GPIO_BASE = 0x4000_0000      # axi_gpio (не используется)
# legacy alias (модульно совместим со старым именем)
DDR_BASE = DDR3_BASE


def _tf48_to_bits(t) -> int:
    """TFloat48 -> 48-битное целое (совпадает с to_bits48 в verify)."""
    return ((t.e_int & 0xFF) << 40) | (t.m_int & ((1 << 40) - 1))


class XdmaError(RuntimeError):
    """Ошибка взаимодействия с XDMA-устройством."""


class XdmaDevice:
    """Абстракция над конкретным драйвером: read/write по байтовому адресу."""

    def read(self, addr: int, length: int) -> bytes:
        raise NotImplementedError

    def write(self, addr: int, data: bytes) -> None:
        raise NotImplementedError


class XdmaLinux(XdmaDevice):
    """Linux: /dev/xdma0_control (BAR0, AXI-Lite) и /dev/xdma0_user (BAR2, DDR3).

    Хост шлёт ПОЛНЫЕ AXI-адреса (0x4000_xxxx для регистров, 0x8000_xxxx для DDR3).
    Маршрутизация по двум устройствам:
      AXI_LITE_BASE <= addr < DDR3_BASE  →  /dev/xdma0_control,  offset = addr - AXI_LITE_BASE
      addr >= DDR3_BASE                  →  /dev/xdma0_user,     offset = addr - DDR3_BASE
    """

    def __init__(self, base: str = "/dev/xdma0"):
        self.ctl = base + "_control"
        self.usr = base + "_user"
        for p in (self.ctl, self.usr):
            if not os.path.exists(p):
                raise XdmaError(f"XDMA-устройство не найдено: {p}")

    def _route(self, addr: int) -> tuple[str, int]:
        """Вернуть (devpath, bar_offset) по полному AXI-адресу."""
        if AXI_LITE_BASE <= addr < DDR3_BASE:
            return self.ctl, addr - AXI_LITE_BASE
        if addr >= DDR3_BASE:
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
        """Программирует data/weights/result адреса в RTL.

        Параметры da/wa/ra — СМЕЩЕНИЯ внутри DDR3 (в байтах, от 0x8000_0000).
        RTL (tdot_axi4.sv) читает `data_start_reg` как ПОЛНЫЙ AXI-адрес для
        M_AXI_ARADDR — значит, надо писать DDR3_BASE + offset, иначе RTL уйдёт
        читать из BRAM (0x0..0x1FFF) вместо DDR3.
        """
        full_da = DDR3_BASE + data_addr
        full_wa = DDR3_BASE + weights_addr
        full_ra = DDR3_BASE + result_addr
        self._reg_w(0x14, full_da & 0xFFFFFFFF)            # DATA_ADDR_LO
        self._reg_w(0x18, (full_da >> 32) & 0xFFFFFFFF)    # DATA_ADDR_HI
        self._reg_w(0x1C, full_wa & 0xFFFFFFFF)            # WEIGHTS_ADDR_LO
        self._reg_w(0x20, (full_wa >> 32) & 0xFFFFFFFF)    # WEIGHTS_ADDR_HI
        self._reg_w(0x24, full_ra & 0xFFFFFFFF)            # RESULT_ADDR_LO
        self._reg_w(0x28, (full_ra >> 32) & 0xFFFFFFFF)    # RESULT_ADDR_HI

    def set_n(self, n: int) -> None:
        self._reg_w(0x08, n)

    def start(self) -> None:
        self._reg_w(0x00, 0x1)  # GO

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
