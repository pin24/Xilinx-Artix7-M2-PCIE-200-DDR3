set f [open "C:/A7_M2/Xilinx-Artix7-M2-PCIE-200-DDR3/_probe_t182.out" w]
if {[catch {connect} e]} { puts $f "CONNECT ERR: $e" } else { puts $f "CONNECTED" }
if {[catch {jtag targets} t]} { puts $f "TARGETS ERR: $t" } else { puts $f "TARGETS: $t" }
catch {disconnect}
close $f
exit
