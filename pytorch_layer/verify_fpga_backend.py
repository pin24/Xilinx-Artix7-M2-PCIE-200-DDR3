"""Сверка FPGA-бэкенда (TdotCore + FpgaBackend) без железа.

Использует mock-устройство (XdmaDevice с памятью), которое повторяет поведение
XDMA: запись/чтение DDR3 и регистров по полному AXI-адресу. Проверяем, что:
  1. TdotCore.dot раскладывает TFloat48 по 8 байт/элемент (младшие 48 бит).
  2. Регистры пишутся по адресам REG_BASE+off (AXI-Lite).
  3. set_addrs передаёт в RTL ПОЛНЫЕ AXI-адреса (DDR3_BASE+offset).
  4. read_result_reg возвращает 48-битный результат (RES0=result[31:0],
     RES1={16'h0, result[47:32]}).
  5. Результат, полученный через mock, совпадает с CPU-эмуляцией.

Маршрутизация MockMem повторяет driver/driver.c FIX-1:
  AXI_LITE_BASE <= addr < DDR3_BASE  →  BAR0 (регистры, хранятся в self.regs)
  addr >= DDR3_BASE                  →  BAR2 (DDR3, хранится в self.mem с offset=addr-DDR3_BASE)
"""
from __future__ import annotations
import os, sys, struct
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw"))

from block.tfloat48 import TFloat
from fpga_backend import FpgaBackend, DDR_DATA, DDR_WEIGHTS, DDR_RESULT
from xdma_driver import (XdmaDevice, TdotCore, REG_BASE, DDR_BASE,
                          AXI_LITE_BASE, DDR3_BASE)


class XdmaMemError(RuntimeError):
    """Локальная ошибка mock-памяти (вне xdma_driver.XdmaError, чтобы не
    триггерить fallback на XdmaWindows в вызывающем коде)."""
    pass


class MockMem(XdmaDevice):
    """Память + регистры, повторяет поведение XDMA read/write по AXI-адресу.

    Моделирует routing driver/driver.c FIX-1:
      AXI_LITE_BASE <= addr < DDR3_BASE  →  BAR0 (regs[addr])
      addr >= DDR3_BASE                  →  BAR2 (mem[addr - DDR3_BASE])
    """

    def __init__(self, size: int = 0x4000):
        self.mem = bytearray(size)
        self.regs = {}   # addr -> int (32-битные значения)

    def read(self, addr: int, length: int) -> bytes:
        if addr >= DDR3_BASE:
            off = addr - DDR3_BASE
            if off + length > len(self.mem):
                raise XdmaMemError(f"DDR3 read out-of-range: addr=0x{addr:X} "
                                   f"(off=0x{off:X}), len={length}, mem={len(self.mem)}")
            return bytes(self.mem[off:off + length])
        if AXI_LITE_BASE <= addr < DDR3_BASE:
            # 32-битный регистр; для length != 4 возвращаем дополненное нулями
            val = self.regs.get(addr, 0) & 0xFFFFFFFF
            return struct.pack("<I", val)[:length] if length < 4 else struct.pack("<I", val)
        raise XdmaMemError(f"Некорректный AXI-адрес для чтения: 0x{addr:X}")

    def write(self, addr: int, data: bytes) -> None:
        if addr >= DDR3_BASE:
            off = addr - DDR3_BASE
            if off + len(data) > len(self.mem):
                raise XdmaMemError(f"DDR3 write out-of-range: addr=0x{addr:X} "
                                   f"(off=0x{off:X}), len={len(data)}, mem={len(self.mem)}")
            self.mem[off:off + len(data)] = data
            return
        if AXI_LITE_BASE <= addr < DDR3_BASE:
            # регистр: дополняем до 4 байт если нужно
            buf = data[:4].ljust(4, b"\x00")
            self.regs[addr] = struct.unpack("<I", buf)[0]
            return
        raise XdmaMemError(f"Некорректный AXI-адрес для записи: 0x{addr:X}")


class TdotCoreMock(TdotCore):
    """TdotCore, который ВЫЧИСЛЯЕТ dot на месте (имитация ядра на FPGA).

    Повторяет поведение AXI4-мастера tdot_axi4:
      - читает data_start_reg / weights_start_reg / result_addr_reg (теперь ПОЛНЫЕ
        AXI-адреса с DDR3_BASE+offset, после фикса set_addrs FIX-2);
      - через dev.read() (AXI-маршрутизация) читает векторы из mock-DDR3;
      - считает dot эталоном dot_ref_raw;
      - через dev.write() кладёт 8-байтный результат в mock-DDR3;
      - дублирует результат в RES0/RES1 регистры (как RTL: res0=[31:0],
        res1={16'h0, [47:32]}) — чтобы read_result_reg() давал корректные 48 бит;
      - выставляет STATUS.DONE=1.
    """

    def __init__(self, dev: MockMem, num_mac: int = 32, ddr_base: int = DDR_BASE):
        super().__init__(dev, num_mac, ddr_base)
        self.mem = dev.mem

    def dot(self, data_bits, weights_bits, data_addr=0x0, weights_addr=0x1000,
            result_addr=0x2000):
        # как настоящий мастер: пишем входные векторы, ставим адреса, GO
        n = len(data_bits)
        if n == 0 or n > self.num_mac:
            raise ValueError(f"ожидается 1..{self.num_mac} пар, получено {n}")
        self.write_tf48(data_addr, data_bits)
        self.write_tf48(weights_addr, weights_bits)
        self.set_addrs(data_addr, weights_addr, result_addr)
        self.set_n(n)
        self.start()

        # Читаем ПОЛНЫЕ AXI-адреса из регистров (как делает RTL M_AXI_ARADDR).
        da = (self.dev.regs.get(REG_BASE + 0x14, 0) |
              (self.dev.regs.get(REG_BASE + 0x18, 0) << 32))
        wa = (self.dev.regs.get(REG_BASE + 0x1C, 0) |
              (self.dev.regs.get(REG_BASE + 0x20, 0) << 32))
        ra = (self.dev.regs.get(REG_BASE + 0x24, 0) |
              (self.dev.regs.get(REG_BASE + 0x28, 0) << 32))

        # Проверяем, что RTL получил полные AXI-адреса (регресс-тест фикса FIX P5).
        assert da >= DDR3_BASE, (f"DATA_ADDR должен быть >= DDR3_BASE, "
                                 f"получено 0x{da:X} (FIX P5 регрессия!)")
        assert wa >= DDR3_BASE, (f"WEIGHTS_ADDR должен быть >= DDR3_BASE, "
                                 f"получено 0x{wa:X}")
        assert ra >= DDR3_BASE, (f"RESULT_ADDR должен быть >= DDR3_BASE, "
                                 f"получено 0x{ra:X}")

        # Имитация работы ядра: читаем векторы из mock-DDR3 через AXI-маршрутизацию.
        def read_vec(base_axi):
            out = []
            for i in range(n):
                v = struct.unpack("<Q", self.dev.read(base_axi + i * 8, 8))[0]
                out.append(v & 0xFFFFFFFFFFFF)
            return out

        d = read_vec(da)
        w = read_vec(wa)
        # dot в эталонной raw-модели (как RTL compute_dot_par_raw)
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "..", "rtl", "integration"))
        from verify_tdot_axi4 import dot_ref_raw
        res = dot_ref_raw(d, w) & 0xFFFFFFFFFFFF

        # Запись результата в mock-DDR3 через AXI-маршрутизацию (как M_AXI_AWADDR).
        self.dev.write(ra, struct.pack("<Q", res))

        # Дублируем в RES0/RES1 регистры (как делает RTL CS_WAIT):
        #   res0_reg <= core_result[31:0]
        #   res1_reg <= {16'h0, core_result[47:32]}
        self.dev.regs[REG_BASE + 0x0C] = res & 0xFFFFFFFF
        self.dev.regs[REG_BASE + 0x10] = (res >> 32) & 0xFFFF

        # Статус: DONE=1, BUSY=0
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
    res_via_reg = []   # проверка read_result_reg (48 бит)
    res_via_ddr = []   # проверка read_tf48 (48 бит из DDR3)
    for i in range(2):
        bits_a = be._batch_to_bits(a[i:i+1])[0]
        bits_b = be._batch_to_bits(b[i:i+1])[0]
        r = core.dot(bits_a, bits_b)
        res.append(be._bits_to_float(r))
        # Проверка 1: read_result_reg должен вернуть те же 48 бит (FIX P4)
        r_reg = core.read_result_reg()
        assert r_reg == r, (f"read_result_reg != dot: 0x{r_reg:X} != 0x{r:X} "
                            f"(FIX P4 регрессия!)")
        res_via_reg.append(be._bits_to_float(r_reg))
        # Проверка 2: read_tf48 из DDR3 должен вернуть те же 48 бит
        r_ddr = core.read_tf48(DDR_RESULT)
        assert r_ddr == r, (f"read_tf48 != dot: 0x{r_ddr:X} != 0x{r:X}")
        res_via_ddr.append(be._bits_to_float(r_ddr))
    res = np.array(res, dtype=np.float32)

    print("CPU (эмуляция)    :", ref)
    print("FPGA (mock)       :", res)
    print("FPGA via RES0/RES1:", np.array(res_via_reg, dtype=np.float32))
    print("FPGA via DDR3 read :", np.array(res_via_ddr, dtype=np.float32))
    diff = np.abs(ref - res).max()
    diff_reg = np.abs(np.array(res, dtype=np.float32) -
                      np.array(res_via_reg, dtype=np.float32)).max()
    diff_ddr = np.abs(np.array(res, dtype=np.float32) -
                      np.array(res_via_ddr, dtype=np.float32)).max()
    print(f"max diff (CPU vs mock)         : {diff}")
    print(f"max diff (mock vs RES0/RES1)   : {diff_reg}")
    print(f"max diff (mock vs DDR3 read)   : {diff_ddr}")
    # допуск: троичная точность ~1e-5
    assert diff < 1e-4, "рассинхрон CPU/FPGA пути"
    assert diff_reg == 0.0, "read_result_reg не совпал с dot (FIX P4 регрессия!)"
    assert diff_ddr == 0.0, "read_tf48 не совпал с dot"
    print("OK: FPGA-протокол (конверсия, раскладка, регистры, "
          "полные AXI-адреса, 48-битный результат) работает")


if __name__ == "__main__":
    main()
