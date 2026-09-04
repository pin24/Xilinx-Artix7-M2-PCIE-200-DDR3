"""Горячая замена Reconfigurable Partition (RP) через PCIe — без JTAG.

Полная последовательность Dynamic Function eXchange (UG909) для DFX-сборки
(xdma_ddr3_dfx.bd, DFX Socket = dfx_socket):

  1. (опционально) убедиться, что RP не обслуживает транзакции.
  2. DFX Socket GPIO (0x4000_2000, канал 1): shutdown ОБОИХ AXI-мостов RP
     + decouple сброса RP (rp_resetn уходит в безопасное состояние).
  3. Дождаться статуса (канал 2): in_shutdown мастера и слейва + decoupled.
  4. Загрузить частичный битстрим RP через icap_ctrl (0x4000_4000)
     — переиспользует IcapLoader из icap_load.py.
  5. Очистить shutdown/decouple — dfx_axi_shutdown_manager возобновляет шину,
     dfx_decoupler выводит rp_resetn из сброса. PCIe-линк жив всё время
     (статическая область не трогается).

Распиновка DFX Socket (из xdma_ddr3_dfx_bd.tcl, hier dfx_socket):
  канал 1 (GPIO_DATA  @0x00, выходы, 3 бита):
    bit0 -> dfx_decoupler (resetn_dfx_decoupler).decouple
    bit1 -> dfx_axi_shutdown_static_master.request_shutdown (RP M_AXI)
    bit2 -> dfx_axi_shutdown_static_slave .request_shutdown (RP S_AXI)
  канал 2 (GPIO2_DATA @0x08, входы, 5 бит = xlconcat_status):
    bit0 = master shutdown_requested
    bit1 = master in_shutdown
    bit2 = slave  shutdown_requested
    bit3 = slave  in_shutdown
    bit4 = decoupler decouple_status

Частичные битстримы производит сборка (build_dfx.tcl / gen_bitstream.tcl —
экспорт `*partial*.bit|.bin` в build/artifacts_dfx/). Формат — обычный .bit
или .bin: icap_load.parse_bitstream сам срезает заголовок .bit.

Usage:
    python dfx_swap.py build/artifacts_dfx/*_partial.bit
    python dfx_swap.py --status
    python dfx_swap.py partial.bit --no-verify --timeout 10
"""
from __future__ import annotations
import argparse
import glob
import struct
import sys
import time

from xdma_driver import XdmaDevice, XdmaError
from icap_load import IcapLoader, IcapError, parse_bitstream, iter_words_le

# ---------------------------------------------------------------------------
# Адреса и биты (источник истины: docs/ADDRESS_MAP.md, DFX-карта)
# ---------------------------------------------------------------------------
DFX_SOCK_BASE = 0x4000_2000   # dfx_socket/decouple_shutdown_ctrl (axi_gpio)

# AXI GPIO v2.0 регистры (относительно базы)
REG_GPIO1_DATA = 0x00         # канал 1: выходы shutdown/decouple
REG_GPIO1_TRI  = 0x04
REG_GPIO2_DATA = 0x08         # канал 2: статус (входы)

# Канал 1 — управление
BIT_DECOUPLE = 1 << 0         # dfx_decoupler: удерживать rp_resetn в сбросе
BIT_SHUT_M   = 1 << 1         # shutdown моста RP M_AXI (RP -> статика/DDR3)
BIT_SHUT_S   = 1 << 2         # shutdown моста RP S_AXI (статика -> RP)
CTRL_ALL     = BIT_DECOUPLE | BIT_SHUT_M | BIT_SHUT_S

# Канал 2 — статус (xlconcat_status: In0..In4)
ST_REQ_M      = 1 << 0        # master shutdown_requested
ST_IN_SHUT_M  = 1 << 1        # master in_shutdown (шина RP M_AXI заглушена)
ST_REQ_S      = 1 << 2        # slave shutdown_requested
ST_IN_SHUT_S  = 1 << 3        # slave in_shutdown (шина RP S_AXI заглушена)
ST_DECOUPLED  = 1 << 4        # decoupler: RP в безопасном состоянии

# Маска "RP полностью отцеплена и заглушена"
ST_QUIESCED = ST_IN_SHUT_M | ST_IN_SHUT_S | ST_DECOUPLED

DEFAULT_TIMEOUT_S = 5.0
POLL_S = 0.005


class DfxSwapError(RuntimeError):
    pass


class DfxSocket:
    """Управление DFX Socket (shutdown/decouple) через AXI GPIO 0x4000_2000."""

    def __init__(self, dev: XdmaDevice):
        self.dev = dev

    def _w(self, off: int, val: int) -> None:
        self.dev.write(DFX_SOCK_BASE + off, struct.pack("<I", val & 0xFFFFFFFF))

    def _r(self, off: int) -> int:
        return struct.unpack("<I", self.dev.read(DFX_SOCK_BASE + off, 4))[0]

    def status(self) -> int:
        return self._r(REG_GPIO2_DATA)

    def control(self) -> int:
        return self._r(REG_GPIO1_DATA)

    def quiesce(self, timeout_s: float = DEFAULT_TIMEOUT_S) -> None:
        """Заглушить RP: shutdown обоих мостов + decouple; ждать подтверждения."""
        # TRI уже настроен Vivado на выходы (C_ALL_INPUTS_2/C_ALL_OUTPUTS),
        # но на всякий случай гарантируем направление канала 1.
        try:
            self._w(REG_GPIO1_TRI, 0x0)
        except XdmaError:
            pass
        self._w(REG_GPIO1_DATA, CTRL_ALL)
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout_s:
            st = self.status()
            if (st & ST_QUIESCED) == ST_QUIESCED:
                return
            time.sleep(POLL_S)
        raise DfxSwapError(
            f"RP не заглушился за {timeout_s}s: статус=0b{self.status():05b} "
            f"(ожидался 0b{ST_QUIESCED:05b}: in_shutdown M+S + decoupled)")

    def resume(self, timeout_s: float = DEFAULT_TIMEOUT_S) -> None:
        """Возобновить RP: снять shutdown/decouple; ждать сброса статуса."""
        self._w(REG_GPIO1_DATA, 0x0)
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout_s:
            st = self.status()
            # shutdown_requested/in_shutdown должны уйти; decouple_status снят
            if (st & (ST_REQ_M | ST_IN_SHUT_M | ST_REQ_S | ST_IN_SHUT_S | ST_DECOUPLED)) == 0:
                return
            time.sleep(POLL_S)
        raise DfxSwapError(
            f"RP не возобновился за {timeout_s}s: статус=0b{self.status():05b}")

    def verify_alive(self) -> None:
        """Проверить доступность периферии RP (DataMover MM2S @ 0x40010000).

        После успешного resume чтение регистра RP-слейва обязано завершиться
        без AXI-ошибки (SLVERR/DECERR ловим как исключение драйвера либо
        детектируем по флагу ответа).
        """
        self.dev.read(0x4001_0000, 4)


def format_status(st: int) -> str:
    parts = [
        "req_M" if st & ST_REQ_M else "-",
        "in_shut_M" if st & ST_IN_SHUT_M else "-",
        "req_S" if st & ST_REQ_S else "-",
        "in_shut_S" if st & ST_IN_SHUT_S else "-",
        "decoupled" if st & ST_DECOUPLED else "-",
    ]
    return " ".join(parts)


def swap(dev: XdmaDevice, partial_path: str, timeout_s: float = DEFAULT_TIMEOUT_S,
         verify: bool = True, show_progress: bool = True) -> None:
    """Горячая замена RP: quiesce -> partial bitstream -> resume -> verify."""
    # 0. Валидация файла ДО того, как заглушим RP (не оставляем систему
    #    в отцепленном состоянии из-за битого файла).
    body = parse_bitstream(partial_path)
    words = iter_words_le(body)
    if not words:
        raise DfxSwapError(f"Файл {partial_path} пуст")
    print(f"Частичный битстрим: {partial_path}")
    print(f"  размер: {len(words)} слов ({len(words) * 4} байт)")

    sock = DfxSocket(dev)
    st0 = sock.status()
    print(f"[1/4] DFX Socket: статус до замены: {format_status(st0)}")

    # 1. Заглушить RP
    sock.quiesce(timeout_s)
    print(f"[2/4] RP заглушен (shutdown M+S + decouple): "
          f"{format_status(sock.status())}")
    time.sleep(0.01)  # дать шинам опустеть после in_shutdown

    # 2. Частичный битстрим через icap_ctrl (PCIe, статика жива)
    try:
        loader = IcapLoader(dev=dev)
        loader.load(partial_path, show_progress=show_progress)
    except (IcapError, XdmaError) as e:
        # Не пытаемся resume вслепую: если ICAP-сессия зависла — STOP уже
        # отправлен внутри load() либо сессия не началась; RP в decouple,
        # повторная попытка безопасна.
        raise DfxSwapError(f"Ошибка загрузки частичного битстрима: {e}") from e

    # 3. Возобновить RP
    sock.resume(timeout_s)
    print(f"[3/4] RP возобновлён: {format_status(sock.status())}")

    # 4. Проверка доступности RP
    if verify:
        try:
            sock.verify_alive()
            print("[4/4] RP отвечает (чтение @0x40010000 OK) — горячая замена успешна")
        except (XdmaError, OSError) as e:
            raise DfxSwapError(
                f"RP не отвечает после возобновления: {e}. "
                f"Проверьте частичный битстрим (та ли это конфигурация RP).") from e
    else:
        print("[4/4] проверка RP пропущена (--no-verify)")


def main():
    parser = argparse.ArgumentParser(
        description="Горячая замена RP (DFX) через PCIe без JTAG.")
    parser.add_argument("bitstream", nargs="?", default=None,
                        help="частичный битстрим RP (.bit/.bin)")
    parser.add_argument("--device", default="xdma0",
                        help="имя XDMA-устройства (по умолч. xdma0)")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S,
                        help="таймаут ожидания shutdown/resume, с (по умолч. 5)")
    parser.add_argument("--no-verify", action="store_true",
                        help="не проверять доступность RP после замены")
    parser.add_argument("--no-progress", action="store_true",
                        help="отключить прогресс-бар ICAP")
    parser.add_argument("--status", action="store_true",
                        help="только показать статус DFX Socket и выйти")
    args = parser.parse_args()

    # Импорт устройства с fallback Linux -> Windows (как в icap_load.py)
    try:
        from xdma_driver import XdmaLinux
        dev = XdmaLinux(f"/dev/{args.device}")
    except (XdmaError, ImportError, OSError):
        from xdma_driver import XdmaWindows
        dev = XdmaWindows()

    sock = DfxSocket(dev)

    if args.status:
        print(f"DFX Socket 0x{DFX_SOCK_BASE:08X}: "
              f"CTRL=0x{sock.control():X}  STATUS: {format_status(sock.status())}")
        return
    if args.bitstream is None:
        parser.error("укажите частичный битстрим либо --status")

    # Поддержка glob-масок (удобно для build/artifacts_dfx/*_partial.bit)
    candidates = sorted(glob.glob(args.bitstream)) or [args.bitstream]
    path = candidates[0]

    try:
        swap(dev, path, timeout_s=args.timeout,
             verify=not args.no_verify, show_progress=not args.no_progress)
    except (DfxSwapError, IcapError, XdmaError, OSError) as e:
        print(f"ОШИБКА: {e}", file=sys.stderr)
        try:
            print(f"Текущее состояние DFX Socket: {format_status(sock.status())}",
                  file=sys.stderr)
        except XdmaError:
            pass
        sys.exit(1)


if __name__ == "__main__":
    main()
