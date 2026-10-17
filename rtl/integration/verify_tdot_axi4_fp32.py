"""Сверка AXI4-мастера tdot_axi4 в режиме ELEM_FMT=1 (fp32 вход/выход).

Генерирует fp32-данные (2 fp32 на 64-бит слово), запускает tb_tdot_axi4_fp32.sv,
сверяет результат (fp32, 4 байта) с CPU-эталоном:
   эталон = float32( TFloat.to_float( dot_ref_raw( from_float(a_i), from_float(b_i) ) ) )
т.е. ровно то, что делает ядро: F2T на входе -> tfmul/tfadd (raw) -> T2F на выходе.

Запуск:  python verify_tdot_axi4_fp32.py [NUM_MAC]
"""
from __future__ import annotations
import sys, os, subprocess, struct, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ternary_sw"))

from block.tfloat48 import TFloat
from block import arith48
# переиспользуем dot_ref_raw и тритовые примитивы из verify_tdot_axi4
from verify_tdot_axi4 import dot_ref_raw, to_bits48, _bits_to_tf, _pack_raw

RTL = os.path.dirname(os.path.abspath(__file__))
BLOCK = os.path.join(RTL, "..", "block")
SIM = os.path.join(RTL, "sim")
_CANDS = ["C:/AMDDesignTools/2025.2/Vivado/bin", "C:/Xilinx/Vivado/2025.2/bin",
          "C:/AMDDesignTools/Vivado/2021.2/bin"]
XIL_BIN = os.environ.get("VIVADO_BIN")
if not XIL_BIN:
    for c in _CANDS:
        if os.path.exists(os.path.join(c, "xvlog.bat")):
            XIL_BIN = c; break
    else:
        XIL_BIN = _CANDS[0]
NUM_MAC = int(sys.argv[1]) if len(sys.argv) > 1 else 32
NCASES = 4
os.makedirs(SIM, exist_ok=True)

M_MASK = (1 << 40) - 1


def f32(x): return struct.unpack("f", struct.pack("f", x))[0]
def f32_bits(x): return struct.unpack("I", struct.pack("f", x))[0]
def kernel_to_py(w): return ((w & M_MASK) << 8) | ((w >> 40) & 0xFF)


def ref_fp32_result(tf48_word):
    """tf48 (конвенция ядра) -> float32 bits (RNE), как T2F/RTL."""
    t = TFloat.from_bits(kernel_to_py(tf48_word))
    return f32_bits(t.to_float())


def gen_input():
    random.seed(71)
    words = []
    expected = []
    for case in range(NCASES):
        a = [f32(random.uniform(-10, 10)) for _ in range(NUM_MAC)]
        b = [f32(random.uniform(-10, 10)) for _ in range(NUM_MAC)]
        # упаковка 2 fp32 на слово: data[2k],data[2k+1] в word k
        base = case * 2 * NUM_MAC * 4
        data_words = []
        for k in range(0, NUM_MAC, 2):
            lo = f32_bits(a[k]); hi = f32_bits(a[k+1])
            data_words.append((hi << 32) | lo)
        wgt_words = []
        for k in range(0, NUM_MAC, 2):
            lo = f32_bits(b[k]); hi = f32_bits(b[k+1])
            wgt_words.append((hi << 32) | lo)
        words += data_words + wgt_words
        # CPU-эталон отсюда
        aref = [to_bits48(TFloat.from_float(x)) for x in a]
        bref = [to_bits48(TFloat.from_float(y)) for y in b]
        r = dot_ref_raw(aref, bref)
        expected.append(ref_fp32_result(r))
    with open(os.path.join(SIM, "tb_tdot_axi4_fp32_in.hex"), "w") as f:
        for w in words:
            f.write(f"{w:016x}\n")
    with open(os.path.join(SIM, "tb_tdot_axi4_fp32_expected.hex"), "w") as f:
        for e in expected:
            f.write(f"{e:08x}\n")
    print(f"Сгенерировано {NCASES} случаев fp32 (NUM_MAC={NUM_MAC})")


def run_sim():
    # параметризуем tb под нужный NUM_MAC (как в verify_tdot_axi4.py)
    tb_path = os.path.join(RTL, "tb_tdot_axi4_fp32.sv")
    tb_src = open(tb_path).read()
    tb_src = tb_src.replace("parameter int NUM_MAC = 32;",
                            f"parameter int NUM_MAC = {NUM_MAC};")
    tb_use = os.path.join(RTL, "tb_tdot_axi4_fp32_use.sv")
    open(tb_use, "w").write(tb_src)
    files = [
        os.path.join(BLOCK, "tbyte_add.sv"),
        os.path.join(BLOCK, "tbyte_mul.sv"),
        os.path.join(BLOCK, "tfadd_raw.sv"),
        os.path.join(BLOCK, "tfmul_raw.sv"),
        os.path.join(BLOCK, "tfadd48.sv"),
        os.path.join(BLOCK, "compute_dot_par_raw.sv"),
        os.path.join(RTL, "..", "rtl", "tf48_pkg.sv"),
        os.path.join(RTL, "..", "rtl", "int_to_trits.sv"),
        os.path.join(RTL, "..", "rtl", "tf48_div_pipe.sv"),
        os.path.join(RTL, "..", "rtl", "f32_to_tf48_pipe.sv"),
        os.path.join(RTL, "..", "rtl", "tf48_to_f32_pipe.sv"),
        os.path.join(RTL, "tdot_axi4.sv"),
        tb_use,
    ]
    xvlog = os.path.join(XIL_BIN, "xvlog.bat")
    xelab = os.path.join(XIL_BIN, "xelab.bat")
    xsim = os.path.join(XIL_BIN, "xsim.bat")
    def run(cmd):
        r = subprocess.run(cmd, shell=True, cwd=RTL, capture_output=True, text=True)
        if r.returncode != 0:
            print("CMD FAIL:", cmd); print(r.stdout[-1500:]); print(r.stderr[-1500:])
        return r
    for d in ["xsim.dir", "xsim.cmd", "xsim.log"]:
        p = os.path.join(RTL, d)
        if os.path.isdir(p):
            import shutil; shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)
    run(f'"{xvlog}" -sv {" ".join(files)}')
    run(f'"{xelab}" tb_tdot_axi4_fp32 -debug typical')
    run(f'"{xsim}" tb_tdot_axi4_fp32 -runall')


def verify():
    exp = [int(l.strip(), 16) for l in open(os.path.join(SIM, "tb_tdot_axi4_fp32_expected.hex")) if l.strip()]
    got = [int(l.strip(), 16) for l in open(os.path.join(SIM, "tb_tdot_axi4_fp32_out.hex")) if l.strip()]
    if len(exp) != len(got):
        print(f"ОШИБКА: exp {len(exp)}, got {len(got)}")
        return False
    bad = 0
    for i, (e, g) in enumerate(zip(exp, got)):
        if e != g:
            bad += 1
            if bad <= 10:
                print(f"  [{i}] exp={e:08x} got={g:08x}")
    print(f"tdot_axi4_fp32(NUM_MAC={NUM_MAC}): {len(got)} случаев, несовпадений {bad}")
    return bad == 0


def main():
    gen_input()
    run_sim()
    ok = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()