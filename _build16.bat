@echo off
cd /d C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\rtl\block
vivado -mode batch -source synth_par_raw.tcl -tclargs NUM_MAC=16 ADDERS=4 -nojournal
