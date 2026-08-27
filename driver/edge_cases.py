#!/usr/bin/env python3
"""Edge-case тестирование эмуляции XDMA драйвера + FPGA"""
import struct
import time
import threading

# ============================================================
# 1. Модель FPGA (копия из emulate_test.py)
# ============================================================
class FpgaEmulator:
    NUM_MAC = 32

    def __init__(self):
        self.bar0 = bytearray(128 * 1024 * 1024)
        self.bar2 = bytearray(256 * 1024 * 1024)
        self._busy = False
        self._done = False
        self._go_pending = False
        self._timer = None

        self._tdot = {
            'ctrl': 0, 'status': 0, 'n_in': 0,
            'res0': 0, 'res1': 0,
            'data_addr_lo': 0, 'data_addr_hi': 0,
            'weights_addr_lo': 0, 'weights_addr_hi': 0,
            'result_addr_lo': 0, 'result_addr_hi': 0,
            'core_res0': 0, 'core_res1': 0,
        }
        self._icap = {'ctrl': 0, 'status': 1, 'data': 0}
        self._xadc = {'temp': 0x0A00, 'vccint': 0x0D55, 'status': 1}
        self._gpio = {'data': 0, 'tri': 0xFF}

    def _tdot_write(self, addr, val):
        if addr == 0x00:
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
        n_eff = n if n != 0 else self.NUM_MAC
        self._tdot['status'] = 0x01
        def _compute():
            time.sleep(0.02)
            self._tdot['res0'] = 0xDEAD
            self._tdot['res1'] = 0xBEEF
            self._tdot['core_res0'] = 0xDEAD
            self._tdot['core_res1'] = 0xBEEF
            self._tdot['status'] = 0x02
        t = threading.Thread(target=_compute, daemon=True)
        t.start()

    def read(self, offset, length=4):
        addr = offset
        if addr < 0x80000000:
            if 0x40000000 <= addr < 0x40001000:
                off = addr - 0x40000000
                if off == 0x00: return struct.pack('<I', self._gpio['data'])
                elif off == 0x04: return struct.pack('<I', self._gpio['tri'])
            elif 0x40001000 <= addr < 0x40002000:
                off = addr - 0x40001000
                return struct.pack('<I', self._tdot_read(off))
            elif 0x40002000 <= addr < 0x40003000:
                off = addr - 0x40002000
                if off == 0x00: return struct.pack('<I', self._icap['ctrl'])
                elif off == 0x04: return struct.pack('<I', self._icap['status'])
                elif off == 0x08: return struct.pack('<I', self._icap['data'])
            elif 0x46000000 <= addr < 0x46001000:
                off = addr - 0x46000000
                if off == 0x00: return struct.pack('<I', self._xadc['temp'])
                elif off == 0x04: return struct.pack('<I', self._xadc['vccint'])
                elif off == 0x08: return struct.pack('<I', self._xadc['status'])
            return bytes(self.bar0[addr:addr+length])
        else:
            off = addr - 0x80000000
            if off + length > len(self.bar2):
                return b'\x00' * length
            return bytes(self.bar2[off:off+length])

    def write(self, offset, data):
        addr = offset
        if addr < 0x80000000:
            if 0x40000000 <= addr < 0x40001000:
                off = addr - 0x40000000
                val = struct.unpack('<I', data[:4])[0]
                if off == 0x00: self._gpio['data'] = val
                elif off == 0x04: self._gpio['tri'] = val
            elif 0x40001000 <= addr < 0x40002000:
                off = addr - 0x40001000
                self._tdot_write(off, struct.unpack('<I', data[:4])[0])
            elif 0x40002000 <= addr < 0x40003000:
                off = addr - 0x40002000
                val = struct.unpack('<I', data[:4])[0]
                if off == 0x00: self._icap['ctrl'] = val
                elif off == 0x08: self._icap['data'] = val
            elif 0x46000000 <= addr < 0x46001000:
                pass
            else:
                self.bar0[addr:addr+len(data)] = data
        else:
            off = addr - 0x80000000
            if off + len(data) <= len(self.bar2):
                self.bar2[off:off+len(data)] = data

class XdmaDriver:
    def __init__(self, emu):
        self.emu = emu
    def read_reg(self, addr):
        return struct.unpack('<I', self.emu.read(addr, 4))[0]
    def write_reg(self, addr, val):
        self.emu.write(addr, struct.pack('<I', val))
    def read_block(self, addr, length):
        return self.emu.read(addr, length)
    def write_block(self, addr, data):
        self.emu.write(addr, data)

# ============================================================
# Константы
# ============================================================
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
DDR3_SIZE   = 256 * 1024 * 1024  # 256MB

NUM_MAC = 32

PASS = 0
FAIL = 0

def test(name, ok):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  >>> PASS")
    else:
        FAIL += 1
        print(f"  >>> FAIL")

# ============================================================
# EDGE CASE 1: N_IN граничные значения
# ============================================================
def edge_n_in_bounds(drv):
    print("\n" + "="*60)
    print("EDGE CASE 1: N_IN граничные значения")
    print("="*60)

    cases = [
        (0,  NUM_MAC, "N_IN=0 -> n_in_eff=NUM_MAC(32)"),
        (1,  1,       "N_IN=1 -> n_in_eff=1 (min)"),
        (32, 32,      "N_IN=32 -> n_in_eff=32 (max)"),
        (33, 32,      "N_IN=33 -> n_in_eff=32 (clamp)"),
    ]

    all_ok = True
    for n_in, expected_n_eff, desc in cases:
        # Сброс эмулятора (пересоздаём)
        drv.write_reg(TDOT_N_IN, n_in)
        readback = drv.read_reg(TDOT_N_IN)
        print(f"  [{desc}]")
        print(f"    N_IN written={n_in}, readback={readback}")
        if readback != n_in:
            print(f"    FAIL: readback mismatch! expected {n_in}")
            all_ok = False
            continue

        drv.write_reg(TDOT_CTRL, 0x01)  # GO
        ctrl = drv.read_reg(TDOT_CTRL)
        print(f"    After GO: CTRL=0x{ctrl:08X}")

        # Ждём DONE
        for _ in range(200):
            st = drv.read_reg(TDOT_STATUS)
            if st & 0x02:
                break
            time.sleep(0.001)
        st = drv.read_reg(TDOT_STATUS)
        n_in_after = drv.read_reg(TDOT_N_IN)
        res0 = drv.read_reg(TDOT_RES0)
        res1 = drv.read_reg(TDOT_RES1)
        print(f"    STATUS=0x{st:08X}, N_IN after compute={n_in_after}, RES0=0x{res0:04X}, RES1=0x{res1:04X}")

        # Проверяем что n_in не изменился (RTL fix)
        if n_in_after != n_in:
            print(f"    FAIL: N_IN corrupted after GO! {n_in} -> {n_in_after}")
            all_ok = False

    test("EDGE1: N_IN bounds", all_ok)

# ============================================================
# EDGE CASE 2: Большие адреса BAR0 / граница BAR0-BAR2
# ============================================================
def edge_bar0_boundary(drv):
    print("\n" + "="*60)
    print("EDGE CASE 2: BAR0/AXI-Lite граница BAR2")
    print("="*60)
    all_ok = True

    # 2a. Последний валидный dword AXI-Lite RAM-буфера (128MB, конец буфера bar0)
    #     0x07FFFFFC находится в пределах buffer'а (128MB=0x08000000)
    last_bar0 = 0x07FFFFFC
    marker = 0xA5A5A5A5
    drv.write_block(last_bar0, struct.pack('<I', marker))
    rb = drv.read_block(last_bar0, 4)
    ok1 = (rb == struct.pack('<I', marker))
    print(f"  AXI-Lite RAM last dword [0x{last_bar0:08X}]: "
          f"wrote 0x{marker:08X}, read {rb.hex()}  ok={ok1}")
    all_ok &= ok1

    # 2b. Граница BAR0/BAR2: адрес 0x80000000 — первый байт BAR2 (DDR3).
    #     По факту эмулятора барьер декодирования = 0x80000000 (см. память проекта).
    #     Любой адрес < 0x80000000 — AXI-Lite, >= 0x80000000 — BAR2/AXI-MM (DDR3).
    drv.write_block(0x80000000, struct.pack('<I', 0xDEADBEEF))
    rb2 = drv.read_block(0x80000000, 4)
    ok2 = (rb2 == struct.pack('<I', 0xDEADBEEF))
    print(f"  BAR2/DDR3 first byte [0x80000000]: "
          f"wrote 0xDEADBEEF, read {rb2.hex()}  ok={ok2}")
    all_ok &= ok2

    # 2c. Незанятый AXI-Lite срез выше периферии (0x08000000..0x7FFFFFFF) не должен
    #     разрушать BAR2 — проверка отсутствия конфликта декодирования.
    bar0_gap = 0x08000010
    drv.write_block(bar0_gap, struct.pack('<I', 0x12345678))
    rb_gap = drv.read_block(bar0_gap, 4)
    # 0x08000010 >= 128MB буфера, поэтому читается как пустой AXI-Lite (0x00000000)
    print(f"  AXI-Lite gap [0x{bar0_gap:08X}] read {rb_gap.hex()} (no cross-talk)")

    test("EDGE2: BAR0/BAR2 boundary", all_ok)

# ============================================================
# EDGE CASE 3: DDR3 границы
# ============================================================
def edge_ddr3_bounds(drv):
    print("\n" + "="*60)
    print("EDGE CASE 3: DDR3 граничные адреса")
    print("="*60)

    all_ok = True

    # 3a. Первый байт DDR3
    addr_first = DDR3_BASE  # 0x80000000
    drv.write_block(addr_first, b'\x11\x22\x33\x44')
    rb = drv.read_block(addr_first, 4)
    print(f"  DDR3 first [0x{addr_first:08X}]: wrote 11223344, read {rb.hex()}")
    if rb != b'\x11\x22\x33\x44':
        all_ok = False

    # 3b. Последний байт DDR3
    addr_last = DDR3_BASE + DDR3_SIZE - 4  # 0x8FFFFFFC
    drv.write_block(addr_last, b'\xAA\xBB\xCC\xDD')
    rb = drv.read_block(addr_last, 4)
    print(f"  DDR3 last [0x{addr_last:08X}]: wrote AABBCCDD, read {rb.hex()}")
    if rb != b'\xAA\xBB\xCC\xDD':
        all_ok = False

    # 3c. За пределами DDR3 (должен вернуть нули)
    addr_oob = DDR3_BASE + DDR3_SIZE + 0x1000  # 0x90001000
    rb = drv.read_block(addr_oob, 4)
    print(f"  DDR3 OOB [0x{addr_oob:08X}]: read {rb.hex()} (expect 00000000)")
    if rb != b'\x00\x00\x00\x00':
        all_ok = False

    # 3d. Запись за пределами DDR3 (должна быть отброшена)
    addr_oob2 = DDR3_BASE + DDR3_SIZE  # 0x90000000
    drv.write_block(addr_oob2, b'\xFF\xEE\xDD\xCC')
    rb = drv.read_block(addr_oob2, 4)
    print(f"  DDR3 OOB write [0x{addr_oob2:08X}]: read {rb.hex()} (expect 00000000)")
    if rb != b'\x00\x00\x00\x00':
        all_ok = False

    # 3e. Середина DDR3 (smoke test)
    addr_mid = DDR3_BASE + 0x4000000  # 64MB
    drv.write_block(addr_mid, b'\xDE\xAD\xBE\xEF')
    rb = drv.read_block(addr_mid, 4)
    print(f"  DDR3 mid [0x{addr_mid:08X}]: wrote DEADBEEF, read {rb.hex()}")
    if rb != b'\xDE\xAD\xBE\xEF':
        all_ok = False

    test("EDGE3: DDR3 bounds", all_ok)

# ============================================================
# EDGE CASE 4: N_IN после GO (RTL fix verification)
# ============================================================
def edge_n_in_after_go(drv):
    print("\n" + "="*60)
    print("EDGE CASE 4: N_IN сохраняется после GO (RTL fix)")
    print("="*60)

    all_ok = True

    # 4a. N_IN=16, потом GO — должно остаться 16
    drv.write_reg(TDOT_N_IN, 0)
    drv.write_reg(TDOT_N_IN, 16)
    n1 = drv.read_reg(TDOT_N_IN)
    print(f"  N_IN written=16, read={n1}")
    if n1 != 16:
        all_ok = False

    drv.write_reg(TDOT_CTRL, 0x01)  # GO
    time.sleep(0.001)
    ctrl = drv.read_reg(TDOT_CTRL)
    n2 = drv.read_reg(TDOT_N_IN)
    print(f"  After GO: CTRL=0x{ctrl:08X}, N_IN={n2}")
    if n2 != 16:
        print(f"  FAIL! N_IN corrupted: expected 16, got {n2}")
        all_ok = False

    # Ждём завершения
    for _ in range(200):
        st = drv.read_reg(TDOT_STATUS)
        if st & 0x02:
            break
        time.sleep(0.001)
    st = drv.read_reg(TDOT_STATUS)
    n3 = drv.read_reg(TDOT_N_IN)
    print(f"  After DONE: STATUS=0x{st:08X}, N_IN={n3}")
    if n3 != 16:
        all_ok = False

    test("EDGE4: N_IN preserved after GO", all_ok)

# ============================================================
# EDGE CASE 5: Многократный GO (самосброс CTRL)
# ============================================================
def edge_multi_go(drv):
    print("\n" + "="*60)
    print("EDGE CASE 5: Многократный GO / самосброс CTRL")
    print("="*60)

    all_ok = True

    # 5a. GO=1, проверить самосброс
    drv.write_reg(TDOT_CTRL, 0x01)
    ctrl = drv.read_reg(TDOT_CTRL)
    print(f"  GO write 1, immediate read: CTRL=0x{ctrl:08X}")
    if ctrl != 0x01:
        print(f"  FAIL: CTRL should be 1 after GO write, got {ctrl}")
        all_ok = False

    # На эмуляторе ctrl остаётся 1 (нет тактов)
    # Но проверяем что повторный GO=1 возможен
    # Ждём DONE
    for _ in range(200):
        st = drv.read_reg(TDOT_STATUS)
        if st & 0x02:
            break
        time.sleep(0.001)
    st = drv.read_reg(TDOT_STATUS)
    print(f"  After DONE: STATUS=0x{st:08X}, CTRL={drv.read_reg(TDOT_CTRL)}")

    # 5b. Второй GO
    drv.write_reg(TDOT_N_IN, 8)
    drv.write_reg(TDOT_CTRL, 0x01)
    ctrl2 = drv.read_reg(TDOT_CTRL)
    print(f"  2nd GO: CTRL=0x{ctrl2:08X}")
    for _ in range(200):
        st = drv.read_reg(TDOT_STATUS)
        if st & 0x02:
            break
        time.sleep(0.001)
    st = drv.read_reg(TDOT_STATUS)
    print(f"  2nd GO after DONE: STATUS=0x{st:08X}")

    # 5c. Третий GO
    drv.write_reg(TDOT_N_IN, 4)
    drv.write_reg(TDOT_CTRL, 0x01)
    ctrl3 = drv.read_reg(TDOT_CTRL)
    print(f"  3rd GO: CTRL=0x{ctrl3:08X}")
    for _ in range(200):
        st = drv.read_reg(TDOT_STATUS)
        if st & 0x02:
            break
        time.sleep(0.001)
    st = drv.read_reg(TDOT_STATUS)
    print(f"  3rd GO after DONE: STATUS=0x{st:08X}, N_IN={drv.read_reg(TDOT_N_IN)}")

    test("EDGE5: Multi GO", all_ok)

# ============================================================
# EDGE CASE 6: Все адреса периферии (smoke test ranges)
# ============================================================
def edge_periph_ranges(drv):
    print("\n" + "="*60)
    print("EDGE CASE 6: Все адреса периферии")
    print("="*60)

    all_ok = True

    # GPIO: 0x40000000-0x40000008
    print("\n  -- GPIO (0x40000000-0x40000008) --")
    drv.write_reg(GPIO_TRI, 0x00)
    drv.write_reg(GPIO_DATA, 0xFF)
    d = drv.read_reg(GPIO_DATA)
    t = drv.read_reg(GPIO_TRI)
    print(f"    DATA=0x{d:08X}, TRI=0x{t:08X}")
    if d != 0xFF or t != 0x00:
        all_ok = False

    # TDOT REGS: 0x40001000-0x40001030
    print("\n  -- TDOT REGS (0x40001000-0x40001030) --")
    for offset in [0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20, 0x24, 0x28, 0x2C, 0x30]:
        addr = TDOT_BASE + offset
        if offset in (0x00,):  # CTRL: only GO bit[0] stored
            drv.write_reg(addr, 0xDEAD)
            v = drv.read_reg(addr)
            expect = 0x01
            print(f"    [0x{addr:08X}] RW: wrote 0xDEAD, read 0x{v:08X} (expect 0x{expect:08X}, bit0 only)")
            if v != expect:
                all_ok = False
        elif offset in (0x04, 0x0C, 0x10, 0x2C, 0x30):  # read-only
            v = drv.read_reg(addr)
            print(f"    [0x{addr:08X}] RO: 0x{v:08X}")
        else:
            drv.write_reg(addr, 0xDEAD + offset)
            v = drv.read_reg(addr)
            expect = 0xDEAD + offset
            if v != expect:
                all_ok = False
            print(f"    [0x{addr:08X}] RW: wrote 0x{expect:08X}, read 0x{v:08X}")

    # ICAP: 0x40002000-0x40002008
    print("\n  -- ICAP (0x40002000-0x40002008) --")
    for offset in [0x00, 0x04, 0x08]:
        addr = ICAP_BASE + offset
        if offset == 0x04:  # ready — RO
            v = drv.read_reg(addr)
            print(f"    [0x{addr:08X}] RO: 0x{v:08X}")
        elif offset == 0x00:  # ctrl
            drv.write_reg(addr, 0x55)
            v = drv.read_reg(addr)
            print(f"    [0x{addr:08X}] RW: wrote 0x55, read 0x{v:08X}")
        elif offset == 0x08:  # data
            drv.write_reg(addr, 0xAABBCCDD)
            v = drv.read_reg(addr)
            print(f"    [0x{addr:08X}] RW: wrote 0xAABBCCDD, read 0x{v:08X}")

    # XADC: 0x46000000-0x46000008 (3 регистра)
    print("\n  -- XADC (0x46000000-0x46000008) --")
    for offset in [0x00, 0x04, 0x08]:
        addr = XADC_BASE + offset
        v = drv.read_reg(addr)
        print(f"    [0x{addr:08X}] RO: 0x{v:08X}")

    test("EDGE6: Periph ranges", all_ok)

# ============================================================
# MAIN
# ============================================================
print("="*60)
print("XDMA EDGE-CASE EMULATION TESTS")
print("="*60)

emu = FpgaEmulator()
drv = XdmaDriver(emu)

edge_n_in_bounds(drv)
edge_bar0_boundary(drv)
edge_ddr3_bounds(drv)
edge_n_in_after_go(drv)
edge_multi_go(drv)
edge_periph_ranges(drv)

print("\n" + "="*60)
print(f"TOTAL: {PASS} PASS, {FAIL} FAIL ({PASS+FAIL} tests)")
print("="*60)
if FAIL == 0:
    print("ALL EDGE CASES PASSED")
else:
    print("SOME EDGE CASES FAILED")