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

    def __init__(self, mode: str = "cpu", n=None, device=None, num_mac=None,
                 ring_depth: int = 256):
        self.mode = mode      # 'cpu' | 'fpga'
        self.device = device  # XdmaDevice или None (fpga -> авто)
        self.num_mac = num_mac
        self.ring_depth = ring_depth   # глубина кольца (256 по умолч.; 1024 после прошивки RING-1024)
        self._sched = None    # кэш TdotScheduler (батч через ring)
        if mode == "fpga":
            if self.num_mac is None:
                # Авто-детект NUM_MAC из прошивки (CORE_PARAMS) после получения
                # устройства. Если прошивка недоступна/не сообщает — ValueError.
                self.num_mac = self._detect_num_mac()
            else:
                self._ensure_device()   # ранняя проверка открытия устройства
        if self.num_mac is None:
            # не-fpga режим (эмуляция) или неизвестно — старый дефолт
            self.num_mac = 32 if mode == "cpu" else 16
        # n: если не задан — dot во всю ширину MAC (matmul всё равно чанкует по n)
        self.n = n if n is not None else self.num_mac

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

    def _to_bits_list(self, vals) -> list:
        """float32 vector -> список 48-битных TFloat48 (для run_dot_bits)."""
        return [self._to_bits48(TFloat.from_float(v)) for v in vals]

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

    # --- FPGA-вызов через XDMA (аппаратный планировщик, batch>1) ---
    def _ensure_device(self):
        """Вернуть устройство, создав его при необходимости (идемпотентно)."""
        if self.device is not None:
            return self.device
        from xdma_driver import XdmaLinux, XdmaError
        try:
            self.device = XdmaLinux()
        except XdmaError:
            # Windows: прямой DMA делает XdmaWinDma (test_dma_win), а НЕ
            # XdmaWindows/xdma_rw.exe (того бинаря в проекте нет).
            from test_dma_win import XdmaWinDma
            self.device = XdmaWinDma(base=r"\\.\XDMA0dma")
        return self.device

    def _detect_num_mac(self) -> int:
        """Прочитать NUM_MAC прошивки (CORE_PARAMS) через probe_firmware().

        Устройство должно поддерживать probe_firmware() (XdmaWinDma); иначе —
        ValueError с понятным текстом (нельзя тихо падать на хардкод 16).
        """
        dev = self._ensure_device()
        probe = getattr(dev, "probe_firmware", None)
        if probe is None:
            raise ValueError(
                f"Автодетект NUM_MAC недоступен: устройство {type(dev).__name__} "
                f"не поддерживает probe_firmware(). Укажите num_mac явно.")
        info = probe()
        nm = info.get("NUM_MAC") if isinstance(info, dict) else None
        if not nm:
            raise ValueError(
                "Не удалось определить NUM_MAC прошивки (CORE_PARAMS недоступен). "
                "Укажите num_mac явно.")
        return int(nm)

    def _run_fpga(self, a, b, batch, a_bits=None, b_bits=None):
        # Каждая строка батча = одна задача планировщика (ring). Длина n до
        # 16*NUM_MAC покрывается long-dot в RTL сама. a_bits/b_bits — уже
        # сконвертированные (для run_dot_bits), иначе конвертируем здесь.
        if self.n > 16 * self.num_mac:
            raise ValueError(f"n={self.n} > MAX_N_TOTAL={16 * self.num_mac}")
        from xdma_driver import TdotScheduler
        dev = self._ensure_device()
        if self._sched is None or getattr(self._sched, "dev", None) is not dev:
            from xdma_driver import SCHED_RING_DEPTH
            rd = self.ring_depth if self.ring_depth else SCHED_RING_DEPTH
            self._sched = TdotScheduler(dev, num_mac=self.num_mac, ring_depth=rd)
        if a_bits is None:
            a_bits = self._batch_to_bits(a)
        if b_bits is None:
            b_bits = self._batch_to_bits(b)
        pairs = [(a_bits[i], b_bits[i]) for i in range(batch)]
        # разбиение на sub-батчи по ~250 задач и минимизацию числа submit'ов
        # делает сам TdotScheduler.dot_batch
        res_bits = self._sched.dot_batch(pairs)
        return np.array([self._bits_to_float(rb) for rb in res_bits], dtype=np.float32)

    def run_dot_bits(self, a_bits, b_bits):
        """Как run_dot, но вход — уже 48-битные TFloat48 (списки списков).
        Экономит повторную конвертацию (напр. одни и те же X на много нейронов)."""
        if len(a_bits) != len(b_bits):
            raise ValueError(f"размеры не совпадают: {len(a_bits)}/{len(b_bits)}")
        if self.mode != "fpga":
            raise NotImplementedError("run_dot_bits только для mode='fpga'")
        return self._run_fpga(None, None, len(a_bits), a_bits=a_bits, b_bits=b_bits)

    def throughput_gflops(self, freq_hz: float = 125e6) -> float:
        """Теоретическая производительность (для сравнения)."""
        return self.n * 2 * freq_hz / 1e9
