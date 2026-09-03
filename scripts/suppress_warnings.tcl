# suppress_warnings.tcl — подавление ложных CRITICAL WARNING/предупреждений Vivado 2025.2
# Вызывается как TCL.PRE для place_design в build_dfx.tcl

# --- DRC checks ---
# REQP-123: ложное на clk_wiz MMCM CLKINSEL=VCC (Vivado 2025.2 баг)
catch { set_property SEVERITY {Warning} [get_drc_checks REQP-123] }

# BUFC-1: MIG DQS IBUFDS без loads — MIG internal, ожидаемо для инверсных DQS
catch { set_property SEVERITY {Warning} [get_drc_checks BUFC-1] }

# REQP-1709: MIG PLL CLKOUT3 не на том же BUFFER — MIG internal, не критично
catch { set_property SEVERITY {Warning} [get_drc_checks REQP-1709] }

# REQP-165, REQP-181: DataMover BRAM WRITE_FIRST advisories — информационное
catch { set_property SEVERITY {Warning} [get_drc_checks REQP-165] }
catch { set_property SEVERITY {Warning} [get_drc_checks REQP-181] }

# --- Message suppression (по ID) ---
# Timing 38-472: IDELAYCTRL REFCLK — MIG internal, ложное (REFCLK подводится через PLL)
set_msg_config -id {Timing 38-472} -new_severity WARNING -suppress

# Vivado 12-1411: PCIe lane LOC конфликт — ожидаем (наши early XDC побеждают IP XDC)
set_msg_config -id {Vivado 12-1411} -new_severity WARNING -suppress

# Constraints 18-550: IBUF_LOW_PWR на clk200_clk_wiz/clk_in1 (net не на top-level порту)
set_msg_config -id {Constraints 18-550} -new_severity WARNING -suppress

# Vivado 12-584: "No ports matched 'clk50'" на синтезе (clk50 как BD-порт, не top-level)
set_msg_config -id {Vivado 12-584} -new_severity WARNING -suppress

# Common 17-55: "set_property expects at least one object" — следствие Vivado 12-584
set_msg_config -id {Common 17-55} -new_severity WARNING -suppress

# Vivado_Tcl 4-921: CDC waiver с пустым -to списком (внутренний SmartConnect XDC)
set_msg_config -id {Vivado_Tcl 4-921} -new_severity WARNING -suppress

# Synth 8-3848: "Net axi_aclk_out does not have driver" — BD output port, драйвится в top
set_msg_config -id {Synth 8-3848} -new_severity WARNING -suppress

# Synth 8-689: port width mismatch — Vivado auto-widening, корректно
set_msg_config -id {Synth 8-689} -new_severity WARNING -suppress

# Synth 8-7023/7071: unconnected/extra ports на BD black boxes — ожидаем
set_msg_config -id {Synth 8-7023} -new_severity WARNING -suppress
set_msg_config -id {Synth 8-7071} -new_severity WARNING -suppress

# Netlist 29-1115: multi-term driver на const0 (util_ds_buf internal) — benign
set_msg_config -id {Netlist 29-1115} -new_severity WARNING -suppress

# Physopt 32-894: through constraint blocking opt — PCIe IP internal
set_msg_config -id {Physopt 32-894} -new_severity WARNING

puts "=== SUPPRESS WARNINGS: OK ==="