// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps

// Minimal behavioural stand-ins for the Xilinx primitives used in rtl/.
// Simulation only -- Vivado uses the real UNISIM library.

module IBUFDS (input wire I, input wire IB, output wire O);
  assign O = I;
endmodule

module BUFG (input wire I, output wire O);
  assign O = I;
endmodule

module PLLE2_BASE #(
  parameter real    CLKIN1_PERIOD  = 10.0,
  parameter integer CLKFBOUT_MULT  = 8,
  parameter integer DIVCLK_DIVIDE  = 1,
  parameter integer CLKOUT0_DIVIDE = 8,
  parameter         BANDWIDTH      = "OPTIMIZED"
) (
  input  wire CLKIN1, CLKFBIN, PWRDWN, RST,
  output wire CLKFBOUT, CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5,
  output reg  LOCKED
);
  // pass-through (MULT == DIVIDE in this design)
  assign CLKOUT0  = CLKIN1;
  assign CLKFBOUT = CLKIN1;
  assign {CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5} = 5'd0;
  integer n = 0;
  initial LOCKED = 1'b0;
  always @(posedge CLKIN1) begin
    n = n + 1;
    if (n == 20) LOCKED <= 1'b1;
  end
endmodule

module DNA_PORT #(
  parameter [56:0] SIM_DNA_VALUE = 57'h0
) (
  output wire DOUT,
  input  wire CLK, DIN, READ, SHIFT
);
  reg [56:0] sr = 57'h0;
  assign DOUT = sr[56];
  always @(posedge CLK)
    if (READ)       sr <= SIM_DNA_VALUE;
    else if (SHIFT) sr <= {sr[55:0], DIN};
endmodule
