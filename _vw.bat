@echo off
cd /d "C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3"
call "C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -source _hw2.tcl -nojournal > _vw.out 2>&1
echo EXIT=%ERRORLEVEL% >> _vw.out
