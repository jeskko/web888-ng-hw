// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The channelizer's full-band power line (hw/docs/channelizer.md §3.7):
// |X|^2 of every bin summed over `frames` frames (one line), exact in 64
// bits, then each sum as an IEEE float32 (truncated, not rounded: the
// fixed-point model's `power_f32`). Bins come one per enabled clock, k =
// 0..N-1 in order (pfb_chain). A line goes out in chunks of 128 bins:
//   header  {16'h5042, 4'd2, chunk[3:0], 8'd0, line[31:0]}
//   64 words {f32[2j+1], f32[2j]}   (the even bin low)
// `s_first` marks the headers (axi_ring_writer VARLEN). `frames` and
// `enable` are taken at a line's start; `frames` = 0 is off.
//
// The sums live in one RAM of N words (read, add, write back, the same
// bin a frame later); the line's first frame starts from 0 instead of
// what is there, its last sends the sums out instead of keeping them.

module pfb_power #(
  parameter integer W    = 25,
  parameter integer LOGN = 11
) (
  input  wire                clk,
  input  wire                ce,
  input  wire                enable,
  input  wire [15:0]         frames,
  input  wire signed [W-1:0] in_re,
  input  wire signed [W-1:0] in_im,
  input  wire [LOGN-1:0]     in_k,
  input  wire                in_valid,

  output reg  [63:0]         s_data = 64'd0,
  output reg                 s_valid = 1'b0,
  output reg                 s_first = 1'b0
);

  localparam integer N = 1 << LOGN;

  // ---- lines: the frame's place in its line
  wire        start = ce && in_valid && (in_k == 0);
  reg  [15:0] n_line = 16'd0;                // frames in the current line
  reg  [15:0] fcnt = 16'd0;                  // this frame's index in it
  reg         on = 1'b0;                     // the line runs
  reg  [31:0] line = 32'd0;
  // at a frame's start: does a line begin here, is this its last frame
  wire        begin_now = start && (!on || fcnt + 1'b1 >= n_line);
  wire        on_now  = begin_now ? (enable && frames != 0) : on;
  wire [15:0] n_now   = begin_now ? frames : n_line;
  wire [15:0] f_now   = begin_now ? 16'd0 : (start ? fcnt + 1'b1 : fcnt);
  always @(posedge clk)
    if (ce && start) begin
      if (begin_now && on) line <= line + 1'b1;
      on     <= on_now;
      n_line <= n_now;
      fcnt   <= f_now;
    end

  // ---- stage 1: inputs, the RAM read
  reg signed [W-1:0] r1 = 0, i1 = 0;
  reg [LOGN-1:0]     k1 = 0;
  reg                v1 = 1'b0, first1 = 1'b0, last1 = 1'b0;
  reg [63:0]         acc [0:N-1];
  // read, the RAM's output register, then aligned with the sum
  reg [63:0]         a2 = 64'd0, a3 = 64'd0, a4 = 64'd0, a5 = 64'd0;
  integer ii;
  initial for (ii = 0; ii < N; ii = ii + 1) acc[ii] = 64'd0;
  always @(posedge clk)
    if (ce) begin
      r1     <= in_re;
      i1     <= in_im;
      k1     <= in_k;
      v1     <= in_valid && on_now;
      first1 <= (f_now == 0);
      last1  <= (f_now + 1'b1 >= n_now);
      a2     <= acc[in_k];
      a3     <= a2;
      a4     <= a3;
      a5     <= a4;
    end

  // ---- stages 2-4: the squares (two registers: the DSPs' pipeline),
  // their sum (exact: 2 (W - 1) + 1 bits), the line's sum
  localparam integer PW = 2 * W;
  reg signed [PW-1:0] sr2 = 0, si2 = 0, sr3 = 0, si3 = 0;
  reg [PW-1:0]        p4 = 0;
  reg [LOGN-1:0]      k2 = 0, k3 = 0, k4 = 0, k5s = 0;
  reg                 v2 = 1'b0, v3 = 1'b0, v4 = 1'b0, v5s = 1'b0;
  reg                 f2 = 1'b0, f3 = 1'b0, f4 = 1'b0;
  reg                 l2 = 1'b0, l3 = 1'b0, l4 = 1'b0, l5s = 1'b0;
  reg [63:0]          s5 = 64'd0;
  always @(posedge clk)
    if (ce) begin
      sr2 <= r1 * r1;
      si2 <= i1 * i1;
      sr3 <= sr2;
      si3 <= si2;
      p4  <= sr3 + si3;
      // the sum so far (none in the line's first frame) plus this one
      s5  <= (f4 ? 64'd0 : a5) + p4;
      {k2, v2, f2, l2}   <= {k1, v1, first1, last1};
      {k3, v3, f3, l3}   <= {k2, v2, f2, l2};
      {k4, v4, f4, l4}   <= {k3, v3, f3, l3};
      {k5s, v5s, l5s}    <= {k4, v4, l4};
      if (v5s) acc[k5s] <= s5;
    end

  // ---- stages 6-9: float32, truncated. 5: the leading one's position
  // in four 16-bit groups; 6: the shift; 7, 8: shifted in two steps
  function [4:0] lz16;          // leading zeros of 16 bits (16: none set)
    input [15:0] v;
    integer b;
    begin
      lz16 = 5'd16;
      for (b = 0; b < 16; b = b + 1) if (v[b]) lz16 = 5'd15 - b[4:0];
    end
  endfunction

  reg [63:0] x5 = 0, x6 = 0, x7 = 0;
  reg [4:0]  z5 [0:3];
  reg [5:0]  lz6 = 0, lz7 = 0;
  reg        nz6 = 1'b0, nz7 = 1'b0;
  reg [31:0] f8 = 32'd0;
  wire [63:0] xs = x7 << lz7[2:0];          // the leading one at bit 63
  reg [LOGN-1:0] k5 = 0, k6 = 0, k7 = 0, k8 = 0;
  reg        o5 = 1'b0, o6 = 1'b0, o7 = 1'b0, o8 = 1'b0;  // a line's last frame
  reg [31:0] ln5 = 0, ln6 = 0, ln7 = 0, ln8 = 0;
  integer g;
  initial for (g = 0; g < 4; g = g + 1) z5[g] = 5'd16;
  always @(posedge clk)
    if (ce) begin
      x5 <= s5;
      for (g = 0; g < 4; g = g + 1) z5[g] <= lz16(s5[63 - 16 * g -: 16]);
      // the first group with a one
      x6  <= x5;
      nz6 <= x5 != 64'd0;
      lz6 <= (z5[0] != 16) ? {1'b0, z5[0]} :
             (z5[1] != 16) ? 6'd16 + z5[1] :
             (z5[2] != 16) ? 6'd32 + z5[2] : 6'd48 + z5[3][3:0];
      // shift by the multiple of 8, then the rest
      x7  <= x6 << {lz6[5:3], 3'b000};
      lz7 <= lz6;
      nz7 <= nz6;
      f8  <= nz7 ? {1'b0, 8'd190 - {2'b00, lz7}, xs[62:40]} : 32'd0;
      {k5, o5, ln5} <= {k5s, v5s && l5s, line};
      {k6, o6, ln6} <= {k5, o5, ln5};
      {k7, o7, ln7} <= {k6, o6, ln6};
      {k8, o8, ln8} <= {k7, o7, ln7};
    end

  // ---- out: a header at each 128 bins' start (an even bin's slot, when
  // no word is due), then the floats in pairs
  reg [31:0] even = 32'd0;
  always @(posedge clk)
    if (ce) begin
      s_valid <= 1'b0;
      s_first <= 1'b0;
      if (o8) begin
        if (!k8[0]) even <= f8;
        if (k8[6:0] == 7'd0) begin
          s_data  <= {16'h5042, 4'd2, k8[LOGN-1:7], 8'd0, ln8};
          s_valid <= 1'b1;
          s_first <= 1'b1;
        end else if (k8[0]) begin
          s_data  <= {f8, even};
          s_valid <= 1'b1;
        end
      end
    end

endmodule

`default_nettype wire
