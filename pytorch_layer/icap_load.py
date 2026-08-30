"""Загрузка битстрима через ICAP-контроллер FPGA.

Читает .bin/.bit-файл, пишет 32-битные слова в регистр DATA ICAP
(AXI-Lite, BAR0-relative 0x4000_2000; CTRL 0x00, STATUS 0x04, DATA 0x08).

ПОРЯДОК БАЙТОВ (важно!):
Битстрим хранит слова в big-endian (файл: байты AA 99 55 66 = слово 0xAA995566).
ICAPE2 X32 потребляет байты слова от I[7:0] вверх, поэтому хост отправляет
little-endian представление слов файла (LE-чтение без преобразований):
  sync 0xAA995566 (BE) -> в DATA пишется 0x665599AA (тогда I[7:0]=0xAA первым).
Это тот же контракт, что у ядра Linux xilinx_hwicap ("cp foo.bit /dev/icap0"
работает без преобразований: memcpy файла в u32 на little-endian машине даёт
ровно это представление; см. drivers/char/xilinx_hwicap/xilinx_hwicap.c).
RTL (icap_ctrl.sv) передаёт слова на ICAPE2.I без изменений.

Протокол: CTRL.GO=1 -> BUSY; затем для каждого слова: ждать STATUS.READY=1,
записать DATA; в конце CTRL.STOP=1 (после DESYNC-слов файла).

Usage:
    python icap_load.py path/to/bitstream.bin [--device xdma0] [--dry-run]
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

CTRL_GO = 0x1
CTRL_STOP = 0x2
STATUS_READY = 0x1
STATUS_BUSY = 0x2

# Sync word: в LE-представлении, как он уходит в DATA (BE 0xAA995566)
ICAP_SYNC_LE = 0x6655_99AA

POLL_US = 0.0001
GO_TIMEOUT_S = 1.0
READY_TIMEOUT_S = 0.1

try:
    from tqdm import tqdm
except ImportError:
    tqdm = None


class IcapError(RuntimeError):
    pass


def parse_bitstream(path: str) -> bytes:
    """Возвращает тело битстрима (без заголовка .bit, либо .bin как есть).

    .bit-файл: поля 0x00'9'0F, 'a'(дизайн), 'b'(чип), 'c'(дата), 'd'(время),
    'e'<4 байта длины BE> <данные>. Возвращаем только данные.
    .bin-файл: сырые данные write_bitstream -bin_file (тело битстрима).
    """
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] == b"\x00\x09" and len(data) > 4 and data[2] == 0x0F:
        # .bit: идём по полям заголовка до секции 'e'
        pos = 4
        while pos < len(data):
            key = data[pos]
            pos += 1
            if key == 0x65:  # 'e' — секция данных
                ln = struct.unpack(">I", data[pos:pos + 4])[0]
                pos += 4
                return data[pos:pos + ln]
            ln2 = struct.unpack(">H", data[pos:pos + 2])[0]
            pos += 2 + ln2
        raise IcapError(f"Не найдена секция данных в {path}")
    return data


def iter_words_le(body: bytes):
    """LE-чтение тела битстрима: слова, готовые к записи в DATA без изменений."""
    n = len(body) & ~3
    return [struct.unpack_from("<I", body, i)[0] for i in range(0, n, 4)]


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
            if self._reg_r(REG_STATUS) & STATUS_READY:
                return True
        return False

    def load(self, bit_path: str, show_progress: bool = True):
        body = parse_bitstream(bit_path)
        words = iter_words_le(body)

        if not words:
            raise IcapError(f"Файл {bit_path} пуст")

        # sync word приходит первым (LE-вид 0x665599AA == BE 0xAA995566).
        # Для .bin он обязан быть в нулевом смещении; для .bit — сразу после
        # заголовка (parse_bitstream уже отрезал заголовок).
        if words[0] != ICAP_SYNC_LE:
            raise IcapError(
                f"Неверный sync word в {bit_path}: 0x{words[0]:08X}, "
                f"ожидался 0x{ICAP_SYNC_LE:08X} (BE 0xAA995566). "
                f"Файл повреждён или это не тело битстрима.")

        print(f"Битстрим: {bit_path}")
        print(f"Размер: {len(words)} слов ({len(words) * 4} байт)")
        print(f"Sync word: 0x{words[0]:08X} OK (BE 0xAA995566)")
        print("Запуск ICAP...")

        self._reg_w(REG_CTRL, CTRL_GO)
        t0 = time.monotonic()
        while time.monotonic() - t0 < GO_TIMEOUT_S:
            if self._reg_r(REG_STATUS) & STATUS_BUSY:
                break
        else:
            raise IcapError("ICAP не перешёл в BUSY после GO")

        seq = tqdm(words, desc="ICAP") if (show_progress and tqdm) else words
        for i, w in enumerate(seq):
            if not self._wait_ready(READY_TIMEOUT_S):
                raise IcapError(f"Таймаут READY на слове {i}")
            self._reg_w(REG_DATA, w)

        # Отправка STOP — закрыть сессию ICAP (см. icap_ctrl.sv:11-17).
        # Протокол: после последнего DATA хост пишет CTRL.STOP=1 → BUSY=0,
        # CSIB принудительно поднимается. Даже при full-bitstream перезагрузке
        # STOP успевает дойти до падения PCIe-линка (CDC toggle-handshake
        # занимает ~5-10 тактов S_AXI_ACLK = 40-80 нс, что много раньше
        # 5-10 секундного окна PCIe reset).
        # Оборачиваем в try/except: при partial reconfig PCIe не падает, и STOP
        # обязателен; при full reload возможна OSError/XdmaError на уже
        # исчезнувшем устройстве — это нормально, игнорируем.
        try:
            self._reg_w(REG_CTRL, CTRL_STOP)
            time.sleep(0.01)   # короткая пауза для CDC (toggle-handshake)
        except (XdmaError, OSError) as e:
            # ожидаемо при full-bitstream reload (PCIe-линк упал)
            print(f"NOTE: STOP не доставлен (ожидаемо при full reload): {e}")

        print("Битстрим отправлен. FPGA перезагружается, "
              "PCIe-линк упадёт на ~5-10 с (full reload) или останется "
              "активным (partial reconfig).")


def main():
    parser = argparse.ArgumentParser(
        description="Загрузка битстрима в FPGA через ICAP.")
    parser.add_argument("bitstream", help="путь к .bin/.bit файлу битстрима")
    parser.add_argument("--device", default="xdma0",
                        help="имя XDMA-устройства (по умолч. xdma0)")
    parser.add_argument("--no-progress", action="store_true",
                        help="отключить прогресс-бар")
    parser.add_argument("--dry-run", action="store_true",
                        help="только распарсить файл и показать первые слова")
    args = parser.parse_args()

    try:
        body = parse_bitstream(args.bitstream)
        words = iter_words_le(body)
        if not words:
            raise IcapError(f"Файл {args.bitstream} пуст")
        print(f"Файл: {args.bitstream}, слов: {len(words)}")
        print("Первые 8 слов в DATA (LE-вид; BE в скобках):")
        for w in words[:8]:
            be = struct.pack("<I", w)
            be_val = struct.unpack(">I", be)[0]
            print(f"  DATA=0x{w:08X}  (BE 0x{be_val:08X})")
        if args.dry_run:
            return
        loader = IcapLoader(device=args.device)
        loader.load(args.bitstream, show_progress=not args.no_progress)
    except (IcapError, XdmaError, OSError) as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
