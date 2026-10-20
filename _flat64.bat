@echo off
REM FLAT build: flat 64/2 (NUM_MAC=64, ADDERS=2), scripts\build_flat.tcl
REM Mirrors _full32.bat (DFX) for the FLAT (no-DFX) flow.
REM ВНИМАНИЕ: NUM_MAC=64 на xc7a200t может не уложиться по ресурсам (DSP48/LUT).
cd /d "C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3"

set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;%PATH%

vivado -mode batch -source scripts\build_flat.tcl -tclargs NUM_MAC=64 ADDERS=2 JOBS=8 -nojournal

echo DONE_FLAT64 exit=%ERRORLEVEL%