import struct, sys
from xdma_driver import XdmaWinDriver

REGS_BASE = 0x40000000
GPIO1 = REGS_BASE + 0x00
TDOT = REGS_BASE + 0x3000
ICAP = REGS_BASE + 0x4000

dev = XdmaWinDriver()
print("XdmaWinDriver opened OK")

for name, addr in (("GPIO1", GPIO1), ("TDOT STATUS", TDOT+0x04), ("ICAP STATUS", ICAP+0x04), ("GPIO2", GPIO1+0x08)):
    v = struct.unpack("<I", dev.read(addr, 4))[0]
    print(f"  {name:15s} @ 0x{addr:08X} = 0x{v:08X}")
