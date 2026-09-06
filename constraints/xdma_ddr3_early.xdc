# Fix PCIe lane assignments (DFX-BD: xdma_ddr3_dfx_i)
set_property LOC GTPE2_CHANNEL_X0Y7 [get_cells {xdma_ddr3_dfx_i/xdma_0/inst/xdma_ddr3_dfx_xdma_0_0_pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_lane[3].gt_wrapper_i/gtp_channel.gtpe2_channel_i}]
set_property LOC GTPE2_CHANNEL_X0Y6 [get_cells {xdma_ddr3_dfx_i/xdma_0/inst/xdma_ddr3_dfx_xdma_0_0_pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_lane[2].gt_wrapper_i/gtp_channel.gtpe2_channel_i}]
set_property LOC GTPE2_CHANNEL_X0Y5 [get_cells {xdma_ddr3_dfx_i/xdma_0/inst/xdma_ddr3_dfx_xdma_0_0_pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_lane[1].gt_wrapper_i/gtp_channel.gtpe2_channel_i}]
set_property LOC GTPE2_CHANNEL_X0Y4 [get_cells {xdma_ddr3_dfx_i/xdma_0/inst/xdma_ddr3_dfx_xdma_0_0_pcie2_to_pcie3_wrapper_i/pcie2_ip_i/inst/inst/gt_top_i/pipe_wrapper_i/pipe_lane[0].gt_wrapper_i/gtp_channel.gtpe2_channel_i}]

# ============================================================================
# BUG-037: set_multicycle_path для tfmul_raw (25-тактный умножитель)
# tfmul_raw выполняет 25 итераций PH_MUL + 20 итераций PH_FIN за один
# valid_in → valid_out цикл. Путь между регистрами внутри PH_MUL/PH_FIN
# — комбинаторный (263 уровня CARRY4), но Vivado считает его однотактовым
# (8 нс @ 125 МГц), хотя по факту 25 × 8 нс = 200 нс доступно для
# carry-save редукции.
#
# set_multicycle_path -setup 25 -from [all_registers -clock [get_clocks clk_out1_xdma_ddr3_dfx_clk125_core_wiz_0] -filter {name =~ *phase_reg* || name =~ *cnt_reg* || name =~ *gen_mac[*].u_mul/phase_reg* || name =~ *gen_mac[*].u_mul/cnt_reg*}]
# Упрощённо: все пути внутри tfmul_raw (gen_mac[*].u_mul) — 25 циклов.
# ============================================================================
# ============================================================================
# [ОТКЛЮЧЕНО 2026-09-07, Task 30] BUG-037 MCP — разбор в docs/worklog.md (Task 29/30).
# Причина: MCP -setup 25 -through sum_n исходит из трактовки «конус живёт 25 тактов».
# По RTL carry-save массив ОБНОВЛЯЕТСЯ КАЖДЫЙ такт (частичные произведения входят
# по одному за такт, sum_r/carry_r — регистры): путь cnt_reg→колонка→sum_r
# ОДНОТАКТОВЫЙ (бюджет 8 нс @125 МГц), а не 25×8 нс; 25 — ЛАТЕНТНОСТЬ умножения.
# (а) если конус мал — MCP безвреден, но создаёт слепую зону STA;
# (б) если конус велик — MCP СПРЯЧЕТ нарушение → порча данных при «зелёном» отчёте.
# Правило проекта: тайминговое нарушение = fatal — маскировать нельзя.
# После pure-LUT (Task 30) колонка = 1 LUT6/бит, tbyte = case-таблицы: пути короткие.
# Если синтез покажет WNS<0 на u_mul — чинить RTL, а не ослаблять констрейнт.
# ============================================================================
# set_multicycle_path -setup 25 -through [get_nets -quiet -filter {name =~ *gen_mac[*].u_mul/sum_n*}]
# set_multicycle_path -hold 24 -through [get_nets -quiet -filter {name =~ *gen_mac[*].u_mul/sum_n*}]