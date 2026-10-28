// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// One radix-2 single-path delay-feedback butterfly of the R2²SDF FFT
// (hw/docs/channelizer.md §3.6), in a stream of one complex sample per
// enabled clock. Blocks of 2D: the first D samples go into the delay line
// (and its stored differences come out); each of the next D is paired with
// its partner D earlier: the sum goes out, the difference into the delay
// line. With MJ (BF2II), samples in the last quarter of each 4D block are
// first multiplied by -j.
//
// Arithmetic as the fixed-point model's radix-2² (web888-dsp `pfbfx`):
// sums and differences exact, then a rounded halving if HALVE, then
// saturation to W bits. `in_idx` is the sample's position in the frame;
// `out_idx` that of the sample going out (in_idx - D, mod N).
//
// Pipelined to one carry chain per clock (122.88 MHz): the input (after
// -j), the exact sums, the halving, then saturation and the output select;
// LAT = 4 clocks from a sample in to its partner's result out. For a long
// D the delay line is the feedback one, shortened by the two registers
// inside the loop (everything entering it is delayed alike). A short one
// (D <= 32, shift registers) cannot hold those two, so there the input and
// the differences get a delay line each.

module r22_bf #(
  parameter integer W     = 25,
  parameter integer LOGN  = 11,
  parameter integer D     = 1024,
  parameter integer HALVE = 0,
  parameter integer MJ    = 0
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

  localparam integer LD = $clog2(D);
  // the 4D block's quarter bit (a BF2II's D is at most N/4, so it exists)
  localparam integer LQ = (LD + 1 < LOGN) ? LD + 1 : LD;
  localparam [LOGN-1:0] DD = D;
  localparam integer SHORT = (D <= 32);

  // round half up by one bit if HALVE (exact, W + 1 bits after)
  function signed [W+1:0] half;
    input signed [W+1:0] v;
    begin
      half = (HALVE != 0) ? ((v + 1) >>> 1) : v;
    end
  endfunction
  // saturate to W bits: out of range where the top three bits differ
  function signed [W-1:0] sat;
    input signed [W+1:0] h;
    begin
      if (h[W+1:W-1] != 3'b000 && h[W+1:W-1] != 3'b111)
        sat = {h[W+1], {(W-1){~h[W+1]}}};
      else
        sat = h[W-1:0];
    end
  endfunction

  // stage 0: the input, times -j in the last quarter of a 4D block (BF2II):
  // (re, im) -> (im, -re); one bit wider
  wire rot = (MJ != 0) && in_idx[LD] && in_idx[LQ];
  reg signed [W:0]    x_re = 0, x_im = 0;
  reg [LOGN-1:0]      idx0 = 0;
  always @(posedge clk)
    if (ce) begin
      x_re <= rot ? {in_im[W-1], in_im} : {in_re[W-1], in_re};
      x_im <= rot ? -{in_re[W-1], in_re} : {in_im[W-1], in_im};
      idx0 <= in_idx;
    end
  // second half of a 2D block
  wire second = idx0[LD];

  // the partner D earlier: a stored input (second half) or, for a long D,
  // a stored difference (first half)
  wire [2*W-1:0] d_out;
  wire signed [W-1:0] d_re = d_out[2*W-1:W];
  wire signed [W-1:0] d_im = d_out[W-1:0];

  // stage 1: sums and differences, exact
  reg signed [W+1:0] s1_re = 0, s1_im = 0, f1_re = 0, f1_im = 0;
  reg [2*W-1:0]      a1 = 0;              // the stored difference (long D)
  reg [2*W-1:0]      x1 = 0;              // the input, to be stored
  reg                sec1 = 1'b0;
  reg [LOGN-1:0]     idx1 = 0;
  // stage 2: halved
  reg signed [W+1:0] s2_re = 0, s2_im = 0, f2_re = 0, f2_im = 0;
  reg [2*W-1:0]      a2 = 0, x2 = 0;
  reg                sec2 = 1'b0;
  reg [LOGN-1:0]     idx2 = 0;
  always @(posedge clk)
    if (ce) begin
      s1_re <= d_re + x_re;
      s1_im <= d_im + x_im;
      f1_re <= d_re - x_re;
      f1_im <= d_im - x_im;
      a1    <= d_out;
      x1    <= {x_re[W-1:0], x_im[W-1:0]};
      sec1  <= second;
      idx1  <= idx0;
      s2_re <= half(s1_re);
      s2_im <= half(s1_im);
      f2_re <= half(f1_re);
      f2_im <= half(f1_im);
      a2    <= a1;
      x2    <= x1;
      sec2  <= sec1;
      idx2  <= idx1;
    end

  // stage 3: saturated; the sum goes out in the second half, the
  // difference D later
  wire signed [W-1:0] sum_re = sat(s2_re), sum_im = sat(s2_im);
  wire signed [W-1:0] dif_re = sat(f2_re), dif_im = sat(f2_im);
  wire [2*W-1:0] late;                    // the difference of D ago
  generate
    if (SHORT) begin : g_short
      // the inputs D ago, straight; the differences delayed by D
      delay_line #(.W(2*W), .D(D)) dx (.clk(clk), .ce(ce),
        .in({x_re[W-1:0], x_im[W-1:0]}), .out(d_out));
      delay_line #(.W(2*W), .D(D)) df (.clk(clk), .ce(ce),
        .in({dif_re, dif_im}), .out(late));
    end else begin : g_long
      // first half: store the input (never rotated there), pass the stored
      // difference; second half: store the difference. Two of the D
      // clocks are the stage 1 and 2 registers.
      delay_line #(.W(2*W), .D(D - 2)) dl (.clk(clk), .ce(ce),
        .in(sec2 ? {dif_re, dif_im} : x2), .out(d_out));
      assign late = a2;
    end
  endgenerate

  always @(posedge clk)
    if (ce) begin
      out_re  <= sec2 ? sum_re : late[2*W-1:W];
      out_im  <= sec2 ? sum_im : late[W-1:0];
      out_idx <= idx2 - DD;
    end

endmodule

`default_nettype wire
