"""Прямая сверка RTL compute_dot_par_raw с ПРАВИЛЬНОЙ моделью (arith48).

Генерирует N случаев, подаёт пары TFloat48 в RTL (xvlog/xsim) и сравнивает
результат с двумя моделями:
  - arith48.full (нормализованная, совпадает с torch до ~1e-6)  -> эталон
  - raw (dot_ref_raw, использовалась раньше)                      -> подозрение на баг

Запуск: python rtl_vs_arith48.py [NUM_CASE] [NUM_MAC]
"""
from __future__ import annotations
import os, sys, subprocess, struct, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ternary_sw"))

from block.tfloat48 import TFloat
from block import arith48

BLOCK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "block")
SIM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sim")
XIL_BIN = "C:/AMDDesignTools/Vivado/2021.2/bin"
NUM_MAC = 32
os.makedirs(SIM, exist_ok=True)


def f32(x): return struct.unpack("f", struct.pack("f", x))[0]


def to_bits48(t):
    return ((t.e_int & 0xFF) << 40) | (t.m_int & ((1 << 40) - 1))


def bits_to_tf(bits):
    """48-бит в формате RTL [E:8][M:40] -> TFloat (биты E в младших)."""
    return TFloat.from_bits(((bits & ((1 << 40) - 1)) << 8) | ((bits >> 40) & 0xFF))


def dot_arith48(a_bits, b_bits):
    """Полная нормализованная модель (эталон)."""
    a = [bits_to_tf(x) for x in a_bits]
    b = [bits_to_tf(x) for x in b_bits]
    prods = [arith48.mul(x, y) for x, y in zip(a, b)]
    while len(prods) > 1:
        nxt = []
        for k in range(0, len(prods) - 1, 2):
            nxt.append(arith48.add(prods[k], prods[k + 1]))
        if len(prods) % 2 == 1:
            nxt.append(prods[-1])
        prods = nxt
    return prods[0].to_float()


# TB: читает по одному случаю (NUM_MAC пар), гонит ядро, пишет выход
TB = """
module tb_rtl_vs_arith48;
    parameter int NUM_MAC = 32;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;
    logic [48*NUM_MAC-1:0] data_in, weights;
    logic valid_in = 0;
    logic [47:0] result_out;
    logic valid_out;
    compute_dot_par_raw #(.NUM_MAC(NUM_MAC)) u (.clk(clk), .rst_n(rst_n),
        .data_in(data_in), .weights(weights), .valid_in(valid_in),
        .result_out(result_out), .valid_out(valid_out));
    integer f, g, k, ncase, npair;
    logic [47:0] w;
    initial begin
        #20 rst_n <= 1;
        #20;
        f = $fopen("%SIM%rtl48_in.hex", "r");
        g = $fopen("%SIM%rtl48_out.hex", "w");
        ncase = 0;
        while (!$feof(f)) begin
            // один случай = NUM_MAC пар
            npair = 0;
            for (k = 0; k < NUM_MAC; k = k + 1) begin
                if ($fscanf(f, "%h", w) != 1) break;
                data_in[48*k +: 48] <= w;
                $fscanf(f, "%h", w);
                weights[48*k +: 48] <= w;
                npair = npair + 1;
            end
            if (npair < NUM_MAC) break;   // конец файла
            @(posedge clk);
            valid_in <= 1;
            @(posedge clk);
            valid_in <= 0;
            wait (valid_out);
            @(posedge clk);
            $fwrite(g, "%012h\\n", result_out);
            ncase = ncase + 1;
            #20;
        end
        $fclose(f); $fclose(g);
        $display("processed %0d cases", ncase);
        $finish;
    end
endmodule
"""


def gen_and_sim(ncase, seed):
    random.seed(seed)
    with open(os.path.join(SIM, "rtl48_in.hex"), "w") as f:
        for _ in range(ncase):
            a = [f32(random.uniform(-10, 10)) for _ in range(NUM_MAC)]
            b = [f32(random.uniform(-10, 10)) for _ in range(NUM_MAC)]
            for x, y in zip(a, b):
                f.write(f"{to_bits48(TFloat.from_float(x)):012x} {to_bits48(TFloat.from_float(y)):012x}\n")
    tb = TB.replace("%SIM%", SIM.replace("\\", "/") + "/")
    open(os.path.join(SIM, "tb_rtl_vs_arith48.sv"), "w").write(tb)
    files = [os.path.join(BLOCK, "tbyte_add.sv"), os.path.join(BLOCK, "tbyte_mul.sv"),
             os.path.join(BLOCK, "tfadd_raw.sv"), os.path.join(BLOCK, "tfmul_raw.sv"),
             os.path.join(BLOCK, "compute_dot_par_raw.sv"),
             os.path.join(SIM, "tb_rtl_vs_arith48.sv")]
    xvlog, xelab, xsim = [os.path.join(XIL_BIN, b + ".bat") for b in ("xvlog", "xelab", "xsim")]
    def run(cmd):
        r = subprocess.run(cmd, shell=True, cwd=os.path.dirname(os.path.abspath(__file__)),
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("CMD FAIL:", cmd); print(r.stdout[-1000:]); print(r.stderr[-1000:])
        return r
    for d in ["xsim.dir"]:
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), d)
        if os.path.isdir(p):
            import shutil; shutil.rmtree(p, ignore_errors=True)
    run(f'"{xvlog}" -sv {" ".join(files)}')
    run(f'"{xelab}" tb_rtl_vs_arith48 -debug typical')
    run(f'"{xsim}" tb_rtl_vs_arith48 -runall')


def main():
    ncase = 8
    seed = 61
    gen_and_sim(ncase, seed)
    # читаем RTL выходы
    outs = [int(l.strip(), 16) for l in open(os.path.join(SIM, "rtl48_out.hex")) if l.strip()]
    # пересчитываем эталон (и raw)
    import sys as _sys
    _sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "integration"))
    import verify_tdot_axi4 as V
    random.seed(seed)
    bad_full = bad_raw = 0
    for i in range(ncase):
        a = [f32(random.uniform(-10, 10)) for _ in range(NUM_MAC)]
        b = [f32(random.uniform(-10, 10)) for _ in range(NUM_MAC)]
        bits_a = [to_bits48(TFloat.from_float(x)) for x in a]
        bits_b = [to_bits48(TFloat.from_float(y)) for y in b]
        ref = dot_arith48(bits_a, bits_b)
        rtl_float = bits_to_tf(outs[i]).to_float()
        raw_bits = V.dot_ref_raw(bits_a, bits_b)
        raw_float = bits_to_tf(raw_bits).to_float()
        d_full = abs(ref - rtl_float)
        d_raw = abs(raw_float - rtl_float)
        if d_full > 1e-4:
            bad_full += 1
            print(f"[{i}] RTL={rtl_float:.6g} arith48={ref:.6g} raw={raw_float:.6g}")
        if d_raw > 1e-4:
            bad_raw += 1
    print(f"RTL vs arith48 (правильная модель): несовпадений {bad_full}/{ncase}")
    print(f"RTL vs dot_ref_raw (старая модель) : несовпадений {bad_raw}/{ncase}")


if __name__ == "__main__":
    main()
