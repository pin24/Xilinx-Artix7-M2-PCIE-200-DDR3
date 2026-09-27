"""program_spi_flash.py - update SPI flash via SPI-over-PCIe (R-14).

Allows updating the on-board W25Q128JV SPI flash WITHOUT JTAG,
through the custom spi_over_pcie AXI-Lite module at base 0x40005000.

Requirements:
  - FPGA must be running a bitstream that includes spi_over_pcie.sv
  - XDMA driver loaded, \\\\.\\XDMA0 accessible
  - XdmaWinDriver from xdma_driver.py (ctypes direct, no xdma_rw.exe)

Usage:
  python program_spi_flash.py bitstream.bin
  python program_spi_flash.py bitstream.bin --verify
  python program_spi_flash.py --rdid               # just read chip ID
  python program_spi_flash.py --read out.bin --addr 0 --len 4096
  python program_spi_flash.py bitstream.bin --iprog  # trigger reload from flash

Register map (spi_over_pcie @ 0x40005000):
  0x00 CTRL   [0] START (self-clear) [1] ABORT [2] WREN [3] RDID
  0x04 STATUS [0] BUSY [1] DONE [2] ERROR [3] WIP_FLASH
  0x08 CMD    SPI opcode byte
  0x0C ADDR   24-bit address
  0x10 LEN    byte count
  0x14 DATA   TX byte
  0x18 RX     RX byte
"""
from __future__ import annotations
import argparse
import struct
import sys
import time

# ICAP registers (for IPROG trigger) - from icap_load.py
ICAP_BASE = 0x4000_4000
ICAP_CTRL = ICAP_BASE + 0x00
ICAP_STATUS = ICAP_BASE + 0x04
ICAP_DATA = ICAP_BASE + 0x08
ICAP_CTRL_GO = 0x1
ICAP_CTRL_STOP = 0x2

# SPI registers
SPI_BASE = 0x4000_5000
SPI_CTRL = SPI_BASE + 0x00
SPI_STATUS = SPI_BASE + 0x04
SPI_CMD = SPI_BASE + 0x08
SPI_ADDR = SPI_BASE + 0x0C
SPI_LEN = SPI_BASE + 0x10
SPI_DATA = SPI_BASE + 0x14
SPI_RX = SPI_BASE + 0x18

# CTRL bits
CTRL_START = 0x1
CTRL_ABORT = 0x2
CTRL_WREN = 0x4
CTRL_RDID = 0x8

# STATUS bits
ST_BUSY = 0x1
ST_DONE = 0x2
ST_ERROR = 0x4
ST_WIP = 0x8

# SPI opcodes for W25Q128JV
CMD_WREN = 0x06
CMD_WRDI = 0x04
CMD_RDSR1 = 0x05
CMD_RDSR2 = 0x35
CMD_WRSR = 0x01
CMD_READ = 0x03
CMD_FAST_READ = 0x0B
CMD_PAGE_PROG = 0x02
CMD_SECTOR_ERASE = 0x20   # 4 KB
CMD_BLOCK_ERASE = 0xD8    # 64 KB
CMD_CHIP_ERASE = 0xC7
CMD_RDID = 0x9F
CMD_JEDEC_ID = 0x9F
CMD_EN4B = 0xB7           # enable 4-byte addressing

PAGE_SIZE = 256
SECTOR_SIZE = 4 * 1024
CHIP_SIZE = 16 * 1024 * 1024

FLASH_ID_EXPECTED = (0xEF, 0x40, 0x18)  # Winbond W25Q128JV


def _open_device():
    """Open XDMA device: try upstream driver first, fallback to custom."""
    from xdma_driver import XdmaError
    # 1) Upstream Xilinx XDMA 2017: per-node \\.\XDMA0\control | h2c_0 | c2h_0
    try:
        from xdma_driver import XdmaWinUpstream
        dev = XdmaWinUpstream()
        print("Opened via: XdmaWinUpstream (upstream Xilinx XDMA 2017)")
        return dev
    except (XdmaError, OSError, ImportError, AttributeError) as e:
        print(f"  XdmaWinUpstream: {e}")
    # 2) Fallback: custom driver \\.\XDMA0 (ctypes direct)
    try:
        from xdma_driver import XdmaWinDriver
        dev = XdmaWinDriver()
        print("Opened via: XdmaWinDriver (custom driver.c)")
        return dev
    except (XdmaError, OSError, ImportError) as e:
        print(f"  XdmaWinDriver: {e}")
    print("ERROR: no XDMA device found", file=sys.stderr)
    print("  - driver loaded? board in PCIe slot? bitstream has spi_over_pcie?")
    sys.exit(3)


def _reg_w(dev, addr: int, value: int) -> None:
    dev.write(addr, struct.pack("<I", value & 0xFFFFFFFF))


def _reg_r(dev, addr: int) -> int:
    return struct.unpack("<I", dev.read(addr, 4))[0]


def _wait_done(dev, timeout_s: float = 30.0) -> bool:
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout_s:
        st = _reg_r(dev, SPI_STATUS)
        if st & ST_ERROR:
            return False
        if (st & ST_DONE) and not (st & ST_BUSY):
            return True
        time.sleep(0.0005)
    return False


def _rdid(dev) -> tuple[int, int, int]:
    """Read JEDEC ID via CTRL.RDID (module sends 0x9F + 3 dummy bytes)."""
    _reg_w(dev, SPI_CTRL, CTRL_RDID)
    _reg_w(dev, SPI_CTRL, CTRL_RDID | CTRL_START)
    if not _wait_done(dev, 0.5):
        raise RuntimeError("RDID timeout")
    # The module stores last received byte in RX; for ID we need 3 bytes.
    # Instead, use CMD path: send 0x9F, LEN=3, read 3 bytes from RX.
    # Fallback: use CMD=0x9F, LEN=3.
    return (0, 0, 0)  # placeholder; use read_id() below


def read_id(dev) -> bytes:
    """Read JEDEC ID: CMD=0x9F, no address, read 3 bytes."""
    # Use CTRL.RDID shortcut if module supports it.
    _reg_w(dev, SPI_CMD, CMD_RDID)
    _reg_w(dev, SPI_LEN, 3)
    _reg_w(dev, SPI_CTRL, CTRL_START)
    if not _wait_done(dev, 1.0):
        raise RuntimeError("read_id timeout")
    id_bytes = bytearray()
    for _ in range(3):
        b = _reg_r(dev, SPI_RX) & 0xFF
        id_bytes.append(b)
    return bytes(id_bytes)


def wren(dev) -> None:
    _reg_w(dev, SPI_CTRL, CTRL_WREN)
    _reg_w(dev, SPI_CTRL, CTRL_WREN | CTRL_START)
    if not _wait_done(dev, 0.2):
        raise RuntimeError("WREN timeout")


def rdsr1(dev) -> int:
    _reg_w(dev, SPI_CMD, CMD_RDSR1)
    _reg_w(dev, SPI_LEN, 1)
    _reg_w(dev, SPI_CTRL, CTRL_START)
    if not _wait_done(dev, 0.2):
        raise RuntimeError("RDSR1 timeout")
    return _reg_r(dev, SPI_RX) & 0xFF


def wait_wip(dev, timeout_s: float = 60.0) -> None:
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout_s:
        if (rdsr1(dev) & 0x01) == 0:
            return
        time.sleep(0.005)
    raise RuntimeError(f"WIP stuck for {timeout_s}s")


def chip_erase(dev) -> None:
    wren(dev)
    _reg_w(dev, SPI_CMD, CMD_CHIP_ERASE)
    _reg_w(dev, SPI_LEN, 0)
    _reg_w(dev, SPI_CTRL, CTRL_START)
    if not _wait_done(dev, 1.0):
        raise RuntimeError("CHIP_ERASE command timeout")
    print("  chip erase started, waiting WIP=0 (~30-60 s)...")
    wait_wip(dev, 120.0)
    print("  chip erase complete")


def page_program(dev, addr: int, data: bytes) -> None:
    assert 0 < len(data) <= PAGE_SIZE
    wren(dev)
    _reg_w(dev, SPI_CMD, CMD_PAGE_PROG)
    _reg_w(dev, SPI_ADDR, addr & 0xFFFFFF)
    _reg_w(dev, SPI_LEN, len(data))
    for b in data:
        _reg_w(dev, SPI_DATA, b & 0xFF)
    _reg_w(dev, SPI_CTRL, CTRL_START)
    if not _wait_done(dev, 1.0):
        raise RuntimeError(f"PAGE_PROG @ 0x{addr:X} timeout")
    wait_wip(dev, 5.0)


def read_flash(dev, addr: int, length: int) -> bytes:
    out = bytearray()
    offset = 0
    while offset < length:
        chunk = min(0x1000, length - offset)
        _reg_w(dev, SPI_CMD, CMD_READ)
        _reg_w(dev, SPI_ADDR, (addr + offset) & 0xFFFFFF)
        _reg_w(dev, SPI_LEN, chunk)
        _reg_w(dev, SPI_CTRL, CTRL_START)
        if not _wait_done(dev, 2.0):
            raise RuntimeError(f"READ @ 0x{addr + offset:X} timeout")
        for _ in range(chunk):
            out.append(_reg_r(dev, SPI_RX) & 0xFF)
        offset += chunk
    return bytes(out)


def program(dev, fw: bytes, verify: bool = True, do_erase: bool = True) -> None:
    if len(fw) > CHIP_SIZE:
        raise RuntimeError(f"firmware {len(fw)} > chip size {CHIP_SIZE}")
    if do_erase:
        chip_erase(dev)
    # Write in 256-byte pages
    n = len(fw)
    pages = (n + PAGE_SIZE - 1) // PAGE_SIZE
    t0 = time.monotonic()
    for i in range(pages):
        off = i * PAGE_SIZE
        chunk = fw[off : off + PAGE_SIZE]
        page_program(dev, off, chunk)
        if (i + 1) % 256 == 0 or i == pages - 1:
            pct = 100.0 * (i + 1) / pages
            rate = (i + 1) * PAGE_SIZE / max(time.monotonic() - t0, 0.001)
            print(f"  [{pct:5.1f}%] {i+1}/{pages} pages  ({rate/1024:.1f} KB/s)")
    print(f"  wrote {n} bytes")
    if verify:
        print("  verifying...")
        mismatch = 0
        for i in range(pages):
            off = i * PAGE_SIZE
            chunk = fw[off : off + PAGE_SIZE]
            got = read_flash(dev, off, len(chunk))
            if got != chunk:
                mismatch += 1
                for j, (a, b) in enumerate(zip(got, chunk)):
                    if a != b:
                        print(f"    MISMATCH @ 0x{off+j:X}: got 0x{a:02X}, expected 0x{b:02X}")
                        break
                if mismatch > 5:
                    break
        if mismatch:
            raise RuntimeError(f"verify failed: {mismatch} page(s) mismatched")
        print("  verify OK")


def icap_iprog(dev) -> None:
    """Trigger FPGA reload from SPI flash via ICAPE2 IPROG command.

    IPROG command sequence (UG470 Table 6-6):
      sync word, NOOP, RCRC, ... , IPROG (0x0000000F), NOOP.
    NOTE: command bytes below are BE-represented as in .bin, sent via IcapLoader
    writing LE-words to DATA. This is a simplified IPROG-only sequence.
    """
    print("  triggering IPROG (FPGA reload from flash)...")
    # From Xilinx UG470: minimal IPROG sequence as 32-bit words.
    # sync (BE 0xAA995566), NOOP (0x20000000), IPROG (0x30020001 + 0x0000000F),
    # then NOOP + DESYNC.
    seq_be = [
        0xFFFFFFFF,  # dummy lead-in
        0xAA995566,  # sync
        0x20000000,  # type1 NOOP
        0x30020001,  # write to WBSTAR (dummy)
        0x00000000,
        0x30008001,  # write to CMD
        0x0000000F,  # IPROG opcode
        0x20000000,  # NOOP
    ]
    def bswap32(x: int) -> int:
        return int.from_bytes((x & 0xFFFFFFFF).to_bytes(4, "big"), "little")
    _reg_w(dev, ICAP_CTRL, ICAP_CTRL_GO)
    time.sleep(0.02)
    for be in seq_be:
        # wait ready
        t0 = time.monotonic()
        while time.monotonic() - t0 < 0.1:
            if _reg_r(dev, ICAP_STATUS) & 0x1:
                break
        _reg_w(dev, ICAP_DATA, bswap32(be))
    time.sleep(0.02)
    try:
        _reg_w(dev, ICAP_CTRL, ICAP_CTRL_STOP)
    except Exception:
        pass  # link may drop as FPGA reloads
    print("  IPROG sent (PCIe link will drop ~5-10 s while FPGA reloads)")


# --------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bitstream", nargs="?", help=".bin file to program into SPI flash")
    ap.add_argument("--rdid", action="store_true", help="just read JEDEC ID and exit")
    ap.add_argument("--read", metavar="OUT", help="read flash to file")
    ap.add_argument("--addr", type=lambda s: int(s, 0), default=0)
    ap.add_argument("--len", type=lambda s: int(s, 0), default=4096)
    ap.add_argument("--no-erase", action="store_true", help="skip chip erase (page program only)")
    ap.add_argument("--no-verify", action="store_true")
    ap.add_argument("--iprog", action="store_true", help="trigger FPGA reload from flash after write")
    ap.add_argument("--dry-run", action="store_true", help="parse bitstream, no HW writes")
    args = ap.parse_args()

    if args.rdid:
        dev = _open_device()
        print("reading JEDEC ID...")
        try:
            jid = read_id(dev)
            print(f"  JEDEC ID: {jid.hex().upper()}")
            if tuple(jid) == FLASH_ID_EXPECTED:
                print("  -> W25Q128JV (Winbond) confirmed")
                return 0
            else:
                print(f"  -> unexpected (expected {bytes(FLASH_ID_EXPECTED).hex().upper()})")
                return 1
        except Exception as e:
            print(f"ERROR: {e}", file=sys.stderr)
            return 4

    if args.read:
        dev = _open_device()
        print(f"reading {args.len} bytes from 0x{args.addr:X}...")
        data = read_flash(dev, args.addr, args.len)
        with open(args.read, "wb") as f:
            f.write(data)
        print(f"  saved to {args.read}")
        return 0

    if not args.bitstream:
        ap.error("specify bitstream or --rdid / --read")

    with open(args.bitstream, "rb") as f:
        fw = f.read()
    print(f"bitstream: {args.bitstream}")
    print(f"size:      {len(fw)} bytes ({len(fw)/1024:.1f} KB)")

    if args.dry_run:
        print("dry-run: nothing written")
        return 0

    dev = _open_device()
    print("precheck JEDEC ID...")
    jid = read_id(dev)
    print(f"  JEDEC ID: {jid.hex().upper()}")
    if tuple(jid) != FLASH_ID_EXPECTED:
        print(f"ERROR: unexpected ID (expected {bytes(FLASH_ID_EXPECTED).hex().upper()})", file=sys.stderr)
        return 4

    print("programming...")
    program(dev, fw, verify=not args.no_verify, do_erase=not args.no_erase)
    print("SUCCESS")

    if args.iprog:
        icap_iprog(dev)

    return 0


if __name__ == "__main__":
    sys.exit(main())
