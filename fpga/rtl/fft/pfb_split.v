// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The real FFT's split stage (hw/docs/channelizer.md §3.6): from the
// N-point complex FFT Z of the packed branch sums (even + j·odd) to the
// bins of the 2N-point real FFT,
//   X[k] = (Z[k] + Z*[N-k]) / 2 + W_2N^k · (Z[k] - Z*[N-k]) / (2j),
// conjugated (the bank's output), odd bins negated on odd frames (the
// 2x-oversampled bank's phase). One bin per enabled clock, k = 0..N-1 in
// order; bin N (Nyquist, real, half of it above fs/2) is dropped, so a
// frame of N inputs gives N outputs.
//
// The FFT's frames arrive in its bit-reversed order (`in_idx` = in-place
// position). A double buffer holds each frame while the next is written;
// the frame before is read at bit-reversed k and N - k through both
// ports. A frame starts where `in_idx` wraps from N - 1 to 0 (or at the
// first input). `in_odd` and `in_valid` are the frame's parity and
// validity, sampled at its start; `out_valid` carries the latter.
//
// Arithmetic as the fixed-point model (web888-dsp `pfbfx`): sums exact,
// the twiddle product rounded by TB - 1 bits (not saturated), then a
// rounded halving and saturation to W. `out_frame` counts output frames;
// the first (before any input frame was complete) is garbage.

module pfb_split #(
  parameter integer W    = 25,
  parameter integer TB   = 18,
  parameter integer LOGN = 11,
  parameter         TW_FILE = "pfb_split_tw.mem"
) (
  input  wire                 clk,
  input  wire                 ce,
  input  wire signed [W-1:0]  in_re,
  input  wire signed [W-1:0]  in_im,
  input  wire [LOGN-1:0]      in_idx,
  input  wire                 in_odd,
  input  wire                 in_valid,
  output reg  signed [W-1:0]  out_re = 0,
  output reg  signed [W-1:0]  out_im = 0,
  output reg  [LOGN-1:0]      out_k = 0,
  output reg  [15:0]          out_frame = 0,
  output reg                  out_valid = 1'b0
);

  localparam integer N = 1 << LOGN;

  function [LOGN-1:0] bitrev;
    input [LOGN-1:0] v;
    integer b;
    begin
      for (b = 0; b < LOGN; b = b + 1) bitrev[b] = v[LOGN-1-b];
    end
  endfunction

  // ---- double buffer: write the frame arriving, read the one before
  reg [2*W-1:0] mem [0:2*N-1];
  reg [2*TB-1:0] tw [0:N];
  initial $readmemh(TW_FILE, tw);

  reg        wsel = 1'b0;
  reg  [1:0] odd_of = 2'b00, valid_of = 2'b00;
  reg [15:0] frames = 0;
  reg [LOGN-1:0] prev_idx = {LOGN{1'b1}};
  wire       first = (in_idx == {LOGN{1'b0}}) && (prev_idx == {LOGN{1'b1}});
  wire       wsel_now = first ? ~wsel : wsel;
  wire [LOGN-1:0] k  = in_idx;           // the bin read now (in order)
  wire [LOGN-1:0] nk = -in_idx;          // N - k, mod N

  // read stage 1: both partners, the twiddle, the bin's bookkeeping
  reg [2*W-1:0]  za = 0, zb = 0;
  reg [2*TB-1:0] w1 = 0;
  reg [LOGN-1:0] k1 = 0;
  reg            odd1 = 1'b0, val1 = 1'b0;
  reg [15:0]     f1 = 0;
  always @(posedge clk)
    if (ce) begin
      mem[{wsel_now, in_idx}] <= {in_re, in_im};
      prev_idx <= in_idx;
      if (first) begin
        odd_of[wsel_now]   <= in_odd;
        valid_of[wsel_now] <= in_valid;
        frames <= frames + 1'b1;
      end
      wsel <= wsel_now;
      za   <= mem[{~wsel_now, bitrev(k)}];
      zb   <= mem[{~wsel_now, bitrev(nk)}];
      w1   <= tw[k];
      k1   <= k;
      odd1 <= odd_of[~wsel_now];
      val1 <= valid_of[~wsel_now];
      f1   <= first ? frames : f1;
    end

  // stage 2: e = Zk + Z*[N-k], o = (Zk - Z*[N-k]) / j, exact
  wire signed [W-1:0] a_re = za[2*W-1:W], a_im = za[W-1:0];
  wire signed [W-1:0] b_re = zb[2*W-1:W], b_im = zb[W-1:0];
  reg signed [W:0]    e_re = 0, e_im = 0, o_re = 0, o_im = 0;
  reg signed [TB-1:0] w_re = 0, w_im = 0;
  reg [LOGN-1:0]      k2 = 0;
  reg                 odd2 = 1'b0, val2 = 1'b0;
  reg [15:0]          f2 = 0;
  always @(posedge clk)
    if (ce) begin
      e_re <= a_re + b_re;          // Zk + conj(Z[N-k])
      e_im <= a_im - b_im;
      // (Zk - conj(Z[N-k])) / j = (d.im, -d.re), d = (a_re - b_re, a_im + b_im)
      o_re <= a_im + b_im;
      o_im <= b_re - a_re;
      w_re <= w1[2*TB-1:TB];
      w_im <= w1[TB-1:0];
      k2   <= k1;
      odd2 <= odd1;
      val2 <= val1;
      f2   <= f1;
    end

  // stage 3: the twiddle product, rounded by TB - 1 bits
  localparam integer PW = W + 1 + TB + 1;
  wire signed [PW-1:0] p_re = o_re * w_re - o_im * w_im;
  wire signed [PW-1:0] p_im = o_re * w_im + o_im * w_re;
  reg signed [PW-1:0]  m_re = 0, m_im = 0;
  reg signed [W:0]     e3_re = 0, e3_im = 0;
  reg [LOGN-1:0]       k3 = 0;
  reg                  odd3 = 1'b0, val3 = 1'b0;
  reg [15:0]           f3 = 0;
  always @(posedge clk)
    if (ce) begin
      m_re  <= (p_re + (1 <<< (TB - 2))) >>> (TB - 1);
      m_im  <= (p_im + (1 <<< (TB - 2))) >>> (TB - 1);
      e3_re <= e_re;
      e3_im <= e_im;
      k3    <= k2;
      odd3  <= odd2;
      val3  <= val2;
      f3    <= f2;
    end

  // stage 4: (e + o') halved, saturated; conjugated; odd bins of odd
  // frames negated (both wrap like the model's W-bit vectors)
  function signed [W-1:0] fit;
    input signed [PW:0] v;
    reg signed [PW:0] h;
    begin
      h = (v + 1) >>> 1;
      if (h > $signed({{(PW-W+2){1'b0}}, {(W-1){1'b1}}}))
        fit = {1'b0, {(W-1){1'b1}}};
      else if (h < -$signed({{(PW-W+1){1'b0}}, 1'b1, {(W-1){1'b0}}}))
        fit = {1'b1, {(W-1){1'b0}}};
      else
        fit = h[W-1:0];
    end
  endfunction

  wire signed [W-1:0] x_re = fit(e3_re + m_re);
  wire signed [W-1:0] x_im = fit(e3_im + m_im);
  wire                flip = odd3 && k3[0];
  wire signed [W-1:0] c_im = -x_im;
  always @(posedge clk)
    if (ce) begin
      out_re    <= flip ? -x_re : x_re;
      out_im    <= flip ? -c_im : c_im;
      out_k     <= k3;
      out_frame <= f3;
      out_valid <= val3;
    end

endmodule

`default_nettype wire
