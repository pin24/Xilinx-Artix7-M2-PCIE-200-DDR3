# XDMA DDR3 V2 — Ternary Accelerator (TFloat48)

PCIe Gen2 x4 FPGA accelerator card (M.2) based on Xilinx Artix-7 XC7A200T with DDR3.
Features ternary arithmetic (TFloat48) with Dynamic Function eXchange (DFX).

## Architecture
- **XDMA IP** — PCIe Gen2 x4, 125 MHz, BAR0=128MB, pciebar2axibar=0x40000000
- **DDR3** — 256MB via MIG 7-series
- **TFloat48** — ternary dot product engine (NUM_MAC=32)
- **DFX** — partial reconfiguration via HWICAP
- **AXI HWICAP** — ICAP for bitstream loading

## Repository Structure
```
FPGA_Vivado/       — Vivado project, RTL, scripts, constraints
  scripts/
    build_fpga.tcl           — Full build script (batch mode)
    dfx_partition_tdot.tcl   — RP with tdot_axi4 (TFloat48)
    block_design_top.tcl     — Static BD (XDMA, MIG, HWICAP, DFX Socket)
  hdl/block/       — TFloat48 RTL (tbyte, tfmul, tfadd, compute)
  hdl/integration/ — tdot_axi4.sv, tdot_axi4_wrapper.v, xdma_ddr3_core_top.sv
  constraints/     — pins.xdc, pcie_lanes_early.xdc
Driver/            — Windows KMDF driver + test app
  sys/driver.c     — KMDF driver
  exe/test_xdma.c  — Test application
  build/           — Signed artifacts: .sys, .cat, .cer, .inf
Python/            — Python driver, PyTorch layer
docs/              — CHANGELOG, DRIVER_DEVLOG, ADR-001/002
```

## BAR Address Map
| Peripheral | Address | Size | Description |
|-----------|---------|------|-------------|
| GPIO | 0x40000000 | 4K | LEDs |
| HWICAP | 0x40001000 | 4K | ICAP control |
| DFX Socket | 0x40002000 | 4K | Decouple/shutdown |
| TDOT CSRs | 0x40010000+ | 64K | Ternary core registers (inside RP) |
| DDR3 | 0x80000000 | 256MB | Data memory |

## FPGA Build

### Step 1: First-time BD creation (Vivado GUI, ONE TIME ONLY)

Open Vivado 2021.2 → Tcl Console, paste:

```tcl
close_project
create_project m2_artix7_tdot FPGA_Vivado/build/m2_artix7_tdot -part xc7a200tfbg484-2 -force
cd C:/A7_M2/EXAMPLES/XDMA_DDR3_V2
read_verilog -sv FPGA_Vivado/hdl/block/tbyte_add.sv
read_verilog -sv FPGA_Vivado/hdl/block/tbyte_mul.sv
read_verilog -sv FPGA_Vivado/hdl/block/tfadd_raw.sv
read_verilog -sv FPGA_Vivado/hdl/block/tfmul_raw.sv
read_verilog -sv FPGA_Vivado/hdl/block/compute_dot_par_raw.sv
read_verilog -sv FPGA_Vivado/hdl/integration/tdot_axi4.sv
read_verilog    FPGA_Vivado/hdl/integration/tdot_axi4_wrapper.v
update_compile_order -fileset sources_1
source FPGA_Vivado/scripts/dfx_partition_tdot.tcl
source FPGA_Vivado/scripts/block_design_top.tcl
make_wrapper -files [get_files xdma_ddr3_dfx.bd] -top -force
save_bd_design
```

### Step 2: Batch build (subsequent runs)

```bash
vivado -mode batch -source FPGA_Vivado/scripts/build_fpga.tcl
```

## Driver Build

### Prerequisites
- Visual Studio 2015 with WDK 10.0.14393.0
- Test signing enabled: `bcdedit /set testsigning on`
- Admin rights for driver installation

### Build
```cmd
cd Driver
build.cmd
```

### Output
```
build/XDMA.sys     — Signed driver
build/XDMA.cat     — Catalog file
build/XDMA.cer     — Certificate
build/XDMA.inf     — INF file
build/test_xdma.exe — Test application
```

## Emulation
```bash
python Driver/emulate_test.py
```

## License
MIT