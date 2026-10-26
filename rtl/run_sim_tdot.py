#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""run_sim_tdot.py — собрать и прогнать tb_tdot_dot_hang.sv через XSim (Vivado 2025.2).

Использование (из корня проекта, у тебя в консоли где xvlog работает):
    python rtl\\make_tdot_vectors.py            # сгенерировать vectors.dat/weights.dat (реальные веса)
    python rtl\\run_sim_tdot.py                # xvlog + xelab + xsim
    python rtl\\run_sim_tdot.py --probe        # + внутренние пробники дерева (+define+PROBE_TREE)

RTL-файлы активного пути Tdot (то, что реально собирается на плате):
    compute_dot_par_raw, tfmul_raw (+ tbyte_mul), tfadd_raw, tfadd48.
"""
import subprocess, os, sys

X = "C:/AMDDesignTools/2025.2/Vivado/bin"
ROOT = os.path.dirname(os.path.abspath(__file__))      # .../rtl
PROJ = os.path.dirname(ROOT)                            # корень проекта (там vectors.dat/weights.dat)
BLK = os.path.join(ROOT, "block")
INT = os.path.join(ROOT, "integration")

def _q(p):
    return '"' + p.replace("/", "\\") + '"'

# закрыток ядра (tb_tdot_dot_hang) — compute_dot_par_raw + tfmul_raw(+tbyte_mul) + tfadd_raw + tfadd48
CORE_FILES = [
    os.path.join(BLK, "compute_dot_par_raw.sv"),
    os.path.join(BLK, "tfmul_raw.sv"),
    os.path.join(BLK, "tbyte_mul.sv"),
    os.path.join(BLK, "tfadd_raw.sv"),
    os.path.join(BLK, "tfadd48.sv"),
]
# закрыток полной платы (tb_tdot_sched_hang) — tdot_axi4 + ядро
SCHED_FILES = [os.path.join(INT, "tdot_axi4.sv")] + CORE_FILES

def filelist(mode):
    common = [os.path.join(ROOT, "timescale.sv")]            # в начале — timescale единицы
    if mode == "sched":
        return common + SCHED_FILES + [os.path.join(INT, "tb_tdot_sched_hang.sv")]
    return common + CORE_FILES + [os.path.join(BLK, "tb_tdot_dot_hang.sv")]

def run(cmd, cwd=PROJ):
    sys.stdout.flush()
    r = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    for line in (r.stdout + r.stderr).splitlines():
        print(line)
    return r.returncode

def board_config():
    """Прочитать NUM_MAC/ADDERS из CORE_PARAMS вставленной платы (только чтение регистров,
    движок не запускаем). Возвращает строку "MAC/ADDER"."""
    import sys as _s, os as _o
    _s.path.insert(0, _o.path.join(PROJ, "pytorch_layer"))
    from test_dma_win import XdmaWinDma
    dev = XdmaWinDma(base=r"\\.\XDMA0dma")
    try:
        info = dev.probe_firmware()
    finally:
        try:
            dev.close()
        except Exception:
            pass
    nm = int(info.get("NUM_MAC") or 32)
    ad = int(info.get("ADDERS") or max(1, nm // 4))
    print(f"board CORE_PARAMS: NUM_MAC={nm}, ADDERS={ad}")
    return f"{nm}/{ad}"


def main():
    args = [a.lower() for a in sys.argv[1:] if a.startswith("--")]
    probe = "--probe" in args
    single = "--single" in args
    mode = next((a.split("=", 1)[1] for a in args if a.startswith("--mode=")), "dot")
    cfg = next((a.split("=", 1)[1] for a in args if a.startswith("--cfg=")), None)
    if not cfg:
        cfg = board_config()                 # берём из вставленной платы
        try:
            nm, ad = [int(x) for x in cfg.split("/")]
        except Exception:
            print("warn: не удалось прочитать плату — использую 32/8")
            nm, ad = 32, 8
    else:
        nm, ad = [int(x) for x in cfg.split("/")]
    TOP = "tb_tdot_sched_hang" if mode == "sched" else "tb_tdot_dot_hang"
    # sim_cfg.svh пишем в оба каталога (block для dot-tb, integration для sched-tb)
    long_def = "`define SIM_LONG " + ("0" if single else "1") + "\n"
    for d in (BLK, INT):
        cfg_path = os.path.join(d, "sim_cfg.svh")
        with open(cfg_path, "w") as f:
            f.write("`define SIM_NUM_MAC " + str(nm) + "\n")
            f.write("`define SIM_ADDERS " + str(ad) + "\n")
            if mode == "sched":
                f.write(long_def)
            if probe:
                f.write("`define PROBE_TREE\n")
    print(f"mode={mode} config: NUM_MAC={nm} ADDERS={ad} probe={probe} "
          f"long_dot={'off' if single else 'on'}")
    for d in ("xsim.dir", "xsim.cmd", "xsim.log", "xsim.wdb", "xvlog.pb", "xelab.pb", "elab.log"):
        p = os.path.join(PROJ, d)
        try:
            if os.path.isdir(p):
                import shutil; shutil.rmtree(p, ignore_errors=True)
            elif os.path.exists(p):
                os.remove(p)
        except OSError:
            pass
    files = filelist(mode)
    rc = run(f'"{X}/xvlog.bat" -sv -i {_q(BLK)} -i {_q(INT)} {" ".join(_q(f) for f in files)}')
    if rc: return rc
    rc = run(f'"{X}/xelab.bat" {TOP} -debug typical -s {TOP}_snap')
    if rc: return rc
    rc = run(f'"{X}/xsim.bat" {TOP}_snap -runall')
    return rc

if __name__ == "__main__":
    sys.exit(main())