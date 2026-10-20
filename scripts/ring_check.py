#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ring_check.py — проверка глубины кольца планировщика на плате (2026-10-20).

Сценарий: на борту прошивка с кольцом D. Хостовый scheduler создаётся с заявленной
глубиной ring_depth. Если ring_depth <= D — плата прогоняет весть батч корректно.
Если ring_depth > D — аппаратный doorbell обрезается по фактической разрядности
(8/10 бит), движок застревает на части батча, wait() даёт таймаут -> значит кольцо
на борту меньше запрошенной.

Использование:
    python scripts/ring_check.py --depth 256     # проверить заявленную глубину
    python scripts/ring_check.py --depth 1024
    python scripts/ring_check.py --probe         # определить глубину (256..1024)
    python scripts/ring_check.py                 # как --probe
"""
from __future__ import annotations
import sys, os, time, argparse
import numpy as np

_RL = os.path.dirname(os.path.abspath(__file__))
for _p in (os.path.join(_RL, "..", "pytorch_layer"),
           os.path.join(_RL, "..", "ternary_sw")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from fpga_backend import FpgaBackend          # noqa: E402
from xdma_driver import XdmaError             # noqa: E402


def _probe_board():
    from test_dma_win import XdmaWinDma
    dev = XdmaWinDma(base=r"\\.\XDMA0dma")
    info = dev.probe_firmware()
    try:
        dev.close()
    except Exception:
        pass
    return info


def test_depth(depth: int, num_mac: int, batch: int):
    """Прогнать батч через ring заданной глубины; вернуть (ok, tasks/s, err)."""
    print(f"  -> ring_depth={depth}, batch={batch} (n={num_mac})", flush=True)
    fb = FpgaBackend(mode="fpga", n=num_mac, num_mac=num_mac, ring_depth=depth)
    rng = np.random.default_rng(int(depth))
    a = rng.uniform(-1, 1, (batch, num_mac)).astype(np.float32)
    b = rng.uniform(-1, 1, (batch, num_mac)).astype(np.float32)
    t0 = time.monotonic()
    try:
        r = fb.run_dot(a, b)
        dt = time.monotonic() - t0
    except XdmaError as e:
        return False, 0.0, f"XOOT/XdmaError: {e}"
    rc = FpgaBackend(mode="cpu", n=num_mac).run_dot(a, b)
    d = np.abs(r - rc).max()
    ok = d < 1e-3
    if not ok:
        return False, batch / dt, f"mismatch vs cpu={d:.2e}"
    return True, batch / dt, None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--depth", type=int, default=0,
                    help="проверить конкретную глубину (0 = авто-детект)")
    ap.add_argument("--probe", action="store_true",
                    help="определить глубину перебором 256/512/1024")
    ap.add_argument("--batch", type=int, default=0,
                    help="размер батча (0 = depth-6)")
    ap.add_argument("--n", type=int, default=0,
                    help="длина dot (0 = автодетект из прошивки)")
    args = ap.parse_args()

    info = _probe_board()
    print("FIRMWARE:", {k: info.get(k) for k in ("NUM_MAC", "ADDERS", "CORE_PARAMS")})
    num_mac = args.n if args.n > 0 else info.get("NUM_MAC", 32)

    candidates = [args.depth] if args.depth > 0 else [256, 512, 1024]
    found = None
    for d in candidates:
        b = args.batch if args.batch > 0 else max(d - 6, 1)
        ok, speed, err = test_depth(d, num_mac, b)
        if ok:
            print(f"    OK  : depth={d} верна, {speed:.0f} задач/с")
            found = d
            if not args.probe:
                break
        else:
            print(f"    FAIL: depth={d} недоступна ({err})")
            if not args.probe:
                break
    print(f"=== ИТОГ: фактическое кольцо на борту = {found if found else 'не определено'} "
          f"(NUM_MAC={num_mac}) ===")


if __name__ == "__main__":
    main()