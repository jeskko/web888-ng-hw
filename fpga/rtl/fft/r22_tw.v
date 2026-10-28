// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The twiddle multiply after a radix-2² stage pair with blocks of L = 4q
// (hw/docs/channelizer.md §3.6): the sample at r + p·q of a block, for
// quarter p = 0..3, is multiplied by W_L^e, e = 0, 2r, r, 3r, which is
// W_N^(e·N/L) of the FFT's table. Where e·N/L is 0 the sample passes
// unchanged (18-bit twiddles can't hold 1); otherwise
// (a · w) rounded by TB - 1 bits (round half up), saturated to W.
//
// The stage's own table: W_L^e for e < 3L/4 (`TW_FILE`, {re, im} TB bits
// each; rtl/gen/pfb_tw_<pair>.mem from web888-dsp examples/pfbvectors.rs).
// Two cycles of latency.

module r22_tw #(
  parameter integer W    = 25,
  parameter integer TB   = 18,
  parameter integer LOGN = 11,
  parameter integer L    = 2048,
  parameter         TW_FILE = "tw.hex"
) (
  input  wire                 clk,
  input  wire                 ce,
  input  wire signed [W-1:0]  in_re,
  input  wire signed [W-1:0]  in_im,
  input  wire [LOGN-1:0]      in_idx,
  output reg  signed [W-1:0]  out_re = 0,
  output reg  signed [W-1:0]  out_im = 0,
  output reg  [LOGN-1:0]      out_idx = 0
);

  localparam integer LQ = $clog2(L / 4);
  localparam integer NT = 3 * L / 4;

  reg [2*TB-1:0] tw [0:NT-1];
  initial $readmemh(TW_FILE, tw);

  // the exponent from the position in the block
  wire [LQ-1:0] r = in_idx[LQ-1:0];
  wire [1:0]    p = in_idx[LQ+1:LQ];
  wire [LQ+1:0] e = (p == 2'd0) ? {(LQ+2){1'b0}} :
                    (p == 2'd1) ? {1'b0, r, 1'b0} :
                    (p == 2'd2) ? {2'b00, r} :
                                  ({2'b00, r} + {1'b0, r, 1'b0});

  // stage 1: the sample and its twiddle
  reg signed [W-1:0]  a_re = 0, a_im = 0;
  reg signed [TB-1:0] w_re = 0, w_im = 0;
  reg                 pass = 1'b1;
  reg [LOGN-1:0]      idx1 = 0;
  always @(posedge clk)
    if (ce) begin
      a_re <= in_re;
      a_im <= in_im;
      w_re <= tw[e][2*TB-1:TB];
      w_im <= tw[e][TB-1:0];
      pass <= (e == {(LQ+2){1'b0}});
      idx1 <= in_idx;
    end

  // stage 2: multiply, round, saturate
  localparam integer PW = W + TB + 1;
  wire signed [PW-1:0] p_re = a_re * w_re - a_im * w_im;
  wire signed [PW-1:0] p_im = a_re * w_im + a_im * w_re;

  function signed [W-1:0] fit;
    input signed [PW-1:0] v;
    reg signed [PW-1:0] h;
    begin
      h = (v + (1 <<< (TB - 2))) >>> (TB - 1);
      if (h > $signed({{(PW-W+1){1'b0}}, {(W-1){1'b1}}}))
        fit = {1'b0, {(W-1){1'b1}}};
      else if (h < -$signed({{(PW-W){1'b0}}, 1'b1, {(W-1){1'b0}}}))
        fit = {1'b1, {(W-1){1'b0}}};
      else
        fit = h[W-1:0];
    end
  endfunction

  always @(posedge clk)
    if (ce) begin
      out_re  <= pass ? a_re : fit(p_re);
      out_im  <= pass ? a_im : fit(p_im);
      out_idx <= idx1;
    end

endmodule

`default_nettype wire
