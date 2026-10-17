"""Сверка RTL-конвертера T2F (TFloat48 -> float32) с Python-эталоном.

Эталон = TFloat.from_bits(перевод в python-конвенцию).to_float() в float32.
Входные 48-бит слова подаются в конвенции ЯДРА [E:8][M:40]; для эталона
конвертируются в python big-endian: from_bits(((w&M)<<8)|((w>>40)&0xFF)).

Запуск:  python verify_rtl_t2f48.py [N]
"""
from __future__ import annotations
import sys, os, subprocess, struct, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw"))

from block.tfloat48 import TFloat, TFloatError

RTL = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(RTL, "sim")
XIL_BIN = "C:/AMDDesignTools/2025.2/Vivado/bin"

M_MASK = (1 << 40) - 1


def f32_bits(x):
    return struct.unpack("I", struct.pack("f", x))[0]


def kernel_to_py(w):
    return ((w & M_MASK) << 8) | ((w >> 40) & 0xFF)


def ref_to_float(w):
    """Эталон: float32 bits of TFloat.from_bits(kernel_word).to_float()."""
    t = TFloat.from_bits(kernel_to_py(w))
    return f32_bits(t.to_float())


def gen_random_words(n):
    random.seed(20261017)
    words = []
    # случайные 48-бит слова (почти всегда содержат ERR-триты + ненормированные M)
    for _ in range(n):
        words.append(random.getrandbits(48))
    # структурированные: норм. слова с валидным M и e на всей шкале экспонент
    from block.tfloat48 import _int_to_trits, _encode_exp
    from block import trits as T
    for e in range(-40, 41):
        for base in [3**18, 3**18 + 12345, (3**19 - 1000), 3**18 * 3 - 1]:
            mt = _int_to_trits(base, 20)
            w = ((T.pack(_encode_exp(e)) & 0xFF) << 40) | (T.pack(tuple(mt)) & M_MASK)
            words.append(w)
            # отрицательные M
            mt2 = tuple(-x for x in mt)
            w2 = ((T.pack(_encode_exp(e)) & 0xFF) << 40) | (T.pack(mt2) & M_MASK)
            words.append(w2)
    # M == 0 (ноль) на всех экспонентах
    for e in range(-40, 41):
        w = ((e & 0xFF) << 40)  # e просто как integer-поле; но нужен balanced-код
        from block.tfloat48 import _encode_exp
        from block import trits as T
        w = ((T.pack(_encode_exp(e)) & 0xFF) << 40) | 0
        words.append(w)
    return words


def gen_input(n):
    words = gen_random_words(n)
    os.makedirs(SIM, exist_ok=True)
    with open(os.path.join(SIM, "t2f48_in.hex"), "w") as f:
        for w in words:
            f.write(f"{w:012x}\n")
    with open(os.path.join(SIM, "t2f48_expected.hex"), "w") as f:
        for w in words:
            f.write(f"{ref_to_float(w):08x}\n", )
    print(f"Сгенерировано {len(words)} векторов T2F")


def run_sim():
    files = [
        os.path.join(RTL, "rtl", "tf48_pkg.sv"),
        os.path.join(RTL, "rtl", "tf48_to_f32.sv"),
        os.path.join(RTL, "tb", "tb_tf48_to_f32.sv"),
    ]
    xvlog = os.path.join(XIL_BIN, "xvlog.bat")
    xelab = os.path.join(XIL_BIN, "xelab.bat")
    xsim  = os.path.join(XIL_BIN, "xsim.bat")

    def run(cmd, cwd=None):
        r = subprocess.run(cmd, shell=True, cwd=cwd or RTL,
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("CMD FAIL:", cmd)
            print(r.stdout[-1500:])
            print(r.stderr[-1500:])
        return r

    for d in ["xsim.dir", "xsim.cmd", "xsim.log", "xelab.log", "xvlog.log"]:
        p = os.path.join(RTL, d)
        if os.path.isdir(p):
            import shutil; shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)

    run(f'"{xvlog}" -sv {" ".join(files)}')
    run(f'"{xelab}" tb_tf48_to_f32 -debug typical')
    run(f'"{xsim}" tb_tf48_to_f32 -runall')


def verify():
    exp_path = os.path.join(SIM, "t2f48_expected.hex")
    out_path = os.path.join(SIM, "t2f48_out.hex")
    if not os.path.exists(out_path):
        print("НЕТ выходного файла t2f48_out.hex - симуляция не выполнена")
        return False
    exp = [int(l.strip(), 16) for l in open(exp_path) if l.strip()]
    got = []
    with open(out_path) as f:
        for line in f:
            p = line.split()
            if len(p) == 2:
                got.append(int(p[1], 16))
    if len(exp) != len(got):
        print(f"ОШИБКА: expected {len(exp)}, got {len(got)}")
        return False
    bad = 0
    for i, (e, g) in enumerate(zip(exp, got)):
        if e != g:
            bad += 1
            if bad <= 20:
                print(f"  [{i}] exp={e:08x} got={g:08x}")
    if bad == 0:
        print(f"T2F48 PASS: {len(exp)} векторы бит-в-бит (0 mismatch)")
        return True
    else:
        print(f"T2F48 FAIL: несовпадений {bad}/{len(exp)}")
        return False


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    gen_input(n)
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()