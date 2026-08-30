# ADR-002: DFX Architecture for Ternary Core

## Status
Accepted (2026-08-30)

## Context
Ternary core (tdot_axi4) needs to be updatable without PCIe reset.

## Decision
Use DFX (Dynamic Function eXchange) with:
- Static region: XDMA, MIG, HWICAP, GPIO, DFX Socket
- Reconfigurable partition: tdot_axi4
- Partial bitstream loaded via HWICAP over PCIe

## Consequences
- FPGA reconfiguration without host reboot
- Complex DFX socket management (decouple/shutdown sequence)
- Additional routing resources for DFX