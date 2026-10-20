@echo off
REM FLAT build: flat 32/16 (NUM_MAC=32, ADDERS=16), scripts\build_flat.tcl
REM Mirrors _full32.bat (which runs the DFX build) for the FLAT (no-DFX) flow.
REM FIX 2026-10-20 (аудит-VS P2-8): JOBS 13->4 (13 параллельных job'ов x maxThreads = OOM/swap).
cd /d "C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3"

set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;%PATH%

vivado -mode batch -source scripts\build_flat.tcl -tclargs NUM_MAC=32 ADDERS=16 JOBS=4 -nojournal

echo DONE_FLAT32 exit=%ERRORLEVEL%