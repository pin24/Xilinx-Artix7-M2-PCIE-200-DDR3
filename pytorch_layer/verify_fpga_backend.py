"""Сверка FPGA-бэкенда (TdotCore + FpgaBackend) без железа.

Использует mock-устройство (XdmaDevice с памятью), которое повторяет поведение
XDMA: запись/чтение DDR3 по адресу. Проверяем, что:
  1. TdotCore.dot раскладывает TFloat48 по 8 байт/элемент (младшие 48 бит).
  2. Регистры пишутся по адресам REG_BASE+off.
  3. Результат, полученный через mock, совпадает с CPU-эмуляцией.
"""
from __future__ import annotations
import os, sys, struct
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw"))

from block.tfloat48 import TFloat
from fpga_backend import FpgaBackend, DDR_DATA, DDR_WEIGHTS, DDR_RESULT
from xdma_driver import XdmaDevice, TdotCore, REG_BASE, DDR_BASE


class MockMem(XdmaDevice):
    """Простая память, повторяет поведение XDMA read/write по байтовому адресу."""

    def __init__(self, size: int = 0x4000):
        self.mem = bytearray(size)
        self.regs = {}   # (addr) -> int, для регистров ядра

    def read(self, addr: int, length: int) -> bytes:
        if addr >= DDR_BASE:
            off = addr - DDR_BASE
            return bytes(self.mem[off:off + length])
        # регистр
        return struct.pack("<I", self.regs.get(addr, 0))

    def write(self, addr: int, data: bytes) -> None:
        if addr >= DDR_BASE:
            off = addr - DDR_BASE
            self.mem[off:off + len(data)] = data
        else:
            self.regs[addr] = struct.unpack("<I", data)[0]


class TdotCoreMock(TdotCore):
    """TdotCore, который ВЫЧИСЛЯЕТ dot на месте (имитация ядра на FPGA).

    Считывает data/weights из mock-памяти так же, как это делает AXI4-мастер,
    считает dot эталоном и кладёт результат в память.
    """

    def __init__(self, dev: MockMem, num_mac: int = 32, ddr_base: int = DDR_BASE):
        super().__init__(dev, num_mac, ddr_base)
        self.mem = dev.mem

    def dot(self, data_bits, weights_bits, data_addr=0x0, weights_addr=0x1000,
            result_addr=0x2000):
        # как настоящий мастер: пишем входные векторы, ставим адреса, GO
        n = len(data_bits)
        self.write_tf48(data_addr, data_bits)
        self.write_tf48(weights_addr, weights_bits)
        self.set_addrs(data_addr, weights_addr, result_addr)
        self.set_n(n)
        self.start()

        # имитация работы ядра: читаем векторы из памяти (8 байт/элемент)
        def read_vec(base):
            out = []
            for i in range(n):
                v = struct.unpack("<Q", self.mem[base + i * 8:base + i * 8 + 8])[0]
                out.append(v & 0xFFFFFFFFFFFF)
            return out

        da = self.dev.regs.get(REG_BASE + 0x14, 0) | (self.dev.regs.get(REG_BASE + 0x18, 0) << 32)
        wa = self.dev.regs.get(REG_BASE + 0x1C, 0) | (self.dev.regs.get(REG_BASE + 0x20, 0) << 32)
        ra = self.dev.regs.get(REG_BASE + 0x24, 0) | (self.dev.regs.get(REG_BASE + 0x28, 0) << 32)

        d = read_vec(da)
        w = read_vec(wa)
        # dot в эталонной raw-модели (как RTL compute_dot_par_raw)
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rtl", "integration"))
        from verify_tdot_axi4 import dot_ref_raw
        res = dot_ref_raw(d, w)
        struct.pack_into("<Q", self.mem, ra, res)
        # статус: DONE=1
        self.dev.regs[REG_BASE + 0x04] = 0b10
        return res


def main():
    np.random.seed(7)
    n = 32
    a = np.random.randn(2, n).astype(np.float32)
    b = np.random.randn(2, n).astype(np.float32)

    be = FpgaBackend(mode="cpu", n=n)
    ref = be.run_dot(a, b)

    # FPGA-путь: mock-ядро (та же конверсия + раскладка, что у реального хоста)
    dev = MockMem()
    core = TdotCoreMock(dev, num_mac=n)
    res = []
    for i in range(2):
        bits_a = be._batch_to_bits(a[i:i+1])[0]
        bits_b = be._batch_to_bits(b[i:i+1])[0]
        r = core.dot(bits_a, bits_b)
        res.append(be._bits_to_float(r))
    res = np.array(res, dtype=np.float32)

    print("CPU (эмуляция):", ref)
    print("FPGA (mock)   :", res)
    diff = np.abs(ref - res).max()
    print("max diff:", diff)
    # допуск: троичная точность ~1e-5
    assert diff < 1e-4, "рассинхрон CPU/FPGA пути"
    print("OK: FPGA-протокол (конверсия, раскладка, регистры, результат) работает")


if __name__ == "__main__":
    main()
