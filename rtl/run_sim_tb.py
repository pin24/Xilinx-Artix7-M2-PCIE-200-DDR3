import subprocess, os, sys
X = 'C:/AMDDesignTools/Vivado/2021.2/bin'
RTL = 'C:/A7_M2/EXAMPLES/XDMA_DDR3/rtl'
tb = sys.argv[1]
files = [f'{RTL}/rtl/tfloat_pkg.sv', f'{RTL}/rtl/int_to_trits.sv',
         f'{RTL}/rtl/f32_to_tf40_pipe2.sv', f'{RTL}/tb/{tb}.sv']
for d in ['xsim.dir', 'xsim.cmd', 'xsim.log']:
    p = os.path.join(RTL, d)
    if os.path.isdir(p):
        import shutil; shutil.rmtree(p, ignore_errors=True)
    elif os.path.exists(p):
        os.remove(p)
def run(cmd):
    r = subprocess.run(cmd, shell=True, cwd=RTL, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL:', cmd)
        print(r.stdout[-900:]); print(r.stderr[-900:])
    return r
run(f'"{X}/xvlog.bat" -sv {" ".join(files)}')
run(f'"{X}/xelab.bat" {tb} -debug typical')
run(f'"{X}/xsim.bat" {tb} -runall')
