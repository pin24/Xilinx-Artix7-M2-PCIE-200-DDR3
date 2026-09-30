// flash_access_top.sv — MINIMAL design that does NOT claim the QSPI flash
// config pins (FCS_B/D00-D03) as user IO. Purpose: load this into the FPGA
// (volatile, via JTAG) to release the flash pins back to the configuration
// controller, so that scripts/flash_program.tcl can fully program the SPI
// flash. The full design (xdma_ddr3_core_top with spi_over_pcie) claims those
// pins as user IO -> while it is loaded, cfgmem programming fails with
// Labtools 27-3347. This minimal netlist does NOT instantiate spi_over_pcie
// and exposes only a harmless clock/LED so the cell is configurable.
module flash_access_top (
    input  wire clk50,
    output wire [3:0] led_o
);
    assign led_o = 4'b0000;
endmodule