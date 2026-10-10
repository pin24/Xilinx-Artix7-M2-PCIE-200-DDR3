connect
puts "=== TARGETS v2 ==="
puts [targets]
catch { jtag targets } err
puts "jtag targets: $err"
exit
