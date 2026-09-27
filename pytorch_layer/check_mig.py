import struct, sys, time
from xdma_driver import XdmaWinDriver, XdmaWindows, XdmaError

GPIO2_DATA = 0x40000008

def main():
    dev = None
    for name, ctor in (("XdmaWinDriver", XdmaWinDriver), ("XdmaWindows", XdmaWindows)):
        try:
            dev = ctor()
            print(f"Opened via: {name}")
            break
        except Exception as e:
            print(f"  {name}: {e}")
    if dev is None:
        print("ERROR: no device")
        return 3
    time.sleep(1.0)
    try:
        st = struct.unpack("<I", dev.read(GPIO2_DATA, 4))[0]
    except XdmaError as e:
        print(f"ERROR reading GPIO2: {e}")
        return 4
    mmcm, calib = bool(st & 1), bool(st & 2)
    print(f"GPIO2 = 0x{st:08X}")
    print(f"  mmcm_locked         = {int(mmcm)}")
    print(f"  init_calib_complete = {int(calib)}")
    if mmcm and calib:
        print("RESULT: DDR3 OK - MIG calibrated.")
        return 0
    print("RESULT: MIG NOT ready.")
    if not mmcm:  print("  -> MMCM not locked")
    if not calib: print("  -> Calib failed")
    return 1

if __name__ == "__main__":
    sys.exit(main())
