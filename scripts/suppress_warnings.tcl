# suppress_warnings.tcl — подавление ложных CRITICAL WARNING/предупреждений Vivado 2025.2
# ============================================================================
# Вызывается как TCL.PRE для place_design в build_dfx.tcl.
#
# ВАЖНО (BUG-025 из ERROR_HISTORY.md):
# В Vivado 2025.2 set_msg_config с -new_severity И -suppress одновременно
# даёт ERROR: [Common 17-447] -limit, -filter, and -new_severity options are
# mutually-exclusive. После этого весь TCL-скрипт падает, Vivado прерывает
# impl_1 с "Failed runs(s): 'impl_1'".
#
# Правильно: использовать ОДИН из вариантов:
#   -new_severity WARNING   → изменить severity (видно в логе как WARNING)
#   -suppress                → полностью подавить (не виден в логе)
#
# Здесь: используем -new_severity WARNING (сообщения видны как WARNING,
# но не как CRITICAL WARNING — это упрощает поиск реальных проблем).
# ============================================================================

# --- DRC checks (set_property SEVERITY на DRC ruledeck) ---
# REQP-123: ложное на clk_wiz MMCM CLKINSEL=VCC (Vivado 2025.2 баг)
catch { set_property SEVERITY {Warning} [get_drc_checks REQP-123] }

# BUFC-1: MIG DQS IBUFDS без loads — MIG internal, ожидаемо для инверсных DQS
catch { set_property SEVERITY {Warning} [get_drc_checks BUFC-1] }

# REQP-1709: MIG PLL CLKOUT3 не на том же BUFFER — MIG internal, не критично
catch { set_property SEVERITY {Warning} [get_drc_checks REQP-1709] }

# REQP-165, REQP-181: DataMover BRAM WRITE_FIRST advisories — информационное
catch { set_property SEVERITY {Warning} [get_drc_checks REQP-165] }
catch { set_property SEVERITY {Warning} [get_drc_checks REQP-181] }

# --- Message severity downgrade (только -new_severity, БЕЗ -suppress) ---
# Timing 38-472: IDELAYCTRL REFCLK — MIG internal, ложное (REFCLK подводится через PLL)
catch { set_msg_config -id {Timing 38-472} -new_severity WARNING }

# Vivado 12-1411: PCIe lane LOC конфликт — ожидаем (наши early XDC побеждают IP XDC)
catch { set_msg_config -id {Vivado 12-1411} -new_severity WARNING }

# Constraints 18-550: IBUF_LOW_PWR на clk200_clk_wiz/clk_in1 (net не на top-level порту)
catch { set_msg_config -id {Constraints 18-550} -new_severity WARNING }

# Vivado 12-584: "No ports matched 'clk50'" — clk50 объявлен как [0:0], а
# get_ports ищет скаляр; до появления wrapper порт не резолвится на синтезе
catch { set_msg_config -id {Vivado 12-584} -new_severity WARNING }

# Common 17-55: "set_property expects at least one object" — следствие Vivado 12-584
catch { set_msg_config -id {Common 17-55} -new_severity WARNING }

# Vivado_Tcl 4-921: CDC waiver с пустым -to списком (внутренний SmartConnect XDC)
catch { set_msg_config -id {Vivado_Tcl 4-921} -new_severity WARNING }

# Synth 8-3848: "Net axi_aclk_out does not have driver" — BD output port, драйвится в top
catch { set_msg_config -id {Synth 8-3848} -new_severity WARNING }

# Synth 8-689: port width mismatch — Vivado auto-widening, корректно
catch { set_msg_config -id {Synth 8-689} -new_severity WARNING }

# Synth 8-7023/7071: unconnected/extra ports на BD black boxes — ожидаем
catch { set_msg_config -id {Synth 8-7023} -new_severity WARNING }
catch { set_msg_config -id {Synth 8-7071} -new_severity WARNING }

# Netlist 29-1115: multi-term driver на const0 (util_ds_buf internal) — benign
catch { set_msg_config -id {Netlist 29-1115} -new_severity WARNING }

# Physopt 32-894: through constraint blocking opt — PCIe IP internal
catch { set_msg_config -id {Physopt 32-894} -new_severity WARNING }

# Vivado 12-2285: GTPE2_CHANNEL BEL occupied — известный PCIe lane LOC conflict
# (IP XDC vs our early XDC). Не блокирует — Vivado auto-place.
catch { set_msg_config -id {Vivado 12-2285} -new_severity WARNING }

# Vivado 12-4739: create_clock No valid objects for REFCLK pin (MIG internal)
catch { set_msg_config -id {Vivado 12-4739} -new_severity WARNING }

puts "=== SUPPRESS WARNINGS: OK ==="
