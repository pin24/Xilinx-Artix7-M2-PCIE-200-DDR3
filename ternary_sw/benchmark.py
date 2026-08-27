"""Benchmark: производительность dot-произведений.

Сравнение:
  1. numpy float32 (эталон CPU)
  2. Python-эмулятор троичной FP (TFloat40): конвертация + mul/add
  3. Теоретический FPGA-конвейер (N MAC, частота f)

Запуск:  python benchmark.py [размер_ternary]
"""
from __future__ import annotations
import sys, os, time, random, struct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

if sys.stdout and hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

import numpy as np
from ternary import tfloat40 as tf
from ternary import arith
from ternary.tfloat40 import TFloat

NUMPY_SIZES = [1_000_000, 10_000_000]
TERN_SIZE_DEFAULT = 5000
REPEATS = 5

N_MAC = 64
FPGA_FREQS_MHZ = [125.0, 250.0]

SEP = "-" * 66


def to_f32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


def median_time(fn, repeats=REPEATS):
    times = []
    for _ in range(repeats):
        t0 = time.perf_counter()
        fn()
        t1 = time.perf_counter()
        times.append(t1 - t0)
    times.sort()
    return times[len(times) // 2]


def gflops(n, seconds):
    if seconds <= 0:
        return float("inf")
    return 2.0 * n / seconds / 1e9


def bench_numpy(n):
    rng = np.random.RandomState(12345)
    a = rng.randn(n).astype(np.float32)
    b = rng.randn(n).astype(np.float32)
    _ = np.dot(a, b)
    t = median_time(lambda: np.dot(a, b))
    return t, gflops(n, t)


def conv_ternary(arr):
    return [TFloat.from_float(to_f32(float(v))) for v in arr]


def bench_ternary(n):
    rng = random.Random(7)
    avals = [to_f32(rng.uniform(-10.0, 10.0)) for _ in range(n)]
    bvals = [to_f32(rng.uniform(-10.0, 10.0)) for _ in range(n)]

    t_conv0 = time.perf_counter()
    ta = conv_ternary(avals)
    tb = conv_ternary(bvals)
    t_conv1 = time.perf_counter()
    t_conv = (t_conv1 - t_conv0) / 2.0

    def dot():
        acc = TFloat.from_float(0.0)
        for x, y in zip(ta, tb):
            acc = arith.add(acc, arith.mul(x, y))
        return acc

    t_dot = median_time(dot)
    return t_conv, t_dot, gflops(n, t_dot)


def fpga_time(n, f_hz):
    return n / (N_MAC * f_hz)


def fpga_gflops(f_hz):
    return 2.0 * N_MAC * f_hz / 1e9


def fmt_sec(s):
    if s >= 1.0:
        return f"{s:9.3f} s"
    if s >= 1e-3:
        return f"{s*1e3:8.2f} ms"
    if s >= 1e-6:
        return f"{s*1e6:8.2f} us"
    return f"{s*1e9:8.2f} ns"


def fmt_gf(g):
    if g >= 1e3:
        return f"{g/1e3:9.2f} T"
    if g >= 1.0:
        return f"{g:9.3f}"
    if g >= 1e-3:
        return f"{g*1e3:8.2f} m"
    if g >= 1e-6:
        return f"{g*1e6:8.2f} u"
    return f"{g:9.2e}"


def fmt_speed(x):
    return f"{x:10.2f}x"


def main():
    tern_size = TERN_SIZE_DEFAULT
    if len(sys.argv) > 1:
        try:
            tern_size = int(sys.argv[1])
        except ValueError:
            print(f"Неверный размер троичного теста: {sys.argv[1]}")
            sys.exit(1)

    print("=" * 66)
    print("  BENCHMARK: dot-произведение  |  TFloat40 vs numpy vs FPGA")
    print("=" * 66)
    print(f"  numpy      : float32, np.dot, размеры {NUMPY_SIZES[0]:,} и {NUMPY_SIZES[1]:,}")
    print(f"  ternary py : TFloat40, чистая арифметика Python, размер {tern_size:,}")
    print(f"  FPGA       : N={N_MAC} MAC, частоты {[int(f) for f in FPGA_FREQS_MHZ]} МГц")
    print(f"  повторений : {REPEATS} (медиана)")
    print(SEP)

    print("\n[1] numpy float32 (эталон CPU)")
    numpy_rows = []
    for n in NUMPY_SIZES:
        t, gf = bench_numpy(n)
        numpy_rows.append((n, t, gf))
        print(f"  n = {n:>12,}   время = {fmt_sec(t)}   скорость = {fmt_gf(gf)} GFLOP/s")

    print("\n[2] Python-эмулятор троичной FP (TFloat40)")
    t_conv, t_dot, gf_py_dot = bench_ternary(tern_size)
    print(f"  n = {tern_size:>12,}   конвертация f32->TFloat: {fmt_sec(t_conv)} (на весь массив)")
    print(f"  n = {tern_size:>12,}   dot (mul+add)           : {fmt_sec(t_dot)}")
    print(f"  скорость dot (без конвертации)  = {fmt_gf(gf_py_dot)} GFLOP/s")
    t_py_all = t_dot + 2 * t_conv
    gf_py_all = gflops(tern_size, t_py_all)
    print(f"  скорость с учётом конвертации   = {fmt_gf(gf_py_all)} GFLOP/s")
    if numpy_rows:
        ref = numpy_rows[0][2]
        print(f"  медленнее numpy (n=1e6) в {ref/gf_py_all:,.0f} раз (с конвертацией), "
              f"в {ref/gf_py_dot:,.0f} раз (чистая арифметика)")

    print("\n[3] Теоретический FPGA-конвейер")
    print(f"  Формула: пропускная = N_MAC * f (MAC/s), GFLOP/s = N_MAC * f * 2 / 1e9")
    fpga_rows = []
    for f_mhz in FPGA_FREQS_MHZ:
        gf_fpga = fpga_gflops(f_mhz * 1e6)
        fpga_rows.append((f_mhz, gf_fpga))
        print(f"  f = {f_mhz:5.0f} МГц  ->  {gf_fpga:8.3f} GFLOP/s   (N={N_MAC} параллельных MAC)")

    print("\n[4] СВОДНАЯ ТАБЛИЦА: время на задачу и ускорение относительно numpy")
    header = (f"  {'Метод':<26}{'Размер':>13}{'Время':>14}{'GFLOP/s':>14}{'Ускор.':>12}")
    print(header)
    print(SEP)

    n0, t0, gf0 = numpy_rows[0]
    print(f"  {'numpy float32':<26}{n0:>13,}{fmt_sec(t0):>14}{fmt_gf(gf0):>14}{'1.00x':>12}")

    if len(numpy_rows) > 1:
        n1, t1, gf1 = numpy_rows[1]
        print(f"  {'numpy float32 (больш.)':<26}{n1:>13,}{fmt_sec(t1):>14}{fmt_gf(gf1):>14}{fmt_speed(gf1/gf0):>12}")

    print(f"  {'ternary python (dot)':<26}{tern_size:>13,}{fmt_sec(t_dot):>14}{fmt_gf(gf_py_dot):>14}{fmt_speed(gf_py_dot/gf0):>12}")
    print(f"  {'ternary python (всё)':<26}{tern_size:>13,}{fmt_sec(t_py_all):>14}{fmt_gf(gf_py_all):>14}{fmt_speed(gf_py_all/gf0):>12}")

    for f_mhz, gf_fpga in fpga_rows:
        t_task_1e6 = fpga_time(1_000_000, f_mhz * 1e6)
        t_task_t = fpga_time(tern_size, f_mhz * 1e6)
        print(f"  {'FPGA ' + str(int(f_mhz)) + ' МГц (1e6 пар)':<26}{1_000_000:>13,}{fmt_sec(t_task_1e6):>14}{fmt_gf(gf_fpga):>14}{fmt_speed(gf_fpga/gf0):>12}")
        print(f"  {'  ускорение vs Python (всё)':<26}{tern_size:>13,}{fmt_sec(t_task_t):>14}{'':>14}{fmt_speed(t_py_all/t_task_t):>12}")

    print(SEP)
    print("\nВЫВОД:")
    print(f"  - numpy float32 на CPU:  ~{gf0:.2f} GFLOP/s")
    if len(numpy_rows) > 1:
        print(f"  - numpy на большом размере: ~{gf1:.2f} GFLOP/s")
    print(f"  - Python-эмулятор троичной FP: ~{gf_py_dot:.4f} GFLOP/s (чистая арифметика),")
    print(f"      с конвертацией ~{gf_py_all:.4f} GFLOP/s — в {gf0/max(gf_py_all,1e-12):,.0f} раз медленнее numpy.")
    print(f"      Это ожидаемо: каждый MAC - десятки операций интерпретатора Python.")
    for f_mhz, gf_fpga in fpga_rows:
        print(f"  - FPGA ({int(f_mhz)} МГц, {N_MAC} MAC): теоретически {gf_fpga:.1f} GFLOP/s — "
              f"в {gf_fpga/gf_py_all:,.0f} раз быстрее Python-эмулятора, в {gf_fpga/gf0:.1f} раз быстрее numpy.")


if __name__ == "__main__":
    main()
