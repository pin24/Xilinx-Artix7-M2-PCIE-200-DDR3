"""Offline DDR3 DMA round-trip test через mock-устройство (проверяет driver path
без железа). Пишет TFloat48 (8-байт и 6-байт packing), читает обратно, сверяет.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from xdma_driver import XdmaDevice, TdotCore, DDR3_BASE

BITS = [0x05a452996588, 0x04648a296169, 0x1a2640469540, 0x06806a5a5aa4]

class MockDevice(XdmaDevice):
    """Mock DDR3: write/read по адресу как dict bytes (эмуляция DMA-окна)."""
    def __init__(self):
        self.mem = {}
    def write(self, addr, data):
        for i, by in enumerate(data):
            self.mem[addr + i] = by
    def read(self, addr, length):
        b = bytearray()
        for i in range(length):
            b.append(self.mem.get(addr + i, 0))
        return bytes(b)

def main():
    dev = MockDevice()
    core = TdotCore(dev, num_mac=8)
    # 8-байт packing round-trip
    core.write_tf48(0x0, BITS)
    back = [core.read_tf48(0x0 + i*8) for i in range(len(BITS))]
    ok8 = back == BITS
    print(f"8-байт round-trip: {'OK' if ok8 else 'FAIL'}")
    # 6-байт packing round-trip
    core.write_tf48_packed(0x1000, BITS)
    back6 = core.read_tf48_packed(0x1000, len(BITS))
    ok6 = back6 == BITS
    print(f"6-байт round-trip: {'OK' if ok6 else 'FAIL'}")
    # footprint
    n = len(BITS)
    print(f"footprint: 8/elt={n*8} B vs 6/elt={n*6} B (экономия {100*(n*8-n*6)//(n*8)}%)")
    return 0 if (ok8 and ok6) else 1

if __name__ == "__main__":
    sys.exit(main())
