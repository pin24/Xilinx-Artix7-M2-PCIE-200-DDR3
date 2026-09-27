# -*- coding: utf-8 -*-
"""
oct_diag.py — OCT-диагностика DMA H2C на живом железе (без блокировки).

Цель: подтвердить/опровергнуть гипотезу "дескриптор завершается на FPGA,
но channel MSI-X-прерывание не доходит до хоста" (Bugcheck/таймаут).

Метод:
  1. Открываем \\.\XDMA0dma\control (чтение регистров BAR0, безопасно — regs PASS)
     и \\.\XDMA0dma\h2c_0 (H2C-канал).
  2. Читаем исходное состояние движка H2C0 (identifier/status/completedDescCount/control)
     и IRQ-блока (channelIntEnable/Request/Pending).
  3. Запускаем H2C-запись 4 байт АСИНХРОННО (WriteFile + OVERLAPPED, ErrorIOPending=997);
     НЕ ждём её завершения, чтобы диаг скрипт не завис сам.
  4. Циклически читаем статусы движка/IRQ каждый tick и логируем с меткой времени
     в файл oct_diag.log. Если процесс застрянет в kernel на handle/close —
     последняя строка лога укажет точную стадию, на которой мы зависли.
  5. По истечении timeout: если completedDescCount==1 и status не BUSY, но IRQ не
     пришло (channelIntRequest навечно висит) => подтверждается "движок завершил,
     IRQ не доставлен" => нужен bounded-completion-poll.
     Если completedDescCount==0 и status BUSY => дескриптор/фетч не завершается.

Регистры (BAR0 config, H2C0 engine offset=0, sgdma=0x4000, irq=0x2000):
  engine identifier  @ 0x0000  (& 0xFFF00000 == 0x1FC00000)
  engine control     @ 0x0018  (RUN bit0, IE биты)
  engine status      @ 0x0040  (BUSY bit0, error биты)
  engine statusRC    @ 0x0044  (read+clear)
  completedDescCount @ 0x0048
  sgdma firstDescLo  @ 0x4080, firstDescHi @ 0x4084
  irq channelIntEnable @ 0x2040, W1S @0x2044? (по reg.h layout: enable=0x2010)
  irq channelIntRequest @ 0x2044, channelIntPending @ 0x204C

ADR_LITE_BASE = 0x40000000; offset в control-ноде = addr - 0x40000000.
"""
import ctypes
import sys
import datetime
import time
import threading
from ctypes import wintypes

BASE = r"\\.\XDMA0dma"
AXI_LITE_BASE = 0x40000000
LOOPBACK_OFF = 0x00100000

# BAR0-смещения регистров (для чтения через control-ноду: offset = bar0off)
ENG_IDENT = 0x0000
ENG_CONTROL = 0x0018
ENG_STATUS = 0x0040
ENG_STATUSRC = 0x0044
ENG_COMPLETED = 0x0048
SGDMA_FIRST_LO = 0x4080
SGDMA_FIRST_HI = 0x4084
IRQ_CH_EN = 0x2010
IRQ_CH_REQ = 0x2044
IRQ_CH_PEND = 0x204C

XDMA_ID_MASK = 0xFFF00000
XDMA_ID = 0x1FC00000
XDMA_CTRL_RUN = 0x00000001
XDMA_STAT_BUSY = 0x00000001

ERROR_IO_PENDING = 997

LOG = open("oct_diag.log", "w", encoding="utf-8")


def log(*args):
    line = "[%s] %s" % (datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3],
                        " ".join(str(a) for a in args))
    print(line, flush=True)
    LOG.write(line + "\n")
    LOG.flush()


class OV(ctypes.Structure):
    _fields_ = [
        ("Internal", ctypes.c_void_p),
        ("InternalHigh", ctypes.c_void_p),
        ("Offset", wintypes.DWORD),
        ("OffsetHigh", wintypes.DWORD),
        ("hEvent", wintypes.HANDLE),
    ]


k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.CreateFileW.restype = wintypes.HANDLE
k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                            ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                            wintypes.HANDLE]
k32.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                         ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
k32.WriteFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                          ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
k32.CloseHandle.argtypes = [wintypes.HANDLE]
k32.ResetEvent.argtypes = [wintypes.HANDLE]
k32.CreateEventW.restype = wintypes.HANDLE
k32.CreateEventW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL,
                             wintypes.LPCWSTR]


def open_node(name):
    h = k32.CreateFileW(BASE + "\\" + name, 0x80000000 | 0x40000000, 0, None, 3, 0x40000000, None)
    if not h or h == ctypes.c_void_p(-1).value:
        raise OSError("cannot open \\\\.\\XDMA0dma\\" + name + ": " + str(ctypes.get_last_error()))
    return h


_ev_read = k32.CreateEventW(None, True, False, None)


def read_reg(h_ctl, bar0_off, nbytes=4):
    ov = OV()
    ov.Offset = bar0_off & 0xFFFFFFFF
    ov.OffsetHigh = (bar0_off >> 32) & 0xFFFFFFFF
    ov.hEvent = _ev_read
    k32.ResetEvent(_ev_read)
    buf = ctypes.create_string_buffer(nbytes)
    done = wintypes.DWORD(0)
    ok = k32.ReadFile(h_ctl, buf, nbytes, ctypes.byref(done), ctypes.byref(ov))
    if not ok:
        err = ctypes.get_last_error()
        if err != ERROR_IO_PENDING:
            raise OSError("read reg fail @0x%X: %d" % (bar0_off, err))
        if k32.WaitForSingleObject(_ev_read, 3000) != 0:
            raise OSError("read reg TIMEOUT @0x%X" % bar0_off)
        dn = wintypes.DWORD(0)
        k32.GetOverlappedResult(h_ctl, ctypes.byref(ov), ctypes.byref(dn), False)
        done = dn
    return int.from_bytes(buf.raw[:done.value], "little")


def main():
    log("OCT diag start; control=" + BASE + r"\control" + " h2c=" + BASE + r"\h2c_0")
    h_ctl = open_node("control")
    log("STEP1: control opened")
    h_h2c = open_node("h2c_0")
    log("STEP2: h2c_0 opened")

    # ---- baseline ================
    ident = read_reg(h_ctl, ENG_IDENT)
    log("STEP3 baseline: engine H2C0 identifier=0x%08X (XDMA_ID? %s)"
        % (ident, "YES" if (ident & XDMA_ID_MASK) == XDMA_ID else "NO"))
    ctl = read_reg(h_ctl, ENG_CONTROL)
    st = read_reg(h_ctl, ENG_STATUS)
    comp = read_reg(h_ctl, ENG_COMPLETED)
    log("STEP4 baseline: control=0x%08X status=0x%08X completed=%u"
        % (ctl, st, comp))
    try:
        ch_en = read_reg(h_ctl, IRQ_CH_EN)
    except OSError:
        ch_en = -1
    ch_req = read_reg(h_ctl, IRQ_CH_REQ)
    ch_pend = read_reg(h_ctl, IRQ_CH_PEND)
    log("STEP5 baseline: irq chEn=0x%08X chReq=0x%08X chPend=0x%08X"
        % (ch_en, ch_req, ch_pend))

    # ---- async H2C write 4 bytes ================
    ev = k32.CreateEventW(None, True, False, None)
    ov = OV()
    ov.Offset = LOOPBACK_OFF & 0xFFFFFFFF
    ov.OffsetHigh = (LOOPBACK_OFF >> 32) & 0xFFFFFFFF
    ov.hEvent = ev
    buf = ctypes.create_string_buffer(b"\x11\x22\x33\x44", 4)
    done = wintypes.DWORD(0)
    ok = k32.WriteFile(h_h2c, buf, 4, ctypes.byref(done), ctypes.byref(ov))
    if not ok:
        err = ctypes.get_last_error()
        log("STEP6: WriteFile returned NOT-ok, last_err=%d (997=IO_PENDING)" % err)
        if err != ERROR_IO_PENDING:
            log("STEP6-FAIL: WriteFile error %d (не пдн) — канал/драйвер" % err)
            k32.CloseHandle(h_ctl); k32.CloseHandle(h_h2c); return 2
    else:
        log("STEP6: WriteFile returned OK synchronously (4 bytes done?)")
    log("STEP7: async H2C write kick sent @0x%X — теперь poll регистров" % LOOPBACK_OFF)

    # ---- poll FPGA registers + overlapped result every tick ================
    completed_before = read_reg(h_ctl, ENG_COMPLETED)
    timeout = 12.0
    t0 = time.monotonic()
    last_status = None
    while time.monotonic() - t0 < timeout:
        try:
            st = read_reg(h_ctl, ENG_STATUS)
            comp = read_reg(h_ctl, ENG_COMPLETED)
            ctl = read_reg(h_ctl, ENG_CONTROL)
            ch_req = read_reg(h_ctl, IRQ_CH_REQ)
            ch_pend = read_reg(h_ctl, IRQ_CH_PEND)
        except OSError as e:
            log("READ-ERR during poll: %s" % e)
            break
        # write result (non-blocking-ish): poll event 0ms
        wr = k32.WaitForSingleObject(ev, 0)
        ovr_done = -1
        if wr == 0:
            dn = wintypes.DWORD(0)
            k32.GetOverlappedResult(h_h2c, ctypes.byref(ov), ctypes.byref(dn), False)
            ovr_done = dn.value
        if st != last_status or wr == 0 or (comp != completed_before):
            log("POLL t=%4.2fs: status=0x%08X completed=%u (prev=%u) control=0x%08X "
                "irqReq=0x%08X irqPend=0x%08X writeResult=%s"
                % (time.monotonic() - t0, st, comp, completed_before, ctl,
                   ch_req, ch_pend, ovr_done if ovr_done >= 0 else "pending"))
            last_status = st
        if ovr_done >= 0 and comp > 0:
            log("RESULT: h2c write completed (%s), engine status=0x%08X completed=%u"
                % ("sync/async", st, comp))
            break
        time.sleep(0.02)

    # ---- final verdict ================
    try:
        st = read_reg(h_ctl, ENG_STATUS)
    except OSError:
        st = -1
    comp = read_reg(h_ctl, ENG_COMPLETED)
    busy = bool(st & XDMA_STAT_BUSY)
    irq_pend_now = read_reg(h_ctl, IRQ_CH_PEND)
    irq_req_now = read_reg(h_ctl, IRQ_CH_REQ)

    log("FINAL: completed=%u status=0x%08X (busy=%s) irqPend=0x%08X irqReq=0x%08X"
        % (comp, st, busy, irq_pend_now, irq_req_now))

    if comp > completed_before and not busy:
        if irq_pend_now == 0 and irq_req_now == 0:
            log("VERDICT: engine COMPLETED descriptor (completed %u), BUT channel-IRQ "
                "не висит в регистрах / не доставлен => подтверждена гипотеза "
                "«завершение на FPGA есть, MSI-X не доходит». Нужен bounded-poll." % comp)
        else:
            log("VERDICT: engine COMPLETED (completed %u), irqReq/Pend НЕ нулевые "
                "(0x%X/0x%X) => прерывание сгенерировано, но не доставлено/не снято." 
                % (comp, irq_req_now, irq_pend_now))
            log("VERDICT=IRQ-GENERATED-BUT-LOST")
        verdict = 0
    elif comp == completed_before:
        log("VERDICT: completedDescCount НЕ вырос (%u==%u) и/или status BUSY=%s "
            "=> дескриптор/фетч/адрес не завершается на FPGA (ОТЛИЧАЕТСЯ от гипотезы IRQ)."
            % (comp, completed_before, busy))
        verdict = 1
    else:
        log("VERDICT: status=%s, completed вырос до %u — уточнить" % (busy, comp))
        verdict = 2

    # ---- cleanup (последний логируемый шаг) ----
    log("CLEANUP: closing h2c handle... (может заблокироваться если транзакция висит)")
    k32.CloseHandle(h_h2c)
    log("CLEANUP: h2c closed OK")
    k32.CloseHandle(h_ctl)
    log("CLEANUP: control closed OK — EXIT=%d" % verdict)
    LOG.close()
    return verdict


if __name__ == "__main__":
    sys.exit(main())