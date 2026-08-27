"""Загрузка битстрима через ICAP-контроллер FPGA.

Читает .bin-файл, пишет 32-битные слова в регистр DATA ICAP (0x4600_0000).

Usage:
    python icap_load.py path/to/bitstream.bin [--device xdma0]
"""
from __future__ import annotations
import argparse
import struct
import sys
import time

from xdma_driver import XdmaLinux, XdmaWindows, XdmaError

ICAP_BASE = 0x4000_2000
REG_CTRL = 0x00
REG_STATUS = 0x04
REG_DATA = 0x08

ICAP_SYNC = 0xAA995566

POLL_US = 0.0001
GO_TIMEOUT_S = 1.0
READY_TIMEOUT_S = 0.1

try:
    from tqdm import tqdm
except ImportError:
    tqdm = None


class IcapError(RuntimeError):
    pass


class IcapLoader:
    def __init__(self, device: str = "xdma0"):
        try:
            self._dev = XdmaLinux(f"/dev/{device}")
        except XdmaError:
            self._dev = XdmaWindows()
        self._base = ICAP_BASE

    def _reg_w(self, off: int, val: int):
        self._dev.write(self._base + off,
                        struct.pack("<I", val & 0xFFFFFFFF))

    def _reg_r(self, off: int) -> int:
        data = self._dev.read(self._base + off, 4)
        return struct.unpack("<I", data)[0]

    def _wait_ready(self, timeout_s: float = READY_TIMEOUT_S) -> bool:
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout_s:
            s = self._reg_r(REG_STATUS)
            ready = s & 0x1
            if ready:
                return True
        return False

    def load(self, bit_path: str, show_progress: bool = True):
        with open(bit_path, "rb") as f:
            words = list(self._iter_words(f))

        if not words:
            raise IcapError(f"Файл {bit_path} пуст")

        if words[0] != ICAP_SYNC:
            raise IcapError(
                f"Неверный sync word в {bit_path}: "
                f"0x{words[0]:08X}, ожидался 0x{ICAP_SYNC:08X}")

        print(f"Битстрим: {bit_path}")
        print(f"Размер: {len(words)} слов ({len(words) * 4} байт)")
        print(f"Sync word: 0x{words[0]:08X} OK")
        print("Запуск ICAP...")

        self._reg_w(REG_CTRL, 0x1)
        t0 = time.monotonic()
        while time.monotonic() - t0 < GO_TIMEOUT_S:
            s = self._reg_r(REG_STATUS)
            if s & 0x2:
                break
        else:
            raise IcapError("ICAP не перешёл в BUSY после GO")

        seq = tqdm(words, desc="ICAP") if (show_progress and tqdm) else words
        for i, w in enumerate(seq):
            if not self._wait_ready(READY_TIMEOUT_S):
                raise IcapError(f"Таймаут READY на слове {i}")
            self._reg_w(REG_DATA, w)

        print("Битстрим отправлен. FPGA перезагружается, "
              "PCIe-линк упадёт на ~5-10 с.")

    @staticmethod
    def _iter_words(f, chunk: int = 65536):
        while True:
            buf = f.read(chunk)
            if not buf:
                break
            for i in range(0, len(buf) & ~3, 4):
                yield struct.unpack("<I", buf[i:i + 4])[0]


def main():
    parser = argparse.ArgumentParser(
        description="Загрузка битстрима в FPGA через ICAP.")
    parser.add_argument("bitstream", help="путь к .bin-файлу битстрима")
    parser.add_argument("--device", default="xdma0",
                        help="имя XDMA-устройства (по умолч. xdma0)")
    parser.add_argument("--no-progress", action="store_true",
                        help="отключить прогресс-бар")
    args = parser.parse_args()

    loader = IcapLoader(device=args.device)
    try:
        loader.load(args.bitstream, show_progress=not args.no_progress)
    except (IcapError, XdmaError) as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()