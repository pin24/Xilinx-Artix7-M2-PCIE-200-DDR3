# XDMA DDR3 V2 — Ternary Accelerator (TFloat48)

English | [Русский](README.ru.md)

PCIe Gen2 x4 FPGA accelerator card (M.2) based on Xilinx Artix-7 XC7A200T with DDR3.
Features ternary arithmetic (TFloat48) with partial reconfiguration (DFX).

## Architecture
- **XDMA IP** — PCIe Gen2 x4, 125 MHz, BAR0=128MB, BAR2=256MB
- **DDR3** — 256MB via MIG 7-series
- **TFloat48** — ternary dot product engine (NUM_MAC=32)
- **DFX** — partial reconfiguration via HWICAP
- **AXI HWICAP** — 50 MHz ICAP for bitstream loading

## Repository Structure
```
FPGA_Vivado/       — Vivado project, RTL, scripts, constraints
  scripts/         — block_design_top.tcl, full.tcl, project_config.tcl
  hdl/             — RTL sources (tdot_axi4, compute_dot_par_raw, etc.)
  constraints/     — XDC files (pins, PCIe lanes, pblock)
Driver/            — Windows KMDF driver + test app
  sys/             — driver.c
  exe/             — test_xdma.c
Python/            — Python driver, PyTorch layer
docs/              — Documentation, changelog, devlog
workflows/         — GitHub workflows, issue templates
```

## BAR Address Map
| Peripheral | Address | Size | Description |
|-----------|---------|------|-------------|
| GPIO | 0x40000000 | 4K | LEDs |
| HWICAP | 0x40001000 | 4K | ICAP control |
| DFX Socket | 0x40002000 | 4K | Decouple/shutdown |
| TDOT CSRs | 0x40010000+ | 64K | Ternary core registers |
| DDR3 | 0x80000000 | 256MB | Data memory |

## Build
```bash
# FPGA: Vivado 2021.2
vivado -mode batch -source FPGA_Vivado/scripts/full.tcl

# Driver: Visual Studio 2015 + WDK 10.0.14393
cd Driver && build.cmd
```

## License
MIT