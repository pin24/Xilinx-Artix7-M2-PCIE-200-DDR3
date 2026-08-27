"""Генерация эталонных векторов для сверки Python-эмулятора с FPGA.

Сохраняет тестовые наборы в CSV: входные float32 (битами и значениями),
выход TFloat40 (40-бит), результат операций. Это эталон, с которым
аппаратное ядро будет сверяться на реальном железе.

Формат CSV (для каждой операции):
    op, a_f32_bits, b_f32_bits, result_tf_bits, result_f32

Запуск:  python gen_reference.py [num_random]
"""
from __future__ import annotations
import sys, os, csv, struct, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ternary.tfloat40 import TFloat
from ternary import arith


def f32_bits(x: float) -> int:
    return struct.unpack("I", struct.pack("f", x))[0]


def gen_cases(num_random: int = 200):
    fixed = [0.0, 1.0, -1.0, 3.0, -3.0, 0.5, -0.5, 0.3333333333,
             1.5, 2.0, 2.5, 0.1, -0.1, 100.0, -100.0, 0.001,
             1e-5, 1234.5678, -9876.5432, 42.0, -42.0]
    random.seed(12345)
    for _ in range(num_random):
        fixed.append(float(struct.unpack("f", struct.pack("f", random.uniform(-1000, 1000)))[0]))
    return fixed


def write_csv(filename, rows, header):
    with open(filename, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    print(f"Записано {len(rows)} строк в {filename}")


def main():
    vals = gen_cases()
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "reference")
    os.makedirs(out_dir, exist_ok=True)

    # 1) конвертация float32 -> TFloat40 (биты)
    conv = []
    for v in vals:
        t = TFloat.from_float(v)
        conv.append([f32_bits(v), v, t.to_bits(), t.to_float()])
    write_csv(os.path.join(out_dir, "conv_f32_to_tf40.csv"), conv,
              ["a_f32_bits", "a_f32", "tf_bits", "tf_f32"])

    # 2) бинарные операции
    for op, fn in [("add", arith.add), ("sub", arith.sub),
                   ("mul", arith.mul), ("div", arith.div)]:
        rows = []
        for a in vals:
            for b in vals:
                if op == "div" and b == 0.0:
                    continue
                ta, tb = TFloat.from_float(a), TFloat.from_float(b)
                try:
                    tr = fn(ta, tb)
                except Exception:
                    continue
                if tr.is_error():
                    continue
                rows.append([op, f32_bits(a), a, f32_bits(b), b,
                             tr.to_bits(), tr.to_float()])
        write_csv(os.path.join(out_dir, f"op_{op}.csv"), rows,
                  ["op", "a_f32_bits", "a_f32", "b_f32_bits", "b_f32",
                   "result_tf_bits", "result_f32"])

    print("Готово. Эталонные векторы в папке reference/")

    # 3) подпись для RTL
    print(f"Кол-во тестовых значений: {len(vals)}")


if __name__ == "__main__":
    main()
