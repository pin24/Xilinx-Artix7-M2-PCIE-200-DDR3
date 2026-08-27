import subprocess, os, sys
X = 'C:/AMDDesignTools/Vivado/2021.2/bin'
R = 'C:/A7_M2/EXAMPLES/XDMA_DDR3/rtl/block'
tb = sys.argv[1]
files = [f'{R}/tbyte_add.sv', f'{R}/tbyte_mul.sv', f'{R}/tfadd_raw.sv',
         f'{R}/tfmul_raw.sv', f'{R}/compute_dot_par_raw.sv', f'{R}/tb_{tb}.sv']
for d in ['xsim.dir', 'xsim.cmd', 'xsim.log']:
    p = os.path.join(R, d)
    if os.path.isdir(p):
        import shutil; shutil.rmtree(p, ignore_errors=True)
    elif os.path.exists(p):
        os.remove(p)
def run(c):
    r = subprocess.run(c, shell=True, cwd=R, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-900:]); print(r.stderr[-900:])
run(f'"{X}/xvlog.bat" -sv {" ".join(files)}')
run(f'"{X}/xelab.bat" {tb} -debug typical')
run(f'"{X}/xsim.bat" {tb} -runall')
