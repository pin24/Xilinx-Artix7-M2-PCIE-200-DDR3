#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================================
# monitor_obs.py — мониторинг OBS-наблюдаемости ядра tdot через PCIe.
#
# Источник данных: rtl/integration/tdot_axi4.sv (OBS, main-карта 0x6C+)
# и pytorch_layer/xdma_driver.py (TdotCore.obs_*).
#
# Выводит:
#   * BUILD_ID / CAPS (конфигурация битстрима), REGMAP-версия;
#   * фазы ядра в % кадра (BUSY/MEM/LOAD/COMPUTE от ΔCYCLES кадра);
#   * AXI-активность (ΔAR/ΔBEAT/ΔWR) и задержки (AR_STALL%, R_WAIT%);
#   * ΔJOB, JOB/s, среднее время задачи по ΔCYCLES (такт = 1/частоты).
#
# ВАЖНО (фикс 2026-10-20): проценты фаз считаются от ΔCYCLES кадра (base → cur),
# а НЕ от абсолютного CYCLES — он free-running и obs_clear() его не обнуляет,
# поэтому при долгом аптайме деление на абсолют давало ~0%.
#   * "--once": один кадр; "--loop": периодический опрос (по умолчанию).
#   * "--dot n": прогнать n-парный dot перед каждым кадром (нагрузка).
#
# Использование:
#   python scripts/monitor_obs.py --num-mac 16 --dot 8 --interval 1.0
#   python scripts/monitor_obs.py --once --num-mac 16
#
# Требуется прошивка с OBS (BUILD_ID>=2a1ea150, 16/4 или 32/16).
# ============================================================================
import argparse
import sys
import time


def main(argv=None):
    ap = argparse.ArgumentParser(description="Monitor tdot OBS counters over PCIe")
    ap.add_argument("--num-mac", type=int, default=16, help="NUM_MAC прошивки (16 или 32)")
    ap.add_argument("--ddr-base", type=lambda s: int(s, 0), default=0x80000000,
                    help="DDR3 база (для dot-адресов)")
    ap.add_argument("--dot", type=int, default=0,
                    help="число пар для dot перед каждым кадром (0 = не гонять)")
    ap.add_argument("--interval", type=float, default=1.0, help="сек между кадрами")
    ap.add_argument("--freq", type=float, default=125.0, help="частота ядра, МГц (для времени задачи)")
    ap.add_argument("--loop", dest="loop", action="store_true", default=True,
                    help="периодический опрос (по умолч.)")
    ap.add_argument("--once", dest="loop", action="store_false",
                    help="один кадр и выход")
    ap.add_argument("--dev", default=None, help="XDMA-устройство (по умолч. авто)")
    args = ap.parse_args(argv)

    try:
        sys.path.insert(0, "pytorch_layer")
        # Бэкенды: XdmaWinUpstream — драйвер XDMA_DMA (узлы \\.\XDMA0dma\user,
        # control, h2c/c2h) на Windows; XdmaLinux — /dev/xdma* на Linux.
        if sys.platform.startswith("win"):
            from xdma_driver import XdmaWinUpstream as _Backend
        else:
            from xdma_driver import XdmaLinux as _Backend
        from xdma_driver import XdmaDevice, XdmaError, TdotCore
    except Exception as e:
        print(f"ERROR: не удалось импортировать xdma_driver: {e}")
        return 2

    try:
        base = args.dev if args.dev else (r"\\.\XDMA0dma" if sys.platform.startswith("win")
                                          else "/dev/xdma0")
        dev = _Backend(base=base)
        core = TdotCore(dev, num_mac=args.num_mac, ddr_base=args.ddr_base)
    except Exception as e:
        print(f"ERROR: не могу открыть устройство: {e}")
        print("  — драйвер установлен? плата видна? прошит бит с OBS?")
        return 1

    # Проверка MAGIC (совместимость host-контракта)
    try:
        magic = core._reg_r(0x68)
    except Exception as e:
        magic = 0
    if magic != 0x54444F54:
        print(f"WARNING: MAGIC=0x{magic:08X} (ожидается 'TDOT'). Либо прошивка без OBS, "
              f"либо не тот драйвер/узел.")
    else:
        print(f"OK: tdot признан (MAGIC='TDOT').")

    bid = core.read_build_id()
    caps = core.read_caps()
    # REGRESS-RESTORE 2026-10-20 (BUG-065, аудит-VS §2.2): WARN "CAPS NUM_MAC !=
    # --num-mac" потерян в мерже 022ff7a (был в 7748803) — CAPS печатался, но
    # расхождение с флагом молча не проверялось.
    caps_mac = (caps or {}).get("num_mac")
    if caps_mac and caps_mac != args.num_mac:
        print(f"WARNING: CAPS NUM_MAC={caps_mac} != --num-mac={args.num_mac}; "
              f"арифметика AR/BEAT на задачу может отличаться от ожидаемой")
    print(f"BUILD_ID = 0x{bid:08X}  CAPS = {caps}\n")

    tick_ns = 1e9 / (args.freq * 1e6)   # нс на такт ядра

    def snapshot():
        core.obs_snap()
        return core.obs_read_shadow()

    def delta(cur, base):
        """Прирост счётчиков кадра; <0 (после obs_clear) клампим в 0."""
        d = {}
        for k in ("busy", "mem", "load", "compute", "ar", "beat",
                  "ar_stall", "r_wait", "wr", "job", "fifo_full"):
            d[k] = max(0, cur[k] - base[k])
        d["cycles"] = max(1, cur["cycles"] - base["cycles"])
        return d

    base = snapshot()          # база кадра (до нагрузки / предыдущий кадр)
    base_t = time.monotonic()
    first = True
    try:
        while True:
            if not first:
                time.sleep(args.interval)
            if first and args.loop:
                print(f"--- мониторинг (обновление каждые {args.interval} c; Ctrl+C — выход) ---")
            first = False

            # загрузка движка (опционально)
            if args.dot > 0:
                core.obs_clear()
                # пример: псевдо-данные 1.0 пары (TF48_ONE); dot-адреса переиспользуют DDR3
                one = 0x001000000000  # TFloat48 1.0
                pairs = [one] * args.dot
                core.dot(pairs, list(pairs),
                         data_addr=0x0, weights_addr=0x1000, result_addr=0x2000)
                core.wait_done(timeout_ms=6000)

            cur = snapshot()
            d = delta(cur, base)
            dt_real = time.monotonic() - base_t
            dcyc = d["cycles"]

            busy_p  = 100.0 * d["busy"]      / dcyc
            mem_p   = 100.0 * d["mem"]       / dcyc
            load_p  = 100.0 * d["load"]      / dcyc
            comp_p  = 100.0 * d["compute"]   / dcyc
            ars_p   = 100.0 * d["ar_stall"]  / dcyc
            rwait_p = 100.0 * d["r_wait"]    / dcyc
            job_s   = d["job"] / dt_real if dt_real > 0 else 0.0
            avg_task_us = (d["job"] and (dcyc * tick_ns / d["job"] / 1000.0)) or 0.0

            line = (
                f"ΔCYC={dcyc:>10}  "
                f"BUSY%={busy_p:5.1f}  MEM%={mem_p:5.1f}  LOAD%={load_p:5.1f}  "
                f"COMPUTE%={comp_p:5.1f}  "
                f"ΔAR={d['ar']:<5} ΔBEAT={d['beat']:<6} "
                f"AR_STALL%={ars_p:5.2f} R_WAIT%={rwait_p:5.2f} "
                f"ΔWR={d['wr']:<4} ΔJOB={d['job']:<4} "
                f"JOB/s={job_s:7.1f} task_avg={avg_task_us:7.1f}us "
                f"FIFO_FULL(Δ)={d['fifo_full']}"
            )
            print(line, flush=True)
            base, base_t = cur, time.monotonic()
            if not args.loop:
                break
    except KeyboardInterrupt:
        print("\n(stop)")
        return 0


if __name__ == "__main__":
    sys.exit(main())