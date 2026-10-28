// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// ADC clock input -> PLL (zero-delay, feedback through BUFG) -> fabric clock.
// The PLL compensates the clock tree so ADC data captured in IOB registers
// keeps the board's source-synchronous timing (as in red-pitaya-notes).
//
// VCO must stay in 800..1600 MHz (-1 speed grade). One configuration cannot
// cover all ADC clocks the server uses, hence two builds (like the vendor's
// websdr_hf.bit / websdr_vhf.bit):
//   HF : 122.88 MHz, MULT = DIV = 8   -> VCO 983 MHz
//   VHF: 61.44 .. 110.592 MHz, MULT = DIV = 14 -> VCO 860 .. 1548 MHz

module clk_gen #(
  parameter integer CLKIN_PERIOD_PS = 8138,
  parameter integer MULT            = 8
) (
  input  wire clk_p,
  input  wire clk_n,
  output wire clk,
  output wire locked,
  // the ADC clock before the PLL (for the liveness bits only)
  output wire clk_raw
);

  localparam real CLKIN_PERIOD = CLKIN_PERIOD_PS / 1000.0;

  wire clk_ibuf, clk_pll, fb_pll, fb_bufg;

  IBUFDS ibufds (.I(clk_p), .IB(clk_n), .O(clk_ibuf));

  PLLE2_BASE #(
    .CLKIN1_PERIOD(CLKIN_PERIOD),
    .CLKFBOUT_MULT(MULT),
    .DIVCLK_DIVIDE(1),
    .CLKOUT0_DIVIDE(MULT),
    .BANDWIDTH("OPTIMIZED")
  ) pll (
    .CLKIN1(clk_ibuf),
    .CLKFBIN(fb_bufg),
    .CLKFBOUT(fb_pll),
    .CLKOUT0(clk_pll),
    .CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
    .LOCKED(locked),
    .PWRDWN(1'b0),
    .RST(1'b0)
  );

  BUFG bufg_fb  (.I(fb_pll),  .O(fb_bufg));
  BUFG bufg_clk (.I(clk_pll), .O(clk));
  BUFG bufg_raw (.I(clk_ibuf), .O(clk_raw));

endmodule

`default_nettype wire
