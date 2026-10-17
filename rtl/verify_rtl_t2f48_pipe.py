"""Сверка конвейерного tf48_to_f32_pipe с комбинационным tf48_to_f32 (бит-в-бит).

Генерирует те же входные 48-бит слова, что verify_rtl_t2f48.py; запускает
tb_t2f48_pipe_comp.sv. Дополнительно привязывает к Python-эталону ref_to_float.

Запуск:  python verify_rtl_t2f48_pipe.py [N]
"""
from __future__ import annotations
import sys, os, subprocess, struct, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ternary_sw"))

from block.tfloat48 import TFloat

RTL = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(RTL, "sim")
XIL_BIN = "C:/AMDDesignTools/2025.2/Vivado/bin"

M_MASK = (1 << 40) - 1


def f32_bits(x):
    return struct.unpack("I", struct.pack("f", x))[0]


def kernel_to_py(w):
    return ((w & M_MASK) << 8) | ((w >> 40) & 0xFF)


def ref_to_float(w):
    t = TFloat.from_bits(kernel_to_py(w))
    return f32_bits(t.to_float())


def gen_random_words(n):
    random.seed(20261017)
    words = []
    for _ in range(n):
        words.append(random.getrandbits(48))
    from block.tfloat48 import _int_to_trits, _encode_exp
    from block import trits as T
    for e in range(-40, 41):
        for base in [3**18, 3**18 + 12345, (3**19 - 1000), 3**18 * 3 - 1]:
            mt = _int_to_trits(base, 20)
            w = ((T.pack(_encode_exp(e)) & 0xFF) << 40) | (T.pack(tuple(mt)) & M_MASK)
            words.append(w)
            mt2 = tuple(-x for x in mt)
            w2 = ((T.pack(_encode_exp(e)) & 0xFF) << 40) | (T.pack(mt2) & M_MASK)
            words.append(w2)
    for e in range(-40, 41):
        from block.tfloat48 import _encode_exp
        from block import trits as T
        w = ((T.pack(_encode_exp(e)) & 0xFF) << 40) | 0
        words.append(w)
    return words


def gen_input(n):
    words = gen_random_words(n)
    os.makedirs(SIM, exist_ok=True)
    with open(os.path.join(SIM, "t2f48p_in.hex"), "w") as f:
        for w in words:
            f.write(f"{w:012x}\n")
    return words


def run_sim():
    files = [
        os.path.join(RTL, "rtl", "tf48_pkg.sv"),
        os.path.join(RTL, "rtl", "tf48_to_f32.sv"),       # сверка ref==comb ниже
        os.path.join(RTL, "rtl", "tf48_div_pipe.sv"),
        os.path.join(RTL, "rtl", "tf48_to_f32_pipe.sv"),
        os.path.join(RTL, "tb", "tb_tf48_to_f32_pipe.sv"),
    ]
    xvlog = os.path.join(XIL_BIN, "xvlog.bat")
    xelab = os.path.join(XIL_BIN, "xelab.bat")
    xsim  = os.path.join(XIL_BIN, "xsim.bat")

    def run(cmd, cwd=None):
        r = subprocess.run(cmd, shell=True, cwd=cwd or RTL, capture_output=True, text=True)
        if r.returncode != 0:
            print("CMD FAIL:", cmd); print(r.stdout[-1500:]); print(r.stderr[-1500:])
        return r

    for d in ["xsim.dir", "xsim.cmd", "xsim.log", "xelab.log", "xvlog.log"]:
        p = os.path.join(RTL, d)
        if os.path.isdir(p):
            import shutil; shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)

    run(f'"{xvlog}" -sv {" ".join(files)}')
    run(f'"{xelab}" tb_tf48_to_f32_pipe -debug typical')
    run(f'"{xsim}" tb_tf48_to_f32_pipe -runall')


def verify(words):
    out_path = os.path.join(SIM, "t2f48p_out.hex")
    if not os.path.exists(out_path):
        print("НЕТ t2f48p_out.hex - симуляция не выполнена")
        return False
    got = [int(l.strip(), 16) for l in open(out_path) if l.strip()]
    if len(got) != len(words):
        print(f"ОШИБКА: ожидалось {len(words)} выходов pipe, получено {len(got)}")
        return False
    bad = 0
    for i, (w, g) in enumerate(zip(words, got)):
        r = ref_to_float(w)      # = бит-в-бит эталон комбинационного tf48_to_f32
        if r != g:
            bad += 1
            if bad <= 20: print(f"  [{i}] ref={r:08x} pipe={g:08x}")
    print(f"T2F48_PIPE: vectors={len(got)} pipe-vs-ref(comb) mismatch={bad}")
    return bad == 0


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    words = gen_input(n)
    run_sim()
    ok = verify(words)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()