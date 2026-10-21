#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""device_prog_run.py — консольный запуск программы device_prog на плате.

Заливает в DDR3 данные и 32-байтную таблицу юнитов, программирует регистры
программного режима (DP_CTRL/DP_DATA_BASE/DP_TABLE_BASE/DP_MBOX_BASE, 0xE4..0xF0),
дёргает GO и ждёт completion-mailbox — ядро само разворачивает программу в
последовательность dot-задач поверх кольца tdot (см. rtl/integration/device_prog.sv
и pytorch_layer/xdma_driver.py::DeviceProgRunner).

ВАЖНО (DEVPROG_EN): программный режим активируется ТОЛЬКО если прошивка собрана
с DEVPROG_EN=1 (scripts/build_flat.tcl, generic DEVPROG_EN=1). На текущей
DEVPROG_EN=0 прошивке регистры 0xE4..0xF0 ИНЕРТНЫ: они читаются и пишутся, но
device_prog отключён, mailbox никогда не пишется -> скрипт честно предупреждает
и возвращает понятную ошибку (см. --check-only ниже).

Формат таблицы юнитов (32 Б/юнит, LE, device_prog.sv):
  +0x00 W0  w_addr[63:0]      полный AXI-адрес базового веса слоя
  +0x08 W1  out_addr[63:0]    полный AXI-адрес выхода слоя
  +0x10 W2  {n_in[15:0], b_addr[47:0]}   входов + базовый адрес смещения
  +0x18 W3  n_out[15:0] | pass<<16 | flags{relu,b_en,src}<<32 | tag<<40
ЭТО НЕ формат device_isa.bits() (у того другой компоновщик) — таблицу готовит
пользователь под формат device_prog.sv.

Использование:
    python scripts/device_prog_run.py --data-file d.bin --table-file t.bin \
        --n-units 2 --out 0xA0_0000 --out-len 64 --out-file res.bin
    python scripts/device_prog_run.py ... --check-only   # только проверка режима
"""
from __future__ import annotations
import os
import sys
import argparse

_RL = os.path.dirname(os.path.abspath(__file__))
for _p in (os.path.join(_RL, "..", "pytorch_layer"),):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from xdma_driver import XdmaError, DeviceProgRunner, REG_BASE  # noqa: E402


def _open_device(dev: str | None):
    """Открыть плату: XdmaWinDma (Windows) или XdmaLinux."""
    if sys.platform.startswith("win"):
        from test_dma_win import XdmaWinDma
        return XdmaWinDma(base=dev or r"\\.\XDMA0dma")
    from xdma_driver import XdmaLinux
    return XdmaLinux(base=dev or "/dev/xdma0")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-file", default=None,
                    help="бинарный файл входных данных (сырые байты, DDR3-смещения сам скрипт)")
    ap.add_argument("--table-file", default=None,
                    help="бинарный файл таблицы юнитов (32 Б/юнит, формат device_prog.sv)")
    ap.add_argument("--out", type=lambda s: int(s, 0), default=None,
                    help="DDR3-смещение результата (куда ядро пишет выходы)")
    ap.add_argument("--out-len", type=lambda s: int(s, 0), default=None,
                    help="сколько байт результата прочитать")
    ap.add_argument("--n-units", type=lambda s: int(s, 0), default=None,
                    help="число 32-байтных юнитов в --table-file")
    ap.add_argument("--num-mac", type=int, default=32,
                    help="NUM_MAC прошивки (default 32)")
    ap.add_argument("--dev", default=None, help="устройство (по умолч. авто)")
    ap.add_argument("--mbox-off", type=lambda s: int(s, 0), default=0x0012_0000,
                    help="DDR3-смещение completion-mailbox (default 0x120000)")
    ap.add_argument("--data-base", type=lambda s: int(s, 0), default=None,
                    help="DDR3-смещение области данных (default: свободный выбор)")
    ap.add_argument("--table-base", type=lambda s: int(s, 0), default=None,
                    help="DDR3-смещение таблицы юнитов (default: свободный выбор)")
    ap.add_argument("--timeout-ms", type=float, default=5000.0,
                    help="таймаут ожидания mailbox, мс (default 5000)")
    ap.add_argument("--out-file", default=None,
                    help="опц.: сохранить результат (raw-байты) в файл")
    ap.add_argument("--check-only", action="store_true",
                    help="только проверить, что плата в программном режиме "
                         "(читает DP_CTRL/CORE_PARAMS), ничего не запускать")
    args = ap.parse_args(argv)

    if not args.check_only:
        missing = [n for n, v in (("--data-file", args.data_file),
                                  ("--table-file", args.table_file),
                                  ("--out", args.out),
                                  ("--out-len", args.out_len),
                                  ("--n-units", args.n_units)) if v is None]
        if missing:
            ap.error("обязательные аргументы (кроме --check-only): " + ", ".join(missing))

    try:
        dev = _open_device(args.dev)
    except Exception as e:  # noqa: BLE001
        print(f"ERROR: не могу открыть устройство: {e}")
        print("  — драйвер установлен? плата видна? (XDMA0dma на Windows / /dev/xdma0)")
        return 1

    try:
        runner = DeviceProgRunner(dev, num_mac=args.num_mac)

        # ---- 0. Диагностика режима ----
        # DP_CTRL (0xE4) читается всегда; при DEVPROG_EN=0 программный режим
        # не «вооружается» (dprog_active всегда 0), а отдельного бита DEVPROG_EN
        # в CORE_PARAMS нет -> не можем подтвердить режим; только предупреждаем.
        try:
            st = runner.state()
        except XdmaError as e:
            print(f"WARNING: не удалось прочитать DP_CTRL (0xE4): {e}")
            st = None
        if st is not None:
            print(f"DP_CTRL (readback): active={st['active']} n_units={st['n_units']}")
        try:
            cp = dev.read(REG_BASE + 0x64, 4)
            num_mac = cp[0] & 0xFF
            adders = cp[1] & 0x0F
            print(f"CORE_PARAMS (0x64): NUM_MAC={num_mac} ADDERS={adders}")
        except Exception:  # noqa: BLE001
            print("WARNING: не удалось прочитать CORE_PARAMS (0x64)")
        print("WARNING: бит DEVPROG_EN не экспонируется в регистрах; "
              "программный режим активен только если прошивка собрана с "
              "DEVPROG_EN=1 (build_flat.tcl). На DEVPROG_EN=0 регистры 0xE4..0xF0 "
              "инертны — запуск завершится таймаутом mailbox.")

        if args.check_only:
            print("check-only: режим проверен (DEVPROG_EN нельзя подтвердить).")
            return 0

        # ---- 1. Чтение входных файлов ----
        try:
            with open(args.data_file, "rb") as f:
                data_bytes = f.read()
            with open(args.table_file, "rb") as f:
                table_bytes = f.read()
        except OSError as e:
            print(f"ERROR: не удалось прочитать файл: {e}")
            return 2
        if not data_bytes:
            print("ERROR: пустой --data-file")
            return 2
        if len(table_bytes) != args.n_units * 32:
            print(f"ERROR: --table-file {len(table_bytes)} Б != "
                  f"--n-units*32 = {args.n_units * 32} Б")
            return 2

        # ---- 2. Запуск программы ----
        print(f"запуск: n_units={args.n_units}, data={len(data_bytes)} Б, "
              f"table={len(table_bytes)} Б, out=0x{args.out:X} {args.out_len} Б ...")
        try:
            res = runner.run(data_bytes, table_bytes, args.n_units,
                             args.out, args.out_len,
                             timeout_ms=args.timeout_ms, mbox_off=args.mbox_off,
                             data_base=args.data_base, table_base=args.table_base)
        except XdmaError as e:
            msg = str(e)
            if "таймаут" in msg.lower() or "mailbox" in msg.lower():
                print("ERROR: плата не ответила completion-mailbox — прошивка "
                      "скорее всего собрана с DEVPROG_EN=0 (регистры 0xE4..0xF0 "
                      "инертны, device_prog отключён). Пересоберите прошивку с "
                      "DEVPROG_EN=1 (scripts/build_flat.tcl DEVPROG_EN=1).")
            else:
                print(f"ERROR: {msg}")
            return 3

        # ---- 3. Вывод результата ----
        print(f"результат: {len(res)} Б (raw)")
        if args.out_file:
            with open(args.out_file, "wb") as f:
                f.write(res)
            print(f"сохранено: {args.out_file}")
        else:
            n = min(len(res), 128)
            print("hex (первые %d Б): %s" % (n, res[:n].hex()))
        return 0
    finally:
        try:
            dev.close()
        except Exception:  # noqa: BLE001
            pass


if __name__ == "__main__":
    sys.exit(main())