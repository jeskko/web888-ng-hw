// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// Streaming radix-2² single-path delay-feedback FFT (hw/docs/channelizer.md
// §3.6): N = 2^LOGN complex points, one per enabled clock, without pause;
// natural order in, bit-reversed order out. For LOGN = 11: five stage
// pairs (BF2I, BF2II, twiddle multiply; the last pair's L = 8) and a final
// radix-2 stage. Bit-exact to the fixed-point model's radix-2²
// (web888-dsp `pfbfx`, `FftArch::Radix22`).
//
// `in_idx` is each input sample's position in its frame (0..N-1, in
// order); `out_idx` that of each output sample in the model's in-place
// (bit-reversed) order. A frame's outputs follow its inputs after N - 1
// samples plus the pipeline registers.

module r22sdf_fft #(
  parameter integer W      = 25,
  parameter integer TB     = 18,
  parameter integer LOGN   = 11,
  // bit s: a rounded halving after butterfly stage s (0..LOGN-1)
  parameter integer HALVES = 11'b11110001111,
  // the twiddle stages' tables: TW_PREFIX <pair> ".mem"
  parameter         TW_PREFIX = "pfb_tw_"
) (
  input  wire                 clk,
  input  wire                 ce,
  input  wire signed [W-1:0]  in_re,
  input  wire signed [W-1:0]  in_im,
  input  wire [LOGN-1:0]      in_idx,
  output wire signed [W-1:0]  out_re,
  output wire signed [W-1:0]  out_im,
  output wire [LOGN-1:0]      out_idx
);

  localparam integer PAIRS = LOGN / 2;

  // the stream between blocks: [0] the input; pair i: [3i+1] after
  // BF2I, [3i+2] after BF2II, [3i+3] after the twiddles
  wire signed [W-1:0] re  [0:3*PAIRS+1];
  wire signed [W-1:0] im  [0:3*PAIRS+1];
  wire [LOGN-1:0]     idx [0:3*PAIRS+1];
  assign re[0] = in_re;
  assign im[0] = in_im;
  assign idx[0] = in_idx;

  genvar i;
  generate
    for (i = 0; i < PAIRS; i = i + 1) begin : g_pair
      localparam integer L = (1 << LOGN) >> (2 * i);
      r22_bf #(.W(W), .LOGN(LOGN), .D(L / 2), .HALVE((HALVES >> (2 * i)) & 1), .MJ(0)) bf1 (
        .clk(clk), .ce(ce),
        .in_re(re[3*i]), .in_im(im[3*i]), .in_idx(idx[3*i]),
        .out_re(re[3*i+1]), .out_im(im[3*i+1]), .out_idx(idx[3*i+1]));
      r22_bf #(.W(W), .LOGN(LOGN), .D(L / 4), .HALVE((HALVES >> (2 * i + 1)) & 1), .MJ(1)) bf2 (
        .clk(clk), .ce(ce),
        .in_re(re[3*i+1]), .in_im(im[3*i+1]), .in_idx(idx[3*i+1]),
        .out_re(re[3*i+2]), .out_im(im[3*i+2]), .out_idx(idx[3*i+2]));
      if (L > 4) begin : g_tw
        localparam [7:0] DIGIT = 8'h30 + i;   // at most 10 pairs
        r22_tw #(.W(W), .TB(TB), .LOGN(LOGN), .L(L), .TW_FILE({TW_PREFIX, DIGIT, ".mem"})) tw (
          .clk(clk), .ce(ce),
          .in_re(re[3*i+2]), .in_im(im[3*i+2]), .in_idx(idx[3*i+2]),
          .out_re(re[3*i+3]), .out_im(im[3*i+3]), .out_idx(idx[3*i+3]));
      end else begin : g_none
        assign re[3*i+3] = re[3*i+2];
        assign im[3*i+3] = im[3*i+2];
        assign idx[3*i+3] = idx[3*i+2];
      end
    end
    if (LOGN % 2 == 1) begin : g_last
      r22_bf #(.W(W), .LOGN(LOGN), .D(1), .HALVE((HALVES >> (LOGN - 1)) & 1), .MJ(0)) bf (
        .clk(clk), .ce(ce),
        .in_re(re[3*PAIRS]), .in_im(im[3*PAIRS]), .in_idx(idx[3*PAIRS]),
        .out_re(re[3*PAIRS+1]), .out_im(im[3*PAIRS+1]), .out_idx(idx[3*PAIRS+1]));
      assign out_re = re[3*PAIRS+1];
      assign out_im = im[3*PAIRS+1];
      assign out_idx = idx[3*PAIRS+1];
    end else begin : g_even
      assign out_re = re[3*PAIRS];
      assign out_im = im[3*PAIRS];
      assign out_idx = idx[3*PAIRS];
    end
  endgenerate

endmodule

`default_nettype wire
