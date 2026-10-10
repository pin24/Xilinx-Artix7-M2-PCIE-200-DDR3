open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
puts "=== hw targets ==="
set tgts [get_hw_targets]
puts "$tgts"
if {[llength $tgts] > 0} {
    current_hw_target [lindex $tgts 0]
    open_hw_target
    puts "=== devices ==="
    puts [get_hw_devices]
}
puts "=== PROBE DONE ==="