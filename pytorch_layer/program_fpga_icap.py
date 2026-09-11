"""program_fpga_icap.py - прошивка FPGA по PCIe (БЕЗ JTAG) через ICAP.

Загружает битстрим (.bin/.bit) в FPGA через кастомный ICAP-контроллер
(0x4000_4000: CTRL/STATUS/DATA) - т.е. по PCIe, без кабеля JTAG.

Когда это работает
------------------
Устройство уже должно быть живо: FPGA должна выполнять битстрим, в котором
есть PCIe-эндпойнт и ICAP-контроллер (базовый/DFX-дизайн этого проекта).
"Пустую" FPGA (или образ без PCIe) по PCIe залить НЕЛЬЗЯ - нужен JTAG/флеш
(см. driver/R-01_BUILD_AND_FLASH.md), т.к. не будет даже PCIe-линка.

Важные свойства
---------------
* Прошивка через ICAP - временная (volatile): после power-cycle FPGA
  загрузится из SPI-флеша (образ во флеше не меняется).
* Полный образ (xdma_ddr3_core_top.bin): во время загрузки произойдёт
  переконфигурация всего кристалла, включая PCIe-блок -> линк упадёт на
  ~5-10 с (это ожидаемо; см. примечание ниже). Восстановление, если образ
  несовместим: полный power-cycle (загрузка из флеша).
* Частичный образ (RP, *partial*.bin): PCIe-линк НЕ падает - это штатный
  DFX-путь (см. dfx_swap.py).

Usage
-----
    python program_fpga_icap.py build\\artifacts_dfx\\xdma_ddr3_core_top.bin
    python program_fpga_icap.py partial.bin --partial
    python program_fpga_icap.py full.bin --full --yes
    python program_fpga_icap.py x.bin --dry-run         # разобрать и показать
    python program_fpga_icap.py x.bin --mock            # прогон без железа

Exit codes: 0 ok; 2 usage; 3 файл/формат; 4 precheck; 5 ошибка загрузки.
"""
from __future__ import annotations

import argparse
import struct
import sys
import time

from xdma_driver import XdmaLinux, XdmaWindows, XdmaWinDriver, XdmaDevice, XdmaError
from icap_load import (
    parse_bitstream, iter_words_le, IcapError,
    ICAP_BASE, REG_CTRL, REG_STATUS, REG_DATA,
    CTRL_GO, CTRL_STOP, STATUS_READY, STATUS_BUSY, ICAP_SYNC_LE,
    find_sync_offset, PREAMBLE_SCAN_LIMIT,
)

FULL_IMAGE_MIN_BYTES = 2 << 20     # >= 2 МБ считаем полным образом (XC7A200T ~4.5 МБ)
GO_TIMEOUT_S = 1.0
READY_TIMEOUT_S = 0.1
PROGRESS_EVERY = 4096


class _MockXdma(XdmaDevice):
    """In-memory ICAP model for --mock (no hardware). Держит CTRL/STATUS/DATA."""

    def __init__(self) -> None:
        self.mem: dict[int, int] = {}
        self.busy = 0
        self.word_count = 0
        self.cmd_hist: list[int] = []
        self._store(ICAP_BASE + REG_STATUS, STATUS_READY)

    def _store(self, addr: int, value: int) -> None:
        raw = struct.pack("<I", value & 0xFFFFFFFF)
        for i, b in enumerate(raw):
            self.mem[addr + i] = b

    def read(self, addr: int, length: int) -> bytes:
        return bytes(self.mem.get(addr + i, 0) for i in range(length))

    def write(self, addr: int, data: bytes) -> None:
        for i, b in enumerate(data):
            self.mem[addr + i] = b
        if addr == ICAP_BASE + REG_CTRL:
            v = struct.unpack("<I", data[:4])[0]
            if v & CTRL_GO:
                self.busy = 1
            if v & CTRL_STOP:
                self.busy = 0
            self._store(ICAP_BASE + REG_STATUS, STATUS_READY | (STATUS_BUSY if self.busy else 0))
        elif addr == ICAP_BASE + REG_DATA:
            self.word_count += 1


def _open_device(device: str, mock: bool) -> XdmaDevice:
    if mock:
        return _MockXdma()
    try:
        return XdmaLinux(f"/dev/{device}")
    except (XdmaError, NameError, OSError):
        pass
    try:
        # Windows: штатный драйвер проекта (\\.\XDMA0) — без xdma_rw.exe
        return XdmaWinDriver()
    except (XdmaError, OSError):
        pass
    return XdmaWindows()


def _reg_r(dev: XdmaDevice, off: int) -> int:
    return struct.unpack("<I", dev.read(ICAP_BASE + off, 4))[0]


def _reg_w(dev: XdmaDevice, off: int, val: int) -> None:
    dev.write(ICAP_BASE + off, struct.pack("<I", val & 0xFFFFFFFF))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Прошивка FPGA по PCIe через ICAP (без JTAG).")
    ap.add_argument("bitstream", help="путь к .bin/.bit")
    ap.add_argument("--device", default="xdma0", help="имя XDMA-устройства (Linux)")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--partial", action="store_true", help="это частичный образ (RP)")
    mode.add_argument("--full", action="store_true", help="это полный образ")
    ap.add_argument("--yes", action="store_true",
                    help="подтвердить полную перезагрузку (линк PCIe упадёт)")
    ap.add_argument("--no-progress", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="только разобрать файл")
    ap.add_argument("--mock", action="store_true", help="прогон без железа (in-memory ICAP)")
    ap.add_argument("--timeout-ms", type=float, default=READY_TIMEOUT_S * 1000.0,
                    help="таймаут READY на слово, мс")
    ap.add_argument("--strict-sync", action="store_true",
                    help="требовать sync-слово в позиции 0 (не пропускать преамбулу)")
    args = ap.parse_args(argv)

    # ---- 1. файл ---------------------------------------------------------
    try:
        body = parse_bitstream(args.bitstream)
    except (IcapError, OSError) as e:
        print(f"ОШИБКА файла: {e}", file=sys.stderr)
        return 3
    off = 0 if args.strict_sync else find_sync_offset(body)
    if off < 0:
        print(f"ОШИБКА: sync word (BE 0xAA995566) не найден в первых "
              f"{PREAMBLE_SCAN_LIMIT} байтах файла. Это не тело битстрима?",
              file=sys.stderr)
        return 3
    words = iter_words_le(body[off:])
    if not words or words[0] != ICAP_SYNC_LE:
        got = f"0x{words[0]:08X}" if words else "нет данных"
        print(f"ОШИБКА: неверный sync word {got} "
              f"(ожидался 0x{ICAP_SYNC_LE:08X} = BE 0xAA995566)", file=sys.stderr)
        return 3
    if off:
        print(f"Преамбула: пропущено {off} байт (bus-width detect)  поток "
              f"начинается с sync-слова")

    nbytes = len(words) * 4
    is_full = args.full or (not args.partial and nbytes >= FULL_IMAGE_MIN_BYTES)
    kind = "ПОЛНЫЙ" if is_full else "частичный (RP)"
    print(f"Файл:      {args.bitstream}")
    print(f"Размер:    {nbytes} байт ({len(words)} слов) -> {kind} образ")
    print(f"Sync word: 0x{words[0]:08X} OK (BE 0xAA995566)")

    if args.dry_run:
        print("Первые 8 слов (LE в DATA / BE в файле):")
        for w in words[:8]:
            print(f"  DATA=0x{w:08X}  (BE 0x{struct.unpack('>I', struct.pack('<I', w))[0]:08X})")
        print("dry-run: устройство не тронуто.")
        return 0

    if is_full and not (args.yes or args.mock):
        print("\nВНИМАНИЕ: полный образ переконфигурирует весь кристалл, включая PCIe.")
        print("Линк упадёт на ~5-10 с; если образ несовместим - поможет power-cycle")
        print("(FPGA грузится из SPI-флеша, флеш не меняется).")
        print("Повторите с --yes для подтверждения (или --mock для теста).")
        return 2

    # ---- 2. precheck -----------------------------------------------------
    dev = _open_device(args.device, args.mock)
    try:
        st = _reg_r(dev, REG_STATUS)
    except (XdmaError, OSError) as e:
        print(f"ОШИБКА: ICAP недоступен ({e}). Драйвер установлен? FPGA жива? "
              f"Для Linux нужен /dev/{args.device}_user.", file=sys.stderr)
        return 4
    busy, ready = bool(st & STATUS_BUSY), bool(st & STATUS_READY)
    print(f"ICAP precheck: STATUS=0x{st:08X} (BUSY={int(busy)} READY={int(ready)})")
    if busy or not ready:
        print("ОШИБКА: контроллер занят/не готов (BUSY=1 или READY=0). "
              "Дождитесь окончания другой сессии или перезагрузите плату.", file=sys.stderr)
        return 4

    # ---- 3. загрузка -----------------------------------------------------
    print("GO...")
    _reg_w(dev, REG_CTRL, CTRL_GO)
    t0 = time.monotonic()
    while time.monotonic() - t0 < GO_TIMEOUT_S:
        if _reg_r(dev, REG_STATUS) & STATUS_BUSY:
            break
    else:
        print("ОШИБКА: ICAP не перешёл в BUSY после GO", file=sys.stderr)
        return 5

    ready_to = args.timeout_ms / 1000.0
    t0 = time.monotonic()
    for i, w in enumerate(words):
        tw = time.monotonic()
        while time.monotonic() - tw < ready_to:
            if _reg_r(dev, REG_STATUS) & STATUS_READY:
                break
        else:
            print(f"\nОШИБКА: таймаут READY на слове {i}", file=sys.stderr)
            return 5
        _reg_w(dev, REG_DATA, w)
        if not args.no_progress and (i % PROGRESS_EVERY == 0 or i == len(words) - 1):
            pct = (i + 1) * 100.0 / len(words)
            rate = (i + 1) / max(time.monotonic() - t0, 1e-9)
            print(f"\r  {pct:5.1f}%  {i + 1}/{len(words)} слов  ({rate:,.0f} слов/с)",
                  end="", flush=True)
    if not args.no_progress:
        print()
    dt = time.monotonic() - t0

    # ---- 4. STOP (при полном образе линк может уже исчезнуть) -------------
    try:
        _reg_w(dev, REG_CTRL, CTRL_STOP)
        time.sleep(0.01)
    except (XdmaError, OSError) as e:
        print(f"NOTE: STOP не доставлен (ожидаемо при полном образе): {e}")

    print(f"\nГотово: {len(words)} слов ({nbytes} байт) за {dt:.2f} с "
          f"({len(words) / max(dt, 1e-9):,.0f} слов/с)")
    if args.mock:
        print(f"[mock] принято слов в ICAP: {dev.word_count}")
    if is_full:
        print("Полный образ: подождите ~5-10 с (PCIe переинициализируется), затем проверьте:")
    else:
        print("Частичный образ: PCIe остаётся активным. Проверьте:")
    print("   1) диспетчер устройств -> XDMA DDR3 Ternary Accelerator v1.1;")
    print("   2) driver\\build\\test_xdma.exe gpio   (строка BAR map) - Linux: python icap_load.py --dry-run")
    print("   3) python pytorch_layer\\xdma_driver.py --selftest")
    return 0


if __name__ == "__main__":
    sys.exit(main())
