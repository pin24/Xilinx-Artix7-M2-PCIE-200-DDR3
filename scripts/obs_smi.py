#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""obs_smi.py — консольный дашборд OBS-наблюдаемости tdot (в стиле nvidia-smi).

Обновляемый интерфейс: живые счётчики (НЕ теневые SNAP — те дают устаревшие
данные на длинных прогонах), прогресс-бары фаз, AXI-активность.

Использование:
  python scripts/obs_smi.py                     # просто мониторинг (live)
  python scripts/obs_smi.py --dot 16            # гнать dot-задачу в фоне нагрузки
  python scripts/obs_smi.py --interval 0.5
Требуется прошивка с OBS (BUILD_ID >= 2a1ea150).
"""
import argparse, sys, time

sys.path.insert(0, "pytorch_layer")

def bar(pct, width=20, filled="#", empty="-"):
    pct = max(0.0, min(100.0, pct))
    n = int(round(pct / 100.0 * width))
    return filled * n + empty * (width - n)

def main(argv=None):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    # Включить ANSI/Virtual Terminal на Windows (иначе \x1b[... печатается литералом)
    if sys.platform.startswith("win"):
        try:
            import ctypes
            k = ctypes.windll.kernel32
            h = k.GetStdHandle(-11)
            mode = ctypes.c_uint()
            if k.GetConsoleMode(h, ctypes.byref(mode)):
                k.SetConsoleMode(h, mode.value | 0x0004)  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
        except Exception:
            pass
    ap = argparse.ArgumentParser(description="tdot OBS console dashboard")
    ap.add_argument("--num-mac", type=int, default=16)
    ap.add_argument("--ddr-base", type=lambda s: int(s, 0), default=0x80000000)
    ap.add_argument("--dot", type=int, default=0, help="количество dot-задач на цикл для нагрузки")
    ap.add_argument("--interval", type=float, default=0.5, help="секунд между кадрами")
    ap.add_argument("--clear", action="store_true",
                    help="обнулить накопленные счётчики OBS перед стартом (иначе показываются "
                         "кумулятивные значения с последнего clear)")
    ap.add_argument("--dev", default=None)
    ap.add_argument("--bench", type=int, default=0, metavar="MB",
                    help="непрерывный DMA-нагрузочный тест с блоком N МБ (write+read через h2c/c2h); "
                         "НАГРУЖАЕТ плату и показывает живую MB/s в реальном времени (0 = выкл). "
                         "Пример: --bench 8")
    args = ap.parse_args(argv)

    if sys.platform.startswith("win"):
        from xdma_driver import XdmaWinUpstream as Backend
        base = args.dev or r"\\.\XDMA0dma"
    else:
        from xdma_driver import XdmaLinux as Backend
        base = args.dev or "/dev/xdma0"
    from xdma_driver import TdotCore, XdmaError

    dev = Backend(base=base)
    core = TdotCore(dev, num_mac=args.num_mac, ddr_base=args.ddr_base)
    # (Реальная скорость линка GT/s из user-mode недоступна; показываем только
    # фактическую скорость передачи DMA MB/s (за кадр) — без бесплатной строки PCIe.)

    one = 0x001000000000
    pairs = [one] * args.num_mac

    print("Подключено к плате... (Ctrl+C для выхода)")
    if args.clear:
        core.obs_clear()
        print("  OBS-счётчики обнулены (--clear).")
    time.sleep(0.3)

    # DMA-нагрузочный тест (опционально): блок N МБ write+read через h2c/c2h
    bench_nbytes = 0
    bench_buf = None
    if args.bench > 0:
        bench_nbytes = args.bench * (1 << 20)
        bench_buf = bytes((i & 255) for i in range(bench_nbytes))
        off = 0x01000000
        d = core.dev
        d.write_dma(off, bench_buf)                 # прогрев
        d.read_dma(off, bench_nbytes)
        print(f"  DMA-нагрузка запущена: блок {args.bench} МБ (write+read через плату)")

    prev = None
    try:
        while True:
            t_frame = time.monotonic()   # начало кадра (для реального времени)
            dma_mb = None                    # MB/s по факту переноса (для bench)
            if args.bench > 0:
                # DMA-нагрузка (непрерывный write+read блока N МБ через плату)
                tb = time.monotonic()
                d.write_dma(off, bench_buf)
                d.read_dma(off, bench_nbytes)
                dtb = time.monotonic() - tb
                if dtb <= 0.0:
                    dtb = 1e-6
                dma_mb = 2 * bench_nbytes / dtb / 1e6   # реальная скорость переноса
            elif args.dot > 0:
                # прогнать N задач для создания нагрузки (ядро/AXI-активность)
                for _ in range(args.dot):
                    core.dot(pairs, list(pairs), data_addr=0x0,
                             weights_addr=0x1000, result_addr=0x2000)
                    core.wait_done(timeout_ms=2000)

            cur = core.obs_read()  # живые счётчики (live)
            cyc = cur["cycles"] or 1
            if prev is not None:
                dcyc = cur["cycles"] - prev["cycles"]
                dj = cur["job"] - prev["job"]
                dar   = cur["ar"]          - prev["ar"]
                dbeat = cur["beat"]        - prev["beat"]
                dwr   = cur["wr"]          - prev["wr"]
                dfifo = cur["fifo_full"]   - prev["fifo_full"]
                if dcyc <= 0:
                    dcyc = 1
                busy_p = 100.0 * (cur["busy"] - prev["busy"]) / dcyc
                mem_p  = 100.0 * (cur["mem"]  - prev["mem"])  / dcyc
                load_p = 100.0 * (cur["load"] - prev["load"]) / dcyc
                comp_p = 100.0 * (cur["compute"] - prev["compute"]) / dcyc
                rwait_p = 100.0 * (cur["r_wait"] - prev["r_wait"]) / dcyc
            else:
                busy_p = mem_p = load_p = comp_p = rwait_p = 0.0
                dj = dar = dbeat = dwr = dfifo = 0

            # ---- отрисовка кадра ----
            dt_real = time.monotonic() - t_frame      # реальная длительность цикла кадра
            if dt_real <= 0.0:
                dt_real = 1e-6
            if dma_mb is not None:
                dmamb = dma_mb                       # реальная скорость переноса (--bench)
            else:
                dmamb = dbeat * 8 / dt_real / 1e6    # по прочитанным словам (ΔBEAT)
            job_s = (dj / dt_real) if dj > 0 else 0.0
            s = (f"\x1b[2J\x1b[H"
                 f"  tdot OBS console  "
                 f"(BUILD_ID=0x{core.read_build_id():08X}  /  build {args.num_mac} MAC)  "
                 f"[flat, live]   Ctrl+C для выхода\n"
                 f"  {('-'*56)}\n"
                 f"  CYCLES (такты)  {cur['cycles']:>14,d}   кадр {dt_real*1000:.0f} мс\n"
                 f"  ФАЗЫ (за кадр):\n"
                 f"  BUSY     (занятость) [{bar(busy_p)}] {busy_p:6.1f}%   JOB/s={job_s:8.1f}\n"
                 f"  MEM      (память)    [{bar(mem_p)}] {mem_p:6.1f}%\n"
                 f"  LOAD     (загрузка)  [{bar(load_p)}] {load_p:6.1f}%\n"
                 f"  COMPUTE  (вычисления) [{bar(comp_p)}] {comp_p:6.1f}%\n"
                 f"  {('-'*56)}\n"
                 f"  ТЕКУЩАЯ АКТИВНОСТЬ (Δ за кадр):\n"
                 f"  AR (чтение)=+{dar:,d}   BEAT (слова)=+{dbeat:,d}   "
                 f"WR (запись)=+{dwr:,d}   JOB (задачи)=+{dj:,d}\n"
                 f"  DMA (живая, реал. время) = {dmamb:8.1f} MB/s   "
                 f"AR_STALL (бэкпрешер)={rwait_p:.3f}%  FIFO_FULL (Δ)=+{dfifo:,d}\n"
                 f"  {('-'*56)}\n"
                 f"  КУМУЛЯТИВНО (с --clear): AR={cur['ar']:,d}  BEAT={cur['beat']:,d}  "
                 f"WR={cur['wr']:,d}  JOB={cur['job']:,d}  FIFO_FULL={cur['fifo_full']:,d}\n"
                 f"  {('-'*56)}\n")
            sys.stdout.write(s)
            sys.stdout.flush()
            prev = cur
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nОстановлено.")
    except XdmaError as e:
        print(f"Ошибка: {e}")
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())