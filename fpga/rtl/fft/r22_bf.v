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

  // second half of a 2D block; last quarter of a 4D block (BF2II's -j)
  wire second = in_idx[LD];
  wire rot    = (MJ != 0) && in_idx[LD] && in_idx[LQ];

  // the input, times -j where due: (re, im) -> (im, -re); one bit wider
  wire signed [W:0] x_re = rot ? {in_im[W-1], in_im} : {in_re[W-1], in_re};
  wire signed [W:0] x_im = rot ? -{in_re[W-1], in_re} : {in_im[W-1], in_im};

  wire [2*W-1:0] d_out;
  wire signed [W-1:0] d_re = d_out[2*W-1:W];
  wire signed [W-1:0] d_im = d_out[W-1:0];

  // round half up by one bit if HALVE, then saturate to W bits
  function signed [W-1:0] fit;
    input signed [W+1:0] v;
    reg signed [W+1:0] h;
    begin
      h = (HALVE != 0) ? ((v + 1) >>> 1) : v;
      if (h > $signed({{3{1'b0}}, {(W-1){1'b1}}}))  // 2^(W-1) - 1, W+2 bits
        fit = {1'b0, {(W-1){1'b1}}};
      else if (h < -$signed({{2{1'b0}}, 1'b1, {(W-1){1'b0}}}))
        fit = {1'b1, {(W-1){1'b0}}};
      else
        fit = h[W-1:0];
    end
  endfunction

  wire signed [W+1:0] s_re = d_re + x_re;
  wire signed [W+1:0] s_im = d_im + x_im;
  wire signed [W+1:0] f_re = d_re - x_re;
  wire signed [W+1:0] f_im = d_im - x_im;
  wire signed [W-1:0] sum_re = fit(s_re), sum_im = fit(s_im);
  wire signed [W-1:0] dif_re = fit(f_re), dif_im = fit(f_im);

  // first half: store the input (never rotated there), pass the stored
  // difference; second half: pass the sum, store the difference
  wire [2*W-1:0] d_in = second ? {dif_re, dif_im} : {x_re[W-1:0], x_im[W-1:0]};

  delay_line #(.W(2*W), .D(D)) dl (.clk(clk), .ce(ce), .in(d_in), .out(d_out));

  always @(posedge clk)
    if (ce) begin
      out_re  <= second ? sum_re : d_re;
      out_im  <= second ? sum_im : d_im;
      out_idx <= in_idx - DD;
    end

endmodule

`default_nettype wire
