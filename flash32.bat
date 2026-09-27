@echo off
cd /d C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;%PATH%
vivado.bat -mode batch -source scripts/flash_program.tcl -tclargs build/artifacts_dfx/xdma_ddr3_core_top.bin
echo FLASH_EXIT=%ERRORLEVEL%
