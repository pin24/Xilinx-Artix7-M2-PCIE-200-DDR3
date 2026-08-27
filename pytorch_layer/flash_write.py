"""Загрузка битстрима в SPI-флешку через ICAP (заглушка).

На данный момент SPI-контроллер в FPGA не реализован.
Используйте JTAG или Vivado Hardware Manager для программирования флешки.

Usage:
    python flash_write.py path/to/bitstream.mcs [--device xdma0]
"""
from __future__ import annotations
import argparse
import sys


def main():
    parser = argparse.ArgumentParser(
        description="Запись битстрима в SPI Flash через PCIe (заглушка).")
    parser.add_argument("bitstream", help="путь к .mcs-файлу")
    parser.add_argument("--device", default="xdma0",
                        help="имя XDMA-устройства (по умолч. xdma0)")
    args = parser.parse_args()

    print(f"Flash write for: {args.bitstream}")
    print(f"Device: {args.device}")
    print()
    print("Flash write not yet implemented — "
          "use JTAG or Vivado Hardware Manager.")
    print()
    print("To program the SPI flash via Vivado:")
    print("  1. Open Vivado -> Open Hardware Manager")
    print("  2. Auto-connect to the M.2 board via JTAG cable")
    print("  3. Add Configuration Memory Device -> MT25QL128 (SPIx4)")
    print(f"  4. Program with: {args.bitstream}")
    sys.exit(1)


if __name__ == "__main__":
    main()