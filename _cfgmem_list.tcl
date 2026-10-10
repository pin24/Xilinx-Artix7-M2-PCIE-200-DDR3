open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t_0] 0]
current_hw_device ${dev}
puts "=== EXACT w25q128 parts ==="
puts [get_cfgmem_parts {w25q128*}]
puts "=== w25q parts (all) ==="
puts [get_cfgmem_parts {w25q*}]
puts "=== mx25l128 / 128 parts ==="
puts [get_cfgmem_parts {*128*spi-x1_x2_x4}]
puts "=== ALL spi parts ==="
puts [get_cfgmem_parts {*spi-x1_x2_x4}]
puts "=== DONE ==="