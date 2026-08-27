xvlog -sv C:\A7_M2\EXAMPLES\XDMA_DDR3\rtl\rtl\tfloat_pkg.sv C:\A7_M2\EXAMPLES\XDMA_DDR3\rtl\rtl\int_to_trits.sv C:\A7_M2\EXAMPLES\XDMA_DDR3\rtl\rtl\f32_to_tf40.sv C:\A7_M2\EXAMPLES\XDMA_DDR3\rtl\tb\tb_f32_to_tf40.sv
xelab tb_f32_to_tf40 -debug typical
xsim tb_f32_to_tf40 -runall
