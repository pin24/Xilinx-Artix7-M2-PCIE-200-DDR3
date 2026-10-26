"""Лестница h2c 4..512 КиБ x3 (аудит REPORT_V2, вариант B).

ВНИМАНИЕ: запускать ТОЛЬКО в обычном окне терминала, не через агентскую обёртку:
прерывание процесса во время DMA оставляет движок wedged (проверено дважды:
kill на 64 Б записи -> timeout at 0x23068).

Порядок по протоколу аудита:
  1) канарейка 64 Б (движок чист?);
  2) лестница: 4,16,64,128,192,256,320,384,448,496,512 КиБ, по 3 повтора;
     успех всех 3 -> следующая точка;
  3) первый клин -> сразу wedge_battery.py (read-only), до любых сбросов/reboot;
  4) выход. Порог P = последний успешный размер.

Запуск:
  python C:\\Temp\\gigatool\\hw_check\\ladder.py > C:\\Temp\\gigatool\\hw_check\\ladder.log 2>&1

Скрипт НЕ делает сбросов и НЕ пишет регистры — только write_dma/read_dma.
"""

import os
import subprocess
import sys
import time

sys.path.insert(0, r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\pytorch_layer")
from test_dma_win import XdmaWinDma

ADDR = 0x0020_0000
SIZES_KIB = (4, 16, 64, 128, 192, 256, 320, 384, 448, 496, 512)
REPEATS = 3
BATTERY = r"C:\Temp\gigatool\hw_check\wedge_battery.py"
BATTERY_FALLBACK = r"C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\docs\audit-h2c-wedge-2026-10-22\wedge_battery.py"


def log(msg=""):
    print(msg, flush=True)


def pattern(n):
    return bytes(((i * 7) & 0xFF) for i in range(n))


def main():
    log("=== LADDER START %s ===" % time.strftime("%Y-%m-%d %H:%M:%S"))
    dev = XdmaWinDma(base=r"\\.\XDMA0dma")

    canary = pattern(64)
    t0 = time.monotonic()
    try:
        dev.write_dma(ADDR, canary)
        back = dev.read_dma(ADDR, 64)
        dt = (time.monotonic() - t0) * 1e3
    except Exception as exc:
        log("CANARY FAIL after %.1f ms: %r" % ((time.monotonic() - t0) * 1e3, exc))
        log("=== LADDER ABORT: engine not clean, power-cycle required ===")
        dev.close()
        return 2
    if back != canary:
        log("CANARY MISMATCH: wr=%s rd=%s" % (canary.hex(), back.hex()))
        log("=== LADDER ABORT: engine not clean ===")
        dev.close()
        return 2
    log("CANARY OK: 64 B round-trip %.1f ms" % dt)

    # взводим счётчики XDMA ДО передачи — иначе perfDat на клине бессмыслен (perfCtrl=0)
    try:
        dev.perf_start()
        p0 = dev.perf_get()
        log("PERF ARMED: start=%r" % (p0,))
    except Exception as exc:
        log("PERF arm failed (продолжаем без счётчиков): %r" % exc)

    last_ok = 0
    for kib in SIZES_KIB:
        size = kib * 1024
        data = pattern(size)
        for rep in range(1, REPEATS + 1):
            t0 = time.monotonic()
            try:
                dev.write_dma(ADDR, data)
                t1 = time.monotonic()
                back = dev.read_dma(ADDR, size)
                t2 = time.monotonic()
            except Exception as exc:
                log("WEDGE  %4d KiB rep %d: FAIL after %.1f ms: %r"
                    % (kib, rep, (time.monotonic() - t0) * 1e3, exc))
                try:
                    log("PERF ON WEDGE: %r" % (dev.perf_get(),))
                except Exception as pe:
                    log("PERF read failed: %r" % pe)
                log("LAST_OK_SIZE_KIB=%d" % last_ok)
                log("P_THRESHOLD_KIB=%d (<=)" % kib)
                run_battery(size)
                dev.close()
                return 1
            ok = (back == data)
            log("ok      %4d KiB rep %d: write %.1f ms read %.1f ms match=%s"
                % (kib, rep, (t1 - t0) * 1e3, (t2 - t1) * 1e3, ok))
            if not ok:
                log("MISMATCH at %d KiB rep %d: data came back wrong (no timeout)"
                    % (kib, rep))
                log("LAST_OK_SIZE_KIB=%d" % last_ok)
                run_battery(size)
                dev.close()
                return 3
        last_ok = kib

    log("=== LADDER DONE: all points OK, no wedge up to 512 KiB ===")
    dev.close()
    return 0


def run_battery(size):
    script = BATTERY if os.path.exists(BATTERY) else BATTERY_FALLBACK
    log("\n--- evidence battery (read-only, before any reset) ---")
    if not os.path.exists(script):
        log("battery script not found: %s" % script)
        return
    try:
        subprocess.call([sys.executable, script, "--expect-bytes", str(size)])
    except Exception as exc:
        log("battery failed: %r" % exc)


if __name__ == "__main__":
    sys.exit(main())
