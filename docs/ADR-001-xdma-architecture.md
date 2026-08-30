# ADR-001: XDMA-based PCIe Architecture

## Status
Accepted (2026-08-30)

## Context
FPGA accelerator card requires PCIe DMA for data transfer between host and DDR3.

## Decision
Use Xilinx XDMA IP core (v4.1) with:
- 4-lane PCIe Gen2 (5.0 GT/s)
- BAR0 = 128MB for AXI-Lite control
- BAR2 = 256MB for DDR3 access
- pciebar2axibar_axil_master = 0x40000000

## Consequences
- Standard Xilinx driver support (Linux + Windows)
- DFX partial reconfiguration via HWICAP
- BAR0 covers all AXI-Lite peripherals