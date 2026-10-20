@echo off
REM FLAT build: flat 16/4 (NUM_MAC=16, ADDERS=4), scripts\build_flat.tcl
REM Mirrors _full16.bat (which runs the DFX build) for the FLAT (no-DFX) flow.
cd /d "C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3"

set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;%PATH%

vivado -mode batch -source scripts\build_flat.tcl -tclargs NUM_MAC=16 ADDERS=4 JOBS=8 -nojournal

echo DONE_FLAT16 exit=%ERRORLEVEL%