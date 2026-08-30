"""FPGA-бэкенд для кастомных слоёв PyTorch.

Стратегия: часть математики слоя выполняется НА FPGA (троичный ускоритель
TFloat48), остальное — на CPU/GPU. Два режима:
  - CPU_MODE: эмуляция на Python (блочная троичная FP через block.tfloat48) —
    для проверки логики без железа.
  - FPGA_MODE: вызов на FPGA через XDMA (TdotCore) — полный AXI4-мастер
    tdot_axi4 читает data/weights из DDR3, вычисляет dot, пишет результат.

Интерфейс единый: run_dot(a, b) -> result (numpy float32), где a/b - 2D
массивы [batch, N], результат - dot по последней оси.
"""
from __future__ import annotations
import os, sys, struct
import numpy as np

# путь к троичному эмулятору
_TERN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw")
if _TERN not in sys.path:
    sys.path.insert(0, _TERN)

from block.tfloat48 import TFloat
from block import arith48

# карта адресов для FPGA (согласовано с xdma_driver.py)
DDR_DATA   = 0x0       # данные в DDR3 (офсет от 0x8000_0000)
DDR_WEIGHTS = 0x1000   # веса
DDR_RESULT  = 0x2000   # результат


class FpgaBackend:
    """Единый интерфейс: CPU-эмуляция или FPGA через XDMA."""

    def __init__(self, mode: str = "cpu", n: int = 32,
                 device=None, num_mac: int = 32):
        self.mode = mode      # 'cpu' | 'fpga'
        self.n = n            # размерность dot
        self.device = device  # XdmaDevice или None (fpga -> авто)
        self.num_mac = num_mac

    def run_dot(self, a: np.ndarray, b: np.ndarray) -> np.ndarray:
        """dot по последней оси: a[batch,N] @ b[batch,N] -> [batch]."""
        a = np.ascontiguousarray(a, dtype=np.float32)
        b = np.ascontiguousarray(b, dtype=np.float32)
        if a.shape[-1] != b.shape[-1] or a.shape[-1] != self.n:
            raise ValueError(f"ожидается размер {self.n}, получен {a.shape[-1]}/{b.shape[-1]}")
        batch = a.shape[0]
        if self.mode == "fpga":
            return self._run_fpga(a, b, batch)
        return self._run_cpu(a, b, batch)

    # --- конверсия float32 -> TFloat48 bits (совпадает с RTL) ---
    @staticmethod
    def _to_bits48(t) -> int:
        return ((t.e_int & 0xFF) << 40) | (t.m_int & ((1 << 40) - 1))

    def _batch_to_bits(self, x: np.ndarray) -> list:
        """[batch, N] float32 -> список списков 48-битных TFloat48."""
        return [[self._to_bits48(TFloat.from_float(v)) for v in row] for row in x]

    @staticmethod
    def _bits_to_float(bits: int) -> float:
        # результат из RTL/DDR3 хранится в конвенции [E:8][M:40]
        return TFloat.from_bits(((bits & ((1 << 40) - 1)) << 8) | ((bits >> 40) & 0xFF)).to_float()

    # --- CPU-эмуляция (эталон, блочная модель как в RTL) ---
    def _run_cpu(self, a, b, batch):
        out = np.zeros(batch, dtype=np.float32)
        for i in range(batch):
            # попарное дерево как в RTL compute_dot_par_raw
            products = [arith48.mul(TFloat.from_float(x), TFloat.from_float(y))
                        for x, y in zip(a[i], b[i])]
            while len(products) > 1:
                nxt = []
                for k in range(0, len(products) - 1, 2):
                    nxt.append(arith48.add(products[k], products[k + 1]))
                if len(products) % 2 == 1:
                    nxt.append(products[-1])
                products = nxt
            out[i] = products[0].to_float()
        return out

    # --- FPGA-вызов через XDMA ---
    def _run_fpga(self, a, b, batch):
        if batch > 1:
            raise NotImplementedError(
                "FPGA-бэкенд пока обрабатывает batch=1 за вызов; "
                "подавайте по одному вектору.")
        if self.n > self.num_mac:
            raise ValueError(f"n={self.n} > NUM_MAC={self.num_mac}")

        from xdma_driver import XdmaLinux, XdmaWindows, TdotCore, XdmaError

        if self.device is None:
            try:
                self.device = XdmaLinux()
            except XdmaError:
                self.device = XdmaWindows()
        core = TdotCore(self.device, num_mac=self.num_mac)

        data_bits = self._batch_to_bits(a)[0]
        weights_bits = self._batch_to_bits(b)[0]
        res = core.dot(data_bits, weights_bits,
                       data_addr=DDR_DATA, weights_addr=DDR_WEIGHTS,
                       result_addr=DDR_RESULT)
        return np.array([self._bits_to_float(res)], dtype=np.float32)

    def throughput_gflops(self, freq_hz: float = 125e6) -> float:
        """Теоретическая производительность (для сравнения)."""
        return self.n * 2 * freq_hz / 1e9
