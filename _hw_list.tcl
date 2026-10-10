connect_hw_server -url TCP:localhost:3121
puts "=== HW TARGETS ==="
foreach t [get_hw_targets] { puts "TARGET: $t" }
puts "=== HW DEVICES ==="
foreach t [get_hw_targets] {
  current_hw_target $t
  open_hw_target
  foreach d [get_hw_devices] { puts "DEVICE on $t: $d" }
  close_hw_target
}
exit
