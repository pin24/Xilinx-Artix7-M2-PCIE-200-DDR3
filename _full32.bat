@echo off
cd /d "C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3"
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;%PATH%
make NUM_MAC=32 ADDERS=2 JOBS=8 build
echo DONE_32 exit=%ERRORLEVEL%
