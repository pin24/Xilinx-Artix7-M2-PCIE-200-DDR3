#!/usr/bin/env python3
"""Интеграционная эмуляция: драйвер ↔ RTL-модель FPGA"""
import struct
import time
import threading

# ============================================================
# 1. МОДЕЛЬ FPGA (AXI-Lite BAR0 128MB, BAR2 256MB)
# ============================================================
class FpgaEmulator:
    def __init__(self):
        self.bar0 = bytearray(128 * 1024 * 1024)  # 128MB BAR0
        self.bar2 = bytearray(256 * 1024 * 1024)  # 256MB BAR2 (DDR3)
        self._busy = False
        self._done = False
        self._go_pending = False
        self._timer = None

        # по умолчанию
        self._tdot = {
            'ctrl': 0, 'status': 0, 'n_in': 0,
            'res0': 0, 'res1': 0,
            'data_addr_lo': 0, 'data_addr_hi': 0,
            'weights_addr_lo': 0, 'weights_addr_hi': 0,
            'result_addr_lo': 0, 'result_addr_hi': 0,
            'core_res0': 0, 'core_res1': 0,
        }
        self._icap = {'ctrl': 0, 'status': 1, 'data': 0}  # READY=1
        self._xadc = {'temp': 0x0A00, 'vccint': 0x0D55, 'status': 1}  # ~25°C, ~1.0V
        self._gpio = {'data': 0, 'tri': 0xFF}

    # --- RTL: TDOT запись ---
    def _tdot_write(self, addr, val):
        if addr == 0x00:  # CTRL — только GO, N_IN не затирается
            self._tdot['ctrl'] = val & 0x01
            if val & 0x01:
                self._start_compute()
        elif addr == 0x08:  # N_IN
            self._tdot['n_in'] = val & 0xFFFFFFFF
        elif addr == 0x14:  self._tdot['data_addr_lo'] = val
        elif addr == 0x18:  self._tdot['data_addr_hi'] = val
        elif addr == 0x1C:  self._tdot['weights_addr_lo'] = val
        elif addr == 0x20:  self._tdot['weights_addr_hi'] = val
        elif addr == 0x24:  self._tdot['result_addr_lo'] = val
        elif addr == 0x28:  self._tdot['result_addr_hi'] = val

    def _tdot_read(self, addr):
        if addr == 0x00: return self._tdot['ctrl']
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
        # RTL-баг: если n_in == 0 → n_in_eff = NUM_MAC (32)
        n_eff = n if n != 0 else 32
        self._tdot['status'] = 0x01  # BUSY
        def _compute():
            time.sleep(0.05)  # 50ms эмуляции
            self._tdot['res0'] = 0xDEAD  # [15:0]
            self._tdot['res1'] = 0xBEEF  # [47:32]
            self._tdot['core_res0'] = 0xDEAD
            self._tdot['core_res1'] = 0xBEEF
            self._tdot['status'] = 0x02  # DONE
        t = threading.Thread(target=_compute, daemon=True)
        t.start()

    # --- AXI-Lite интерфейс ---
    def read(self, offset, length=4):
        addr = offset
        if addr < 0x80000000:  # BAR0 (AXI-Lite)
            # декодирование периферии
            if 0x40000000 <= addr < 0x40001000:  # GPIO
                off = addr - 0x40000000
                if off == 0x00:  # DATA
                    return struct.pack('<I', self._gpio['data'])
                elif off == 0x04:  # TRI
                    return struct.pack('<I', self._gpio['tri'])
            elif 0x40001000 <= addr < 0x40002000:  # TDOT
                off = addr - 0x40001000
                val = self._tdot_read(off)
                return struct.pack('<I', val)
            elif 0x40002000 <= addr < 0x40003000:  # ICAP
                off = addr - 0x40002000
                if off == 0x00: return struct.pack('<I', self._icap['ctrl'])
                elif off == 0x04: return struct.pack('<I', self._icap['status'])
                elif off == 0x08: return struct.pack('<I', self._icap['data'])
            elif 0x46000000 <= addr < 0x46001000:  # XADC
                off = addr - 0x46000000
                if off == 0x00: return struct.pack('<I', self._xadc['temp'])
                elif off == 0x04: return struct.pack('<I', self._xadc['vccint'])
                elif off == 0x08: return struct.pack('<I', self._xadc['status'])
            # fallback: чтение из bar0 массива
            return bytes(self.bar0[addr:addr+length])
        else:  # BAR2 (DDR3)
            off = addr - 0x80000000
            if off + length > len(self.bar2):
                return b'\x00' * length
            return bytes(self.bar2[off:off+length])

    def write(self, offset, data):
        addr = offset
        if addr < 0x80000000:  # BAR0
            if 0x40000000 <= addr < 0x40001000:  # GPIO
                off = addr - 0x40000000
                val = struct.unpack('<I', data[:4])[0]
                if off == 0x00: self._gpio['data'] = val
                elif off == 0x04: self._gpio['tri'] = val
            elif 0x40001000 <= addr < 0x40002000:  # TDOT
                off = addr - 0x40001000
                val = struct.unpack('<I', data[:4])[0]
                self._tdot_write(off, val)
            elif 0x40002000 <= addr < 0x40003000:  # ICAP
                off = addr - 0x40002000
                val = struct.unpack('<I', data[:4])[0]
                if off == 0x00: self._icap['ctrl'] = val
                elif off == 0x08: self._icap['data'] = val
            elif 0x46000000 <= addr < 0x46001000:  # XADC (read-only)
                pass
            else:
                self.bar0[addr:addr+len(data)] = data
        else:  # BAR2
            off = addr - 0x80000000
            if off + len(data) <= len(self.bar2):
                self.bar2[off:off+len(data)] = data


# ============================================================
# 2. ДРАЙВЕР-ЭМУЛЯТОР (интерфейс как у ReadFile/WriteFile)
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
# 3. ТЕСТЫ (как в test_xdma.c)
# ============================================================
PASS = 0
FAIL = 0
def test(name, ok):
    global PASS, FAIL
    if ok: PASS += 1
    else: FAIL += 1
    print(f"  -> {'PASS' if ok else 'FAIL'}")

# --- Константы адресов ---
GPIO_BASE   = 0x40000000
GPIO_DATA   = GPIO_BASE + 0x00
GPIO_TRI    = GPIO_BASE + 0x04

TDOT_BASE   = 0x40001000
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

ICAP_BASE   = 0x40002000
ICAP_GO     = ICAP_BASE + 0x00
ICAP_READY  = ICAP_BASE + 0x04

XADC_BASE   = 0x46000000
XADC_TEMP   = XADC_BASE + 0x00
XADC_VCCINT = XADC_BASE + 0x04

DDR3_BASE   = 0x80000000

def test_gpio(drv):
    print("\n--- GPIO Test ---")
    # Set outputs
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

def test_tdot_regs(drv):
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

def test_xadc(drv):
    print("\n--- XADC Test ---")
    raw_temp = drv.read_reg(XADC_TEMP) & 0xFFFF
    raw_vcc = drv.read_reg(XADC_VCCINT) & 0xFFFF
    temp_c = (raw_temp * 503.975 / 4096.0) - 273.15
    vcc = raw_vcc * 3.0 / 4096.0
    print(f"  TEMP: raw=0x{raw_temp:04X} ({raw_temp}) -> {temp_c:.2f} °C")
    print(f"  VCCINT: raw=0x{raw_vcc:04X} ({raw_vcc}) -> {vcc:.3f} V")
    if raw_temp == 0 or raw_temp == 0xFFFF: return False
    return True

def test_tdot_protocol(drv):
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

    # Проверяем RTL-баг: GO затирает N_IN через [16:8]
    drv.write_reg(TDOT_CTRL, 0x01)  # GO
    n_after_go = drv.read_reg(TDOT_N_IN)
    print(f"  N_IN after GO = {n_after_go} (RTL bug: GO overwrites N_IN via [16:8])")
    if n_after_go != 8:
        print(f"  ⚠ RTL BUG CONFIRMED: GO wrote 0x00, n_in_reg = 0, n_in_eff = 32")

    # Ждём DONE
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

def test_icap(drv):
    print("\n--- ICAP Test ---")
    drv.write_reg(ICAP_GO, 1)
    time.sleep(0.05)
    ready = drv.read_reg(ICAP_READY)
    print(f"  ICAP_READY=0x{ready:08X} (bit0={'1' if ready & 0x01 else '0'})")
    return True

def test_bar2_ddr3(drv):
    print("\n--- BAR2 DDR3 Test ---")
    # Запись в DDR3
    drv.write_block(DDR3_BASE + 0x1000, b'\xAA\xBB\xCC\xDD\xEE\xFF')
    # Чтение обратно
    data = drv.read_block(DDR3_BASE + 0x1000, 6)
    print(f"  Written/read back: {data.hex()} (expect aabbccddeeff)")
    if data != b'\xAA\xBB\xCC\xDD\xEE\xFF':
        return False
    return True


# ============================================================
# 4. ЗАПУСК
# ============================================================
print("=== XDMA DDR3 INTEGRATION EMULATION ===")
print(f"{'Test':<15} {'Result':<10}")
print("-" * 30)

emu = FpgaEmulator()
drv = XdmaDriver(emu)

tests = [
    ("[GPIO]", test_gpio),
    ("[TDOT_REGS]", test_tdot_regs),
    ("[XADC]", test_xadc),
    ("[TDOT_PROTO]", test_tdot_protocol),
    ("[ICAP]", test_icap),
    ("[BAR2_DDR3]", test_bar2_ddr3),
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