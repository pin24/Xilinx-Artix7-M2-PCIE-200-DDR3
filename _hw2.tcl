open_hw_manager
connect_hw_server -allow_non_jtag
puts "TARGETS_START"
puts [get_hw_targets]
puts "TARGETS_END"
exit
