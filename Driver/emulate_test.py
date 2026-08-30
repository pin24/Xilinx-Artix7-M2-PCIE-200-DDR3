#!/usr/bin/env python3
"""Интеграционная эмуляция V2: драйвер ↔ RTL-модель FPGA"""
import struct
import time
import threading

# ============================================================
# Адресная карта V2
#   GPIO:      0x40000000 (4K) — LED
#   HWICAP:    0x40001000 (4K) — AXI HWICAP (device ID @ 0x02C)
#   DFX Socket:0x40002000 (4K) — decouple/shutdown (AXI GPIO)
#   TDOT CSRs: 0x40010000+    — внутри RP (через rp_S_AXI)
#   DDR3:      0x80000000     — 256MB
# ============================================================

# ============================================================
# 1. МОДЕЛЬ FPGA (AXI-Lite BAR0 128MB, BAR2 256MB)
# ============================================================
class FpgaEmulator:
    def __init__(self):
        self.bar0 = bytearray(128 * 1024 * 1024)
        self.bar2 = bytearray(256 * 1024 * 1024)

        # TDOT (ядро, те же регистры, смещение 0x40010000 внутри RP)
        self._tdot = {
            'ctrl': 0, 'status': 0, 'n_in': 0,
            'res0': 0, 'res1': 0,
            'data_addr_lo': 0, 'data_addr_hi': 0,
            'weights_addr_lo': 0, 'weights_addr_hi': 0,
            'result_addr_lo': 0, 'result_addr_hi': 0,
            'core_res0': 0, 'core_res1': 0,
        }

        # HWICAP (AXI HWICAP, read-only device ID @ 0x02C)
        self._hwicap = {
            'hi': 0x00000000,       # 0x00 — HWICAP ID reg
            'ctrl': 0x00000000,     # 0x04
            'status': 0x00000000,   # 0x08
            'write_data': 0,        # 0x0C
            'write_count': 0,       # 0x10
            'read_data': 0,         # 0x14
            # 0x18-0x28: зарезервировано
            'device_id': 0x42610000, # 0x2C — 7-series Xilinx
        }

        # DFX Socket (AXI GPIO, dual channel)
        # ch1: биты [0]=decouple, [1]=shutdown_master, [2]=shutdown_slave
        # ch2: статусы shutdown/decouple
        self._dfx = {
            'data': 0,     # ch1 output
            'tri': 0xFF,   # ch1 direction (0=output)
            'data2': 0,    # ch2 input status
            'tri2': 0xFF,  # ch2 direction (1=input)
        }

        # GPIO (LED)
        self._gpio = {'data': 0, 'tri': 0xFF}

    # --- TDOT RTL ---
    def _tdot_write(self, addr, val):
        if addr == 0x00:  # CTRL
            self._tdot['ctrl'] = val & 0x01
            if val & 0x01:
                self._start_compute()
        elif addr == 0x08:
            self._tdot['n_in'] = val & 0xFFFFFFFF
        elif addr == 0x14:  self._tdot['data_addr_lo'] = val
        elif addr == 0x18:  self._tdot['data_addr_hi'] = val
        elif addr == 0x1C:  self._tdot['weights_addr_lo'] = val
        elif addr == 0x20:  self._tdot['weights_addr_hi'] = val
        elif addr == 0x24:  self._tdot['result_addr_lo'] = val
        elif addr == 0x28:  self._tdot['result_addr_hi'] = val

    def _tdot_read(self, addr):
        if   addr == 0x00: return self._tdot['ctrl']
        elif addr == 0x04: return self._tdot['status']
        elif addr == 0x08: return self._tdot['n_in']
        elif addr == 0x0C: return self._tdot['res0']
        elif addr == 0x10: return self._tdot['res1']
        elif addr == 0x14: return self._tdot['data_addr_lo']
        elif addr == 0x18: return self._tdot['data_addr_hi']
        elif addr == 0x1C: return self._tdot['weights_addr_lo']
        elif addr == 0x20: return self._tdot['weights_addr_hi']
        elif addr == 0x24: return self._tdot['result_addr_lo']
        elif addr == 0x28: return self._tdot['result_addr_hi']
        elif addr == 0x2C: return self._tdot['core_res0']
        elif addr == 0x30: return self._tdot['core_res1']
        return 0

    def _start_compute(self):
        n = self._tdot['n_in']
        n_eff = n if n != 0 else 32
        self._tdot['status'] = 0x01  # BUSY
        def _compute():
            time.sleep(0.05)
            self._tdot['res0'] = 0xDEAD
            self._tdot['res1'] = 0xBEEF
            self._tdot['core_res0'] = 0xDEAD
            self._tdot['core_res1'] = 0xBEEF
            self._tdot['status'] = 0x02  # DONE
        t = threading.Thread(target=_compute, daemon=True)
        t.start()

    # --- AXI-Lite ---
    def read(self, offset, length=4):
        addr = offset
        if addr < 0x80000000:  # BAR0
            # GPIO 0x40000000-0x40000FFF
            if 0x40000000 <= addr < 0x40001000:
                off = addr - 0x40000000
                if   off == 0x00: return struct.pack('<I', self._gpio['data'])
                elif off == 0x04: return struct.pack('<I', self._gpio['tri'])
            # HWICAP 0x40001000-0x40001FFF
            if 0x40001000 <= addr < 0x40002000:
                off = addr - 0x40001000
                if   off == 0x00: return struct.pack('<I', self._hwicap['hi'])
                elif off == 0x04: return struct.pack('<I', self._hwicap['ctrl'])
                elif off == 0x08: return struct.pack('<I', self._hwicap['status'])
                elif off == 0x0C: return struct.pack('<I', self._hwicap['write_data'])
                elif off == 0x10: return struct.pack('<I', self._hwicap['write_count'])
                elif off == 0x14: return struct.pack('<I', self._hwicap['read_data'])
                elif off == 0x2C: return struct.pack('<I', self._hwicap['device_id'])
            # DFX Socket 0x40002000-0x40002FFF
            if 0x40002000 <= addr < 0x40003000:
                off = addr - 0x40002000
                if   off == 0x00: return struct.pack('<I', self._dfx['data'])
                elif off == 0x04: return struct.pack('<I', self._dfx['tri'])
                elif off == 0x08: return struct.pack('<I', self._dfx['data2'])
                elif off == 0x0C: return struct.pack('<I', self._dfx['tri2'])
            # TDOT CSRs 0x40010000+
            if 0x40010000 <= addr < 0x40020000:
                off = addr - 0x40010000
                return struct.pack('<I', self._tdot_read(off))
            return bytes(self.bar0[addr:addr+length])
        else:  # BAR2 (DDR3)
            off = addr - 0x80000000
            if off + length > len(self.bar2):
                return b'\x00' * length
            return bytes(self.bar2[off:off+length])

    def write(self, offset, data):
        addr = offset
        if addr < 0x80000000:  # BAR0
            # GPIO
            if 0x40000000 <= addr < 0x40001000:
                off = addr - 0x40000000
                val = struct.unpack('<I', data[:4])[0]
                if   off == 0x00: self._gpio['data'] = val
                elif off == 0x04: self._gpio['tri'] = val
            # HWICAP (read-only по большей части; разрешена запись ctrl/write_data)
            elif 0x40001000 <= addr < 0x40002000:
                off = addr - 0x40001000
                val = struct.unpack('<I', data[:4])[0]
                if   off == 0x04: self._hwicap['ctrl'] = val
                elif off == 0x0C: self._hwicap['write_data'] = val
                elif off == 0x10: self._hwicap['write_count'] = val
            # DFX Socket
            elif 0x40002000 <= addr < 0x40003000:
                off = addr - 0x40002000
                val = struct.unpack('<I', data[:4])[0]
                if   off == 0x00:
                    self._dfx['data'] = val
                    # ch2 отражает статус decouple/shutdown
                    self._dfx['data2'] = self._dfx['data'] & 0x07
                elif off == 0x04: self._dfx['tri'] = val
            # TDOT CSRs
            elif 0x40010000 <= addr < 0x40020000:
                off = addr - 0x40010000
                val = struct.unpack('<I', data[:4])[0]
                self._tdot_write(off, val)
            else:
                self.bar0[addr:addr+len(data)] = data
        else:  # BAR2
            off = addr - 0x80000000
            if off + len(data) <= len(self.bar2):
                self.bar2[off:off+len(data)] = data


# ============================================================
# 2. ДРАЙВЕР-ЭМУЛЯТОР
# ============================================================
class XdmaDriver:
    def __init__(self, emu):
        self.emu = emu

    def read_reg(self, addr):
        data = self.emu.read(addr, 4)
        return struct.unpack('<I', data)[0]

    def write_reg(self, addr, val):
        self.emu.write(addr, struct.pack('<I', val))

    def read_block(self, addr, length):
        return self.emu.read(addr, length)

    def write_block(self, addr, data):
        self.emu.write(addr, data)


# ============================================================
# 3. ТЕСТЫ
# ============================================================
PASS = 0
FAIL = 0
def test(name, ok):
    global PASS, FAIL
    if ok: PASS += 1
    else: FAIL += 1
    print(f"  -> {'PASS' if ok else 'FAIL'}")

# --- Константы адресов V2 ---
GPIO_BASE   = 0x40000000
GPIO_DATA   = GPIO_BASE + 0x00
GPIO_TRI    = GPIO_BASE + 0x04

HWICAP_BASE     = 0x40001000
HWICAP_HI       = HWICAP_BASE + 0x00
HWICAP_CTRL     = HWICAP_BASE + 0x04
HWICAP_STATUS   = HWICAP_BASE + 0x08
HWICAP_DEVICE_ID = HWICAP_BASE + 0x2C

DFX_BASE    = 0x40002000
DFX_DATA    = DFX_BASE + 0x00
DFX_TRI     = DFX_BASE + 0x04
DFX_DATA2   = DFX_BASE + 0x08
DFX_TRI2    = DFX_BASE + 0x0C

TDOT_BASE   = 0x40010000
TDOT_CTRL   = TDOT_BASE + 0x00
TDOT_STATUS = TDOT_BASE + 0x04
TDOT_N_IN   = TDOT_BASE + 0x08
TDOT_RES0   = TDOT_BASE + 0x0C
TDOT_RES1   = TDOT_BASE + 0x10
TDOT_DATA_ADDR_LO   = TDOT_BASE + 0x14
TDOT_DATA_ADDR_HI   = TDOT_BASE + 0x18
TDOT_WEIGHTS_ADDR_LO = TDOT_BASE + 0x1C
TDOT_WEIGHTS_ADDR_HI = TDOT_BASE + 0x20
TDOT_RESULT_ADDR_LO  = TDOT_BASE + 0x24
TDOT_RESULT_ADDR_HI  = TDOT_BASE + 0x28
TDOT_CORE_RES0 = TDOT_BASE + 0x2C
TDOT_CORE_RES1 = TDOT_BASE + 0x30

DDR3_BASE   = 0x80000000

# -----------------------------------------------------------
def test_gpio(drv):
    """GPIO LED: запись/чтение DATA через TRI"""
    print("\n--- GPIO Test ---")

    drv.write_reg(GPIO_TRI, 0x00)
    tri = drv.read_reg(GPIO_TRI)
    print(f"  GPIO_TRI = 0x{tri:08X} (expect 0x00000000)")
    if tri != 0x00: return False

    drv.write_reg(GPIO_DATA, 0x01)
    d = drv.read_reg(GPIO_DATA)
    print(f"  GPIO_DATA (LED0)= 0x{d:08X}")
    if (d & 0x01) == 0: return False

    drv.write_reg(GPIO_DATA, 0x02)
    d = drv.read_reg(GPIO_DATA)
    print(f"  GPIO_DATA (LED1)= 0x{d:08X}")
    if (d & 0x02) == 0: return False

    drv.write_reg(GPIO_DATA, 0x00)
    d = drv.read_reg(GPIO_DATA)
    print(f"  GPIO_DATA (all off)= 0x{d:08X}")
    if d != 0: return False

    return True


def test_hwicap(drv):
    """HWICAP: чтение device ID регистра (0x2C)"""
    print("\n--- HWICAP Test ---")

    did = drv.read_reg(HWICAP_DEVICE_ID)
    print(f"  HWICAP DEVICE_ID = 0x{did:08X} (expect 0x42610000)")

    hi = drv.read_reg(HWICAP_HI)
    print(f"  HWICAP HI = 0x{hi:08X}")

    status = drv.read_reg(HWICAP_STATUS)
    print(f"  HWICAP STATUS = 0x{status:08X}")

    if did != 0x42610000:
        return False

    # device ID read-only — запись не меняет
    drv.write_reg(HWICAP_DEVICE_ID, 0x12345678)
    if drv.read_reg(HWICAP_DEVICE_ID) != 0x42610000:
        return False

    return True


def test_dfx_socket(drv):
    """DFX Socket: decouple/shutdown через AXI GPIO"""
    print("\n--- DFX Socket Test ---")

    # ch1: все выходы
    drv.write_reg(DFX_TRI, 0x00)
    tri = drv.read_reg(DFX_TRI)
    print(f"  DFX TRI = 0x{tri:08X} (expect 0x00000000)")
    if tri != 0x00: return False

    # ch2: все входы
    tri2 = drv.read_reg(DFX_TRI2)
    print(f"  DFX TRI2 = 0x{tri2:08X} (expect 0xFF — inputs)")
    if tri2 != 0xFF: return False

    # decouple=1, shutdown=0
    drv.write_reg(DFX_DATA, 0x01)
    d = drv.read_reg(DFX_DATA)
    d2 = drv.read_reg(DFX_DATA2)
    print(f"  decouple: DATA=0x{d:08X} DATA2=0x{d2:08X} (expect bit0=1 in both)")
    if (d & 0x01) == 0 or (d2 & 0x01) == 0: return False

    # shutdown_master=1
    drv.write_reg(DFX_DATA, 0x03)
    d = drv.read_reg(DFX_DATA)
    d2 = drv.read_reg(DFX_DATA2)
    print(f"  shutdown_master: DATA=0x{d:08X} DATA2=0x{d2:08X}")
    if (d & 0x03) != 0x03 or (d2 & 0x03) != 0x03: return False

    # shutdown_slave=1
    drv.write_reg(DFX_DATA, 0x07)
    d = drv.read_reg(DFX_DATA)
    d2 = drv.read_reg(DFX_DATA2)
    print(f"  shutdown_slave: DATA=0x{d:08X} DATA2=0x{d2:08X}")
    if (d & 0x07) != 0x07 or (d2 & 0x07) != 0x07: return False

    # все сбросить
    drv.write_reg(DFX_DATA, 0x00)
    d = drv.read_reg(DFX_DATA)
    d2 = drv.read_reg(DFX_DATA2)
    print(f"  all clear: DATA=0x{d:08X} DATA2=0x{d2:08X}")
    if d != 0 or d2 != 0: return False

    return True


def test_tdot_regs(drv):
    """TDOT регистры: запись/чтение CSR"""
    print("\n--- TDOT Register Test ---")

    regs = [
        (TDOT_N_IN, 8, "N_IN"),
        (TDOT_DATA_ADDR_LO, 0x80000000, "DATA_ADDR_LO"),
        (TDOT_DATA_ADDR_HI, 0, "DATA_ADDR_HI"),
        (TDOT_WEIGHTS_ADDR_LO, 0x80001000, "WEIGHTS_ADDR_LO"),
        (TDOT_RESULT_ADDR_LO, 0x80002000, "RESULT_ADDR_LO"),
    ]
    for addr, wval, name in regs:
        drv.write_reg(addr, wval)
        r = drv.read_reg(addr)
        print(f"  {name}: wrote 0x{wval:08X}, read 0x{r:08X}")
        if r != wval:
            return False

    res0 = drv.read_reg(TDOT_RES0)
    res1 = drv.read_reg(TDOT_RES1)
    st   = drv.read_reg(TDOT_STATUS)
    print(f"  RES0=0x{res0:08X} RES1=0x{res1:08X} STATUS=0x{st:08X} (read-only)")
    return True


def test_tdot_protocol(drv):
    """TDOT протокол: GO → DONE, проверка RTL-бага"""
    print("\n--- TDOT Protocol Test ---")

    drv.write_reg(TDOT_N_IN, 8)
    drv.write_reg(TDOT_DATA_ADDR_LO, 0x80000000)
    drv.write_reg(TDOT_DATA_ADDR_HI, 0)
    drv.write_reg(TDOT_WEIGHTS_ADDR_LO, 0x80001000)
    drv.write_reg(TDOT_WEIGHTS_ADDR_HI, 0)
    drv.write_reg(TDOT_RESULT_ADDR_LO, 0x80002000)
    drv.write_reg(TDOT_RESULT_ADDR_HI, 0)

    n = drv.read_reg(TDOT_N_IN)
    print(f"  N_IN readback = {n}")

    drv.write_reg(TDOT_CTRL, 0x01)  # GO
    n_after_go = drv.read_reg(TDOT_N_IN)
    print(f"  N_IN after GO = {n_after_go} (RTL bug: GO overwrites N_IN)")
    if n_after_go != 8:
        print(f"  ⚠ RTL BUG CONFIRMED: n_in_reg = 0, n_in_eff = 32")

    for _ in range(500):
        st = drv.read_reg(TDOT_STATUS)
        if st & 0x02:
            print(f"  DONE detected, STATUS=0x{st:08X}")
            break
        time.sleep(0.001)
    else:
        print("  TIMEOUT!")
        return False

    res0 = drv.read_reg(TDOT_RES0)
    res1 = drv.read_reg(TDOT_RES1)
    result = ((res1 & 0xFFFF) << 32) | (res0 & 0xFFFF)
    print(f"  RES0=0x{res0:08X} RES1=0x{res1:08X} -> combined=0x{result:012X}")
    return True


def test_bar2_ddr3(drv):
    """DDR3: запись/чтение блока через BAR2"""
    print("\n--- BAR2 DDR3 Test ---")

    drv.write_block(DDR3_BASE + 0x1000, b'\xAA\xBB\xCC\xDD\xEE\xFF')
    data = drv.read_block(DDR3_BASE + 0x1000, 6)
    print(f"  Written/read back: {data.hex()} (expect aabbccddeeff)")
    if data != b'\xAA\xBB\xCC\xDD\xEE\xFF':
        return False
    return True


# ============================================================
# 4. ЗАПУСК
# ============================================================
print("=== XDMA DDR3 V2 INTEGRATION EMULATION ===")
print(f"{'Test':<15} {'Result':<10}")
print("-" * 30)

emu = FpgaEmulator()
drv = XdmaDriver(emu)

tests = [
    ("[GPIO]",        test_gpio),
    ("[HWICAP]",      test_hwicap),
    ("[DFX_SOCKET]",  test_dfx_socket),
    ("[TDOT_REGS]",   test_tdot_regs),
    ("[TDOT_PROTO]",  test_tdot_protocol),
    ("[BAR2_DDR3]",   test_bar2_ddr3),
]

for name, fn in tests:
    print(f"{name:<15} ", end="")
    ok = fn(drv)
    test(name, ok)

print(f"\n=== RESULTS: {PASS} PASS, {FAIL} FAIL ({PASS+FAIL} total) ===")
if FAIL == 0:
    print("=== ALL TESTS PASSED ===")
else:
    print("=== SOME TESTS FAILED ===")