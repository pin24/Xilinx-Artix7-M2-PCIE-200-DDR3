@echo off
cd /d "C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3"
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;%PATH%
echo === CLEAN %DATE% %TIME% ===
make NUM_MAC=32 ADDERS=4 JOBS=8 clean
echo === BUILD %DATE% %TIME% ===
make NUM_MAC=32 ADDERS=4 JOBS=8 build
echo === DONE exit=%ERRORLEVEL% %DATE% %TIME% ===
