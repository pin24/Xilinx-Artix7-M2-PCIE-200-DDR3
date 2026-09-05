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

# адресная база AXI-Lite регистров ядра (DFX BD, xdma_axi_lite_smc):
#   M00 GPIO  0x4000_0000    M03 TDOT   0x4000_3000
#   M01 DFX sock 0x4000_2000 M04 ICAP   0x4000_4000
#   M02 HWICAP 0x4000_1000   M05 XADC   0x4600_0000
REG_BASE  = 0x4000_3000      # tdot_axi4 регистры
ICAP_BASE = 0x4000_4000      # ICAP-контроллер
GPIO_BASE = 0x4000_0000      # axi_gpio (не используется)
HWICAP_BASE = 0x4000_1000    # axi_hwicap (если потребуется прямой доступ)
DFX_SOCK_BASE = 0x4000_2000  # dfx_socket/decouple_shutdown_ctrl (shutdown/decouple GPIO)
# legacy alias (модульно совместим со старым именем)
DDR_BASE = DDR3_BASE


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
# Самопроверка DMA-пути на железе:
#   python xdma_driver.py --selftest            # паттерн h2c/c2h + замер МБ/с
#   python xdma_driver.py --selftest --dot      # + один вызов TdotCore.dot
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
    return 0


if __name__ == "__main__":
    import sys as _sys
    _sys.exit(_selftest())
