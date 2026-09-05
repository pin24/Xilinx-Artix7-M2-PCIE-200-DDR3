"""Мониторинг температуры и напряжения чипа через XADC.

Опрос регистров XADC (0x4600_0000) с заданным интервалом,
вывод timestamp + температура + VCCINT, CSV-лог опционально.

Usage:
    python monitor_temp.py [--log temps.csv] [--interval 2] [--device xdma0]
"""
from __future__ import annotations
import argparse
import csv
import signal
import sys
import time
from datetime import datetime, timezone

from xdma_driver import XdmaLinux, XdmaWindows, XdmaError

XADC_BASE = 0x4600_0000   # S_AXI_XADC_REGS: канонический адрес DFX-карты
                          # (docs/ADDRESS_MAP.md §4, post_bd_dfx.tcl M05 @ 0x46000000).
                          # xadc_temp.sv инстанцирован как u_xadc в
                          # xdma_ddr3_core_top.sv (FIX-5), но raw_temp/raw_vccint/
                          # raw_valid = 0 (BUG-031: XADC занят MIG, xadc_wiz не
                          # создаётся) — читаются 0°C/0V. Реальная температура —
                          # через MIG status (GPIO2 axi_gpio_0).
REG_TEMP = 0x00
REG_VCCINT = 0x04
REG_STATUS = 0x08

TEMP_SCALE = 503.975
VCCINT_SCALE = 3.0
ADC_RANGE = 4096.0
TEMP_OFFSET = 273.15

WARN_TEMP = 85.0
CRIT_TEMP = 100.0


class XadcMonitor:
    def __init__(self, device: str = "xdma0"):
        self._running = True
        try:
            self._dev = XdmaLinux(f"/dev/{device}")
        except XdmaError:
            self._dev = XdmaWindows()
        self._base = XADC_BASE

    def _read16(self, off: int) -> int:
        data = self._dev.read(self._base + off, 4)
        return int.from_bytes(data, "little") & 0xFFFF

    def _read_status(self) -> int:
        data = self._dev.read(self._base + REG_STATUS, 4)
        return int.from_bytes(data, "little") & 0x1

    def read_temperature(self) -> float:
        raw = self._read16(REG_TEMP)
        return raw * TEMP_SCALE / ADC_RANGE - TEMP_OFFSET

    def read_vccint(self) -> float:
        raw = self._read16(REG_VCCINT)
        return raw * VCCINT_SCALE / ADC_RANGE

    def stop(self):
        self._running = False

    @property
    def running(self) -> bool:
        return self._running

    def poll_loop(self, interval: float = 2.0, csv_path: str | None = None,
                  callback=None):
        fout = None
        writer = None
        if csv_path:
            fout = open(csv_path, "w", newline="", encoding="utf-8")
            writer = csv.writer(fout)
            writer.writerow(["timestamp", "temp_c", "vccint_v", "warning"])

        print(f"XADC Monitor  |  interval={interval}s  |  "
              f"ctrl+C to stop")
        print(f"{'Timestamp':<26}  {'Temp(C)':>8}  {'VCCINT(V)':>9}  Status")
        print("-" * 56)

        while self._running:
            ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:23]
            temp = self.read_temperature()
            vcc = self.read_vccint()
            valid = self._read_status()

            warn_str = ""
            if temp >= CRIT_TEMP:
                warn_str = "*** CRITICAL ***"
            elif temp >= WARN_TEMP:
                warn_str = "WARNING"

            line = f"{ts:<26}  {temp:>8.2f}  {vcc:>9.3f}  {warn_str}"
            print(line, flush=True)

            if writer:
                writer.writerow([ts, f"{temp:.2f}", f"{vcc:.3f}", warn_str])
                fout.flush()

            if callback:
                callback(temp, vcc, valid)

            try:
                time.sleep(interval)
            except KeyboardInterrupt:
                break

        if fout:
            fout.close()
        print("\nMonitor stopped.")


def main():
    parser = argparse.ArgumentParser(
        description="Мониторинг температуры/напряжения чипа через XADC.")
    parser.add_argument("--log", metavar="FILE", default=None,
                        help="путь к CSV-файлу лога")
    parser.add_argument("--interval", type=float, default=2.0,
                        help="интервал опроса в секундах (по умолч. 2)")
    parser.add_argument("--device", default="xdma0",
                        help="имя XDMA-устройства (по умолч. xdma0)")
    args = parser.parse_args()

    monitor = XadcMonitor(device=args.device)

    def sigint_handler(sig, frame):
        monitor.stop()

    signal.signal(signal.SIGINT, sigint_handler)

    try:
        monitor.poll_loop(interval=args.interval, csv_path=args.log)
    except XdmaError as e:
        print(f"Ошибка XDMA: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()