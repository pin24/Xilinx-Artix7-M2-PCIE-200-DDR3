@echo off
cd /d C:\A7_M2\Xilinx-Artix7-M2-PCIE-200-DDR3\rtl\block
vivado -mode batch -source synth_par_raw.tcl -tclargs NUM_MAC=32 ADDERS=8 -nojournal
