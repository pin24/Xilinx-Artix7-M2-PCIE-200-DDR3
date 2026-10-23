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
import argparse, os, sys, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pytorch_layer"))

def bar(pct, width=20, filled="#", empty="-"):
    pct = max(0.0, min(100.0, pct))
    n = int(round(pct / 100.0 * width))
    return filled * n + empty * (width - n)

def yn(v, unk="n/a"):
    """bool -> 'да'/'нет'; None -> unk (регистр недоступен)."""
    if v is None:
        return unk
    return "да" if v else "нет"

def d32(cur, prev):
    """Разность 32-битных счётчиков OBS с учётом переполнения (wrap-around)."""
    return (cur - prev) & 0xFFFFFFFF

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
    ap.add_argument("--num-mac", type=int, default=None,
                    help="NUM_MAC прошивки; по умолч. (None) авто-детект из CAPS")
    ap.add_argument("--ddr-base", type=lambda s: int(s, 0), default=0x80000000)
    ap.add_argument("--dot", type=int, default=0, help="количество dot-задач на цикл для нагрузки")
    ap.add_argument("--interval", type=float, default=0.5, help="секунд между кадрами")
    ap.add_argument("--once", action="store_true",
                    help="один кадр и выход (не зацикливаться)")
    ap.add_argument("--clear", action="store_true",
                    help="обнулить накопленные счётчики OBS перед стартом (иначе показываются "
                         "кумулятивные значения с последнего clear)")
    ap.add_argument("--dev", default=None)
    ap.add_argument("--bench", type=int, default=0, metavar="MB",
                    help="непрерывный DMA-нагрузочный тест с блоком N МБ (write+read через h2c/c2h); "
                         "НАГРУЖАЕТ плату и показывает живую MB/s в реальном времени (0 = выкл). "
                         "Пример: --bench 8")
    ap.add_argument("--ddr-check", action="store_true",
                    help="быстрый readback-тест DDR3 (write+read+сверка 256 Б в стороне от "
                         "данных ядра) на старте; результат в карте платы")
    args = ap.parse_args(argv)

    if sys.platform.startswith("win"):
        from xdma_driver import XdmaWinUpstream as Backend
        base = args.dev or r"\\.\XDMA0dma"
    else:
        from xdma_driver import XdmaLinux as Backend
        base = args.dev or "/dev/xdma0"
    from xdma_driver import TdotCore, XdmaError

    dev = Backend(base=base)
    core = TdotCore(dev, num_mac=args.num_mac or 32, ddr_base=args.ddr_base)
    # Авто-детект NUM_MAC из CAPS (OBS 0x74): если --num-mac не задан — берём
    # из железа; если задан явно — предупреждаем при расхождении с CAPS.
    try:
        caps_nm = int(core.read_caps().get("num_mac") or 0)
    except Exception as e:
        caps_nm = 0
        print(f"  WARN: CAPS недоступны ({e}); NUM_MAC=16 (fallback)")
    if args.num_mac is None:
        args.num_mac = caps_nm or 16
        print(f"  NUM_MAC авто-детект из CAPS: {args.num_mac}")
    elif caps_nm and caps_nm != args.num_mac:
        print(f"  WARN: --num-mac={args.num_mac} != CAPS NUM_MAC={caps_nm}; "
              f"использую {caps_nm}")
        args.num_mac = caps_nm
    # (Реальная скорость линка GT/s из user-mode недоступна; показываем только
    # фактическую скорость передачи DMA MB/s (за кадр) — без бесплатной строки PCIe.)

    # ---- читалка регистров с защитой: недоступный регистр -> None (покажем n/a) ----
    def rr(off):
        try:
            return core._reg_r(off)
        except Exception:
            return None

    # ---- конфигурация ядра из CORE_PARAMS (0x64, compile-time, один раз) ----
    try:
        _cp = core._reg_r(0x64)            # {16'h0, ADDERS[7:0], NUM_MAC[7:0]}
        hw_num_mac = _cp & 0xFF
        hw_adders  = (_cp >> 8) & 0xFF
    except Exception:
        hw_num_mac = hw_adders = None
    try:
        regmap_v = int(core.read_caps().get("regmap_version") or 0)
    except Exception:
        regmap_v = None

    # ---- XADC (переиспользуем XadcMonitor из monitor_temp, НЕ дублируем) ----
    try:
        from monitor_temp import XadcMonitor
        xadc = XadcMonitor(dev=dev)
    except Exception:
        xadc = None

    one = 0x001000000000
    pairs = [one] * args.num_mac

    print("Подключено к плате... (Ctrl+C для выхода)")
    if args.clear:
        core.obs_clear()
        print("  OBS-счётчики обнулены (--clear).")
    time.sleep(0.3)

    # DDR3 readback-тест (опционально): write+read+сверка 256 Б в стороне от ядра.
    # Не трогает счётчики ядра (DMA-канал h2c/c2h, не AXI ядра).
    ddr_rd = None
    if args.ddr_check:
        try:
            _off = 0x00FF_0000                       # scratch, в стороне от данных ядра
            _buf = bytes((i & 255) for i in range(256))
            core.dev.write_dma(_off, _buf)
            ddr_rd = (core.dev.read_dma(_off, 256) == _buf)
        except Exception:
            ddr_rd = None
        st = {True: "OK", False: "MISMATCH", None: "ERR"}.get(ddr_rd, "ERR")
        print(f"  DDR3 readback (--ddr-check): {st}")

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
    prev_t = None
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
                # FIX 2026-10-20 (OBS/GO): legacy core.dot() uses the GO path, which
                # the HW scheduler blocks while sched_en=1 (go_accept gate) -> OBS
                # would stay 0. Ensure the legacy GO path is active for the load.
                try:
                    core.set_sched(False)
                except Exception:
                    pass
                # прогнать N задач для создания нагрузки (ядро/AXI-активность)
                for _ in range(args.dot):
                    core.dot(pairs, list(pairs), data_addr=0x0,
                             weights_addr=0x1000, result_addr=0x2000)
                    core.wait_done(timeout_ms=2000)

            cur = core.obs_read()  # живые счётчики (live)
            cyc = cur["cycles"] or 1
            cur_t = time.monotonic()
            dt_real = 1.0
            if prev is not None:
                dt_real = (cur_t - prev_t) if (prev_t is not None) else 1.0
                if dt_real <= 0.0:
                    dt_real = 1e-3
                dcyc = cur["cycles"] - prev["cycles"]   # CYCLES 64-бит: маска НЕ применяется
                dj = d32(cur["job"],  prev["job"])
                dar   = d32(cur["ar"],    prev["ar"])
                dbeat = d32(cur["beat"],  prev["beat"])
                dwr   = d32(cur["wr"],    prev["wr"])
                dfifo = d32(cur["fifo_full"], prev["fifo_full"])
                if dcyc <= 0:
                    dcyc = 1
                busy_p = 100.0 * d32(cur["busy"],    prev["busy"])    / dcyc
                mem_p  = 100.0 * d32(cur["mem"],     prev["mem"])     / dcyc
                load_p = 100.0 * d32(cur["load"],    prev["load"])    / dcyc
                comp_p = 100.0 * d32(cur["compute"], prev["compute"]) / dcyc
                ars_p   = 100.0 * d32(cur["ar_stall"], prev["ar_stall"]) / dcyc
                rwait_p = 100.0 * d32(cur["r_wait"], prev["r_wait"])  / dcyc
            else:
                busy_p = mem_p = load_p = comp_p = ars_p = rwait_p = 0.0
                dj = dar = dbeat = dwr = dfifo = 0

            # производные кадра (должны быть вычислены ДО карты платы, где они нужны)
            dt_safe = max(dt_real, 1e-9)             # защита: dt=0 не должен давать inf/деление на 0
            if dma_mb is not None:
                dmamb = dma_mb                       # реальная скорость переноса (--bench)
                bw_label = "DMA host (write+read)"
            else:
                dmamb = dbeat * 8 / dt_safe / 1e6    # по прочитанным словам (ΔBEAT)
                bw_label = "CORE RD (AXI, ядро из DDR3; не host-DMA)"
            job_s = (dj / dt_safe) if dj > 0 else 0.0

            # ---- КАРТА ПЛАТЫ: живые состояния подсистем (доступные регистры) ----
            # ping: среднее время чтения одного регистра (мкс) — «пинг платы».
            # time.monotonic() на Windows даёт ~мбс-гранулярность, а одно чтение ~6 мкс;
            # поэтому меряем perf_counter_ns по N чтениям.
            _t = time.perf_counter_ns()
            for _ in range(100):
                core._reg_r(0x64)
            reg_ns = (time.perf_counter_ns() - _t) / 100.0
            reg_us = reg_ns / 1000.0
            wptr = rr(0x44); rptr = rr(0x48)          # SCHED_WPTR/RPTR (10 бит, mod 1024)
            if wptr is not None and rptr is not None:
                occ = (wptr - rptr) & 0x3FF           # RING-1024: mod 1024
                occ_pct = 100.0 * occ / 1024.0
            else:
                occ = occ_pct = None
            st = rr(0x5C); done_cnt = rr(0x60)        # SCHED_STATUS / DONE_CNT
            sched_busy = bool(st & 1) if st is not None else None
            irq_pend   = bool(st & 2) if st is not None else None
            dp = rr(0xE4)                             # DP_CTRL: bit0 active, [31:16] n_units
            if dp is not None:
                dp_active = bool(dp & 1)
                dp_units  = (dp >> 16) & 0xFFFF
            else:
                dp_active = dp_units = None
            # XADC (через XadcMonitor; BUG-031: valid=0 когда XADC занят MIG)
            xt = xv = None; xa = None
            if xadc is not None:
                try:
                    xa = xadc._read_status()          # bit0: valid (BUG-031 -> 0)
                    if xa:
                        xt = xadc.read_temperature()
                        xv = xadc.read_vccint()
                        # плусibility-фильтр: неразведённый XADC (0xFF...) даёт абсурд
                        if not (-40.0 <= xt <= 150.0) or not (0.3 <= xv <= 2.5):
                            xa = None; xt = xv = None   # мусор — трактуем как n/a
                except Exception:
                    xa = None
            occ_s = ("n/a" if occ is None
                     else f"{occ}/1024 ({occ_pct:.1f}%)")
            _n = (lambda v: "n/a" if v is None else str(v))
            if xa is None or xt is None:
                xadc_s = ("n/a (XADC direct нерабочий — BUG-031: сенсор занят MIG/не разведён, "
                          "чтение даёт мусор; реальная temp через MIG-GPIO2, docs/ADDRESS_MAP.md §7)")
            elif xa == 0:
                xadc_s = "n/a (XADC INVALID статус=0 — BUG-031: XADC занят MIG)"
            else:
                xadc_s = f"{xt:.1f} C  /  VCCINT={xv:.3f} V"
            # AXI burst watchdogs (regs 0xF8/0xFC (word 0x62/0x63), added 2026-10-21)
            try:
                _rd_to = rr(0xF8); _wr_to = rr(0xFC)
                to_s = f"rd={_rd_to} wr={_wr_to}"
                if _rd_to or _wr_to:
                    to_s += "  ** TIMEOUT **"
            except Exception:
                to_s = "n/a (firmware без регистров 0xF8/0xFC)"

            # ---- DDR3-бюджет: окно 256 МБ (защита от переполнения) ----
            ddr_limit = 0x1000_0000
            ddr_base = 0x8000_0000
            _regs = [0x4C, 0x54, 0xE8, 0xEC, 0xF0]   # desc,comp,dp_data,dp_table,dp_mbox (полные AXI)
            _offs = []
            for _r in _regs:
                try:
                    _x = rr(_r)
                    if _x:
                        _o = (_x - ddr_base) & 0xFFFFFFFF
                        if _o < ddr_limit:
                            _offs.append(_o)
                except Exception:
                    pass
            ddr_used = (max(_offs) + 0x4000) if _offs else 0   # +16 КБ запас под последний регион
            ddr_used = min(ddr_used, ddr_limit)
            ddr_free = ddr_limit - ddr_used

            # ---- отрисовка кадра ----
            # dt_real вычислен выше (между двумя чтениями счётчиков prev_t->cur_t)
            s = (f"\x1b[2J\x1b[H"
                 f"  ============================================\n"
                 f"    tdot OBS console  (BUILD_ID=0x{core.read_build_id():08X}"
                 f"  /  build {args.num_mac} MAC)  [flat, live]   Ctrl+C — выход\n"
                 f"  ============================================\n"
                 f"  [ ФАЗЫ ]     за кадр, база {dt_real*1000:.0f} мс\n"
                 f"    BUSY      [{bar(busy_p)}] {busy_p:6.1f} %   JOB/s={job_s:8.1f}\n"
                 f"    MEM       [{bar(mem_p)}] {mem_p:6.1f} %\n"
                 f"    LOAD      [{bar(load_p)}] {load_p:6.1f} %\n"
                 f"    COMPUTE   [{bar(comp_p)}] {comp_p:6.1f} %\n"
                 f"    CYCLES    {cur['cycles']:>14,d}   (Δt кадра {dt_real*1000:.0f} мс)\n"
                 f"  --------------------------------------------\n"
                 f"  [ КОЛЬЦО / ПЛАНИРОВЩИК ]\n"
                 f"    RPTR={_n(rptr)}  WPTR={_n(wptr)}  occupy={occ_s}  "
                 f"done_cnt={_n(done_cnt)}\n"
                 f"    sched_busy={yn(sched_busy)}  irq_pend={yn(irq_pend)}\n"
                 f"  --------------------------------------------\n"
                 f"  [ DDR3 / AXI ]         Δ за кадр\n"
                 f"    AR=+{dar:,d}   BEAT=+{dbeat:,d}   WR=+{dwr:,d}   fifo_full=+{dfifo:,d}\n"
                 f"    AR_STALL={ars_p:.3f} %   R_WAIT={rwait_p:.3f} %\n"
                 f"    readback={'OK' if ddr_rd else ('MISMATCH' if ddr_rd is False else 'n/a')}    "
                 f"AXI timeout: {to_s}\n"
                 f"  --------------------------------------------\n"
                 f"  [ ПАМЯТЬ DDR3 ]      окно 256 МБ (защита от переполнения)\n"
                 f"    лимит={ddr_limit/1024/1024:.0f} МБ   резерв ядра(по базам)={ddr_used/1024/1024:.1f} МБ\n"
                 f"    свободно из бюджета={ddr_free/1024/1024:.1f} МБ ({100.0*ddr_free/ddr_limit:.0f} %)\n"
                 f"  --------------------------------------------\n"
                 f"  [ DEVICE_PROG ]\n"
                 f"    active={yn(dp_active)}  n_units={_n(dp_units)}\n"
                 f"  --------------------------------------------\n"
                 f"  [ XADC / СВЯЗЬ ]\n"
                 f"    XADC: {xadc_s}\n"
                 f"    backend={type(dev).__name__}   reg-ping={reg_us:.1f} мкс   "
                 f"REGMAP_v={_n(regmap_v)}\n"
                 f"  --------------------------------------------\n"
                 f"  [ АКТИВНОСТЬ ]         Δ за кадр\n"
                 f"    AR=+{dar:,d}  BEAT=+{dbeat:,d}  WR=+{dwr:,d}  JOB=+{dj:,d}  "
                 f"FIFO_FULL=+{dfifo:,d}\n"
                 f"    {bw_label} = {dmamb:8.1f} MB/s\n"
                 f"  --------------------------------------------\n"
                 f"  [ КУМУЛЯТИВНО ]        полные счётчики (сброс: --clear)\n"
                 f"    AR={cur['ar']:,d}  BEAT={cur['beat']:,d}  WR={cur['wr']:,d}  "
                 f"JOB={cur['job']:,d}  FIFO_FULL={cur['fifo_full']:,d}\n"
                 f"  ============================================\n")
            sys.stdout.write(s)
            sys.stdout.flush()
            prev = cur
            prev_t = cur_t
            if args.once:
                break
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nОстановлено.")
    except XdmaError as e:
        print(f"Ошибка: {e}")
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())