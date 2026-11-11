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
// position). A double buffer (two block RAMs) holds each frame while the
// next is written; the frame before is read at bit-reversed k and N - k
// through both ports. The twiddles are a quarter-wave table. A frame
// starts where `in_idx` wraps from N - 1 to 0 (or at the first input). `in_odd` and `in_valid` are the frame's parity and
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

  // ---- double buffer: two memories of N words, one written with the frame
  // arriving (wsel_now), the other read for the frame before
  (* ram_style = "block" *) reg [2*W-1:0] mem0 [0:N-1];
  (* ram_style = "block" *) reg [2*W-1:0] mem1 [0:N-1];
  // twiddles: a quarter wave, W_2N^k for k < N/2 (k >= N/2 is (im, -re) of k - N/2)
  (* rom_style = "block" *) reg [2*TB-1:0] tw [0:N/2-1];
  initial $readmemh(TW_FILE, tw, 0, N/2-1);

  reg        wsel = 1'b0;
  reg  [1:0] odd_of = 2'b00, valid_of = 2'b00;
  reg [15:0] frames = 0;
  reg [LOGN-1:0] prev_idx = {LOGN{1'b1}};
  wire       first = (in_idx == {LOGN{1'b0}}) && (prev_idx == {LOGN{1'b1}});
  wire       wsel_now = first ? ~wsel : wsel;
  wire [LOGN-1:0] k  = in_idx;           // the bin read now (in order)
  wire [LOGN-1:0] nk = -in_idx;          // N - k, mod N

  // port A of a memory writes at in_idx while it is the one being written,
  // else reads bitrev(k); port B reads bitrev(nk)
  wire            wr0 = ~wsel_now, wr1 = wsel_now;
  wire [LOGN-1:0] aa0 = wr0 ? in_idx : bitrev(k);
  wire [LOGN-1:0] aa1 = wr1 ? in_idx : bitrev(k);
  wire [LOGN-1:0] ab  = bitrev(nk);
  reg [2*W-1:0]   qa0 = 0, qa1 = 0, qb0 = 0, qb1 = 0;
  always @(posedge clk)
    if (ce) begin
      if (wr0) mem0[aa0] <= {in_re, in_im};
      else     qa0 <= mem0[aa0];
    end
  always @(posedge clk)
    if (ce) begin
      if (wr1) mem1[aa1] <= {in_re, in_im};
      else     qa1 <= mem1[aa1];
    end
  always @(posedge clk)
    if (ce) qb0 <= mem0[ab];
  always @(posedge clk)
    if (ce) qb1 <= mem1[ab];

  // read stage 1: the memories' and the twiddle ROM's output registers, the
  // bin's bookkeeping
  reg [2*TB-1:0] wq = 0;
  reg            rsel0 = 1'b0, kh0 = 1'b0;
  reg [LOGN-1:0] k0 = 0;
  reg            odd0 = 1'b0, val0 = 1'b0;
  reg [15:0]     f0 = 0;
  always @(posedge clk)
    if (ce) begin
      prev_idx <= in_idx;
      if (first) begin
        odd_of[wsel_now]   <= in_odd;
        valid_of[wsel_now] <= in_valid;
        frames <= frames + 1'b1;
      end
      wsel <= wsel_now;
      wq    <= tw[k[LOGN-2:0]];
      kh0   <= k[LOGN-1];
      rsel0 <= ~wsel_now;                // the memory read
      k0    <= k;
      odd0  <= odd_of[~wsel_now];
      val0  <= valid_of[~wsel_now];
      f0    <= first ? frames : f0;
    end

  // read stage 2: pick the memory read, unfold the twiddle
  reg [2*W-1:0]  za = 0, zb = 0;
  reg [2*TB-1:0] w1 = 0;
  reg [LOGN-1:0] k1 = 0;
  reg            odd1 = 1'b0, val1 = 1'b0;
  reg [15:0]     f1 = 0;
  always @(posedge clk)
    if (ce) begin
      za   <= rsel0 ? qa1 : qa0;
      zb   <= rsel0 ? qb1 : qb0;
      w1   <= kh0 ? {wq[TB-1:0], -wq[2*TB-1:TB]} : wq;   // k >= N/2: (im, -re)
      k1   <= k0;
      odd1 <= odd0;
      val1 <= val0;
      f1   <= f0;
    end

  // stage 3: e = Zk + Z*[N-k], o = (Zk - Z*[N-k]) / j, exact
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

  // stages 4-9, one carry chain each (122.88 MHz): the four products
  // (DSP48), their sums, the product rounded by TB - 1 bits (not
  // saturated), e + o', its halving and saturation, then conjugation and
  // the odd bins' sign on odd frames (both wrap like the model's W-bit
  // vectors)
  localparam integer PW = W + 1 + TB + 1;     // the sums of products
  localparam integer MW = PW - TB + 1;        // after the rounding shift
  localparam integer TW = MW + 1;             // e + o'
  localparam integer DL = 5;                  // stages 4..8 before the output
  reg signed [W+1+TB-1:0] q_rr = 0, q_ii = 0, q_ri = 0, q_ir = 0;
  reg signed [PW-1:0]     p_re = 0, p_im = 0;
  reg signed [MW-1:0]     m_re = 0, m_im = 0;
  reg signed [TW-1:0]     t_re = 0, t_im = 0;
  reg signed [W-1:0]      x_re = 0, x_im = 0;
  // e and the bookkeeping, delayed alongside
  reg signed [W:0]        ed_re [0:2];
  reg signed [W:0]        ed_im [0:2];
  reg [LOGN-1:0]          kd [0:DL-1];
  reg                     oddd [0:DL-1];
  reg                     vald [0:DL-1];
  reg [15:0]              fd [0:DL-1];
  integer n;
  initial
    for (n = 0; n < DL; n = n + 1) begin
      kd[n] = 0; oddd[n] = 1'b0; vald[n] = 1'b0; fd[n] = 0;
      if (n < 3) begin ed_re[n] = 0; ed_im[n] = 0; end
    end

  function signed [W-1:0] fit;
    input signed [TW-1:0] v;
    reg signed [TW-1:0] h;
    begin
      h = (v + 1) >>> 1;
      if (h > $signed({{(TW-W+1){1'b0}}, {(W-1){1'b1}}}))
        fit = {1'b0, {(W-1){1'b1}}};
      else if (h < -$signed({{(TW-W){1'b0}}, 1'b1, {(W-1){1'b0}}}))
        fit = {1'b1, {(W-1){1'b0}}};
      else
        fit = h[W-1:0];
    end
  endfunction

  always @(posedge clk)
    if (ce) begin
      // 4: products
      q_rr <= o_re * w_re;
      q_ii <= o_im * w_im;
      q_ri <= o_re * w_im;
      q_ir <= o_im * w_re;
      // 5: sums
      p_re <= q_rr - q_ii;
      p_im <= q_ri + q_ir;
      // 6: rounded
      m_re <= (p_re + (1 <<< (TB - 2))) >>> (TB - 1);
      m_im <= (p_im + (1 <<< (TB - 2))) >>> (TB - 1);
      // 7: e + o' (e from stage 3, three stages back)
      t_re <= ed_re[2] + m_re;
      t_im <= ed_im[2] + m_im;
      // 8: halved, saturated
      x_re <= fit(t_re);
      x_im <= fit(t_im);
      // 9: conjugated, odd bins of odd frames negated
      out_re    <= (oddd[DL-1] && kd[DL-1][0]) ? -x_re : x_re;
      out_im    <= (oddd[DL-1] && kd[DL-1][0]) ? x_im : -x_im;
      out_k     <= kd[DL-1];
      out_frame <= fd[DL-1];
      out_valid <= vald[DL-1];
      ed_re[0] <= e_re; ed_im[0] <= e_im;
      for (n = 1; n < 3; n = n + 1) begin ed_re[n] <= ed_re[n-1]; ed_im[n] <= ed_im[n-1]; end
      kd[0] <= k2; oddd[0] <= odd2; vald[0] <= val2; fd[0] <= f2;
      for (n = 1; n < DL; n = n + 1) begin
        kd[n] <= kd[n-1]; oddd[n] <= oddd[n-1]; vald[n] <= vald[n-1]; fd[n] <= fd[n-1];
      end
    end

endmodule

`default_nettype wire
