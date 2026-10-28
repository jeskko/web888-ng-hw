// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The channelizer's polyphase FIR (hw/docs/channelizer.md §3.6): M = 2^LOGM
// branches of T taps, 2x oversampled (a frame every D = M/2 samples). One
// 16-bit ADC sample in per enabled clock; out, one per clock, the FFT's
// packed input z[k] = (u[2k], u[2k+1]), k = 0..D-1, where branch r's sum
// for a frame ending at sample z is
//   u[r] = sum_t h[r + t·M] · x[z - r - t·M],
// exact, then rounded down by BSH bits and saturated to W (the fixed-point
// model's branch sums, web888-dsp `pfbfx`).
//
// History: half-blocks of D samples (a frame's new samples), two per word,
// one RAM of D/2 words each (a BRAM36); 2T + 1 of them in rotation, 2T
// being read while the next is written. For a frame, tap t's samples are in
// half-block J - 2t (k < D/2) and J - 2t - 1 (k >= D/2), J the last full
// one, all at word D/2 - 1 - (k mod D/2): every bank reads the same word,
// each tap picks its bank. A word holds offsets {2w, 2w + 1} (high, low):
// the odd branch's sample, then the even branch's.
//
// Coefficients: the prototype is symmetric, so taps t and T - 1 - t share
// ROM t (rtl/gen/pfb_coef_t.mem, from web888-dsp examples/pfbvectors.rs),
// word k = {h[2k+1 + tM], h[2k + tM]}; tap T - 1 - t reads word D - 1 - k
// with its halves swapped.
//
// `out_valid` once 2T half-blocks have been filled; `out_odd` is the
// frame's parity (the model's frame count). Latency: 5 + log2(T) clocks
// after the frame's last sample to its first output.

module pfb_fir #(
  parameter integer WI   = 16,
  parameter integer CB   = 20,
  parameter integer W    = 25,
  parameter integer T    = 11,
  parameter integer LOGM = 12,
  parameter integer BSH  = 11,
  parameter         COEF_PREFIX = "pfb_coef_"
) (
  input  wire                   clk,
  input  wire                   ce,
  input  wire signed [WI-1:0]   adc,
  output reg  signed [W-1:0]    out_re = 0,
  output reg  signed [W-1:0]    out_im = 0,
  output reg  [LOGM-2:0]        out_idx = 0,
  output reg                    out_odd = 1'b0,
  output reg                    out_valid = 1'b0
);

  localparam integer M  = 1 << LOGM;
  localparam integer D  = M / 2;          // samples per half-block = frame step
  localparam integer LD = LOGM - 1;
  localparam integer NB = 2 * T + 1;      // banks
  localparam integer BB = $clog2(NB);
  localparam integer NR = (T + 1) / 2;    // coefficient ROMs

  // ---- write side: the sample position in the half-block, the bank
  reg [LD-1:0]  s = 0;
  reg [BB-1:0]  jb = 0;                   // bank being written
  reg [7:0]     filled = 0;               // half-blocks completed (saturates)
  reg           jpar = 1'b0;              // parity of the frames read now
  reg [WI-1:0]  held = 0;
  wire          last = (s == D - 1);
  always @(posedge clk)
    if (ce) begin
      s <= s + 1'b1;
      if (!s[0]) held <= adc;
      if (last) begin
        jb <= (jb == NB - 1) ? {BB{1'b0}} : jb + 1'b1;
        if (filled != 8'hff) filled <= filled + 1'b1;
        // frames count from the first full history (frame 0 even)
        if (filled >= 2 * T) jpar <= ~jpar;
      end
    end

  // ---- read side: output k = s, for the frame ending with bank jb - 1
  wire [LD-1:0]   k  = s;
  wire            hb = k[LD-1];           // second half: one bank further back
  wire [LD-2:0]   w  = ~k[LD-2:0];        // D/2 - 1 - (k mod D/2)
  // the bank of tap t: (jb - 1 - 2t - hb) mod NB
  function [BB-1:0] bank_of;
    input integer t;
    input [BB-1:0] j;
    input          h;
    integer jj, hh;
    begin
      jj = j;
      hh = h;
      bank_of = (jj + 2 * NB - 1 - 2 * t - hh) % NB;
    end
  endfunction

  // each tap's bank for the first half of a block, (jb - 1 - 2t) mod NB,
  // kept in a register that steps with jb (the second half's is one less)
  reg [BB-1:0] base [0:T-1];
  integer bt;
  initial for (bt = 0; bt < T; bt = bt + 1) base[bt] = bank_of(bt, {BB{1'b0}}, 1'b0);
  always @(posedge clk)
    if (ce && last)
      for (bt = 0; bt < T; bt = bt + 1)
        base[bt] <= (base[bt] == NB - 1) ? {BB{1'b0}} : base[bt] + 1'b1;

  // stage 1: every bank reads word w; the taps' banks, coefficient words
  wire [2*WI-1:0] bank_q [0:NB-1];
  genvar b, t;
  generate
    for (b = 0; b < NB; b = b + 1) begin : g_bank
      reg [2*WI-1:0] mem [0:D/2-1];
      reg [2*WI-1:0] q = 0;
      always @(posedge clk)
        if (ce) begin
          if (jb == b && s[0]) mem[s[LD-1:1]] <= {held, adc};
          q <= mem[w];
        end
      assign bank_q[b] = q;
    end
  endgenerate

  // the word written holds {x[2w], x[2w+1]} = offsets {2w, 2w+1}; the even
  // branch takes offset 2w + 1, the odd branch offset 2w (see above)
  reg [BB-1:0] sel1 [0:T-1];
  reg [LD-1:0] k1 = 0;
  reg          v1 = 1'b0, odd1 = 1'b0;
  integer i;
  always @(posedge clk)
    if (ce) begin
      for (i = 0; i < T; i = i + 1)
        sel1[i] <= !hb ? base[i] : (base[i] == 0) ? NB - 1 : base[i] - 1'b1;
      k1   <= k;
      v1   <= (filled >= 2 * T);
      odd1 <= jpar;
    end

  // coefficients: ROM r serves taps r and T - 1 - r
  wire [2*CB-1:0] rom_a [0:NR-1];
  wire [2*CB-1:0] rom_b [0:NR-1];
  generate
    for (t = 0; t < NR; t = t + 1) begin : g_rom
      localparam [7:0] DIGIT = 8'h30 + t;   // T <= 19: one digit
      reg [2*CB-1:0] rom [0:D-1];
      reg [2*CB-1:0] qa = 0, qb = 0;
      initial $readmemh({COEF_PREFIX, DIGIT, ".mem"}, rom);
      always @(posedge clk)
        if (ce) begin
          qa <= rom[k];
          qb <= rom[~k];                  // D - 1 - k
        end
      assign rom_a[t] = qa;
      assign rom_b[t] = qb;
    end
  endgenerate

  // stage 2: each tap's samples and coefficients
  reg signed [WI-1:0] xe [0:T-1];
  reg signed [WI-1:0] xo [0:T-1];
  reg signed [CB-1:0] ce_ [0:T-1];
  reg signed [CB-1:0] co_ [0:T-1];
  reg [LD-1:0] k2 = 0;
  reg          v2 = 1'b0, odd2 = 1'b0;
  always @(posedge clk)
    if (ce) begin
      for (i = 0; i < T; i = i + 1) begin
        // word {x[2w], x[2w+1]}: even branch = offset 2w+1 (low), odd = 2w (high)
        xe[i] <= bank_q[sel1[i]][WI-1:0];
        xo[i] <= bank_q[sel1[i]][2*WI-1:WI];
        if (i < NR) begin
          // ROM word {h_odd, h_even}
          ce_[i] <= rom_a[i][CB-1:0];
          co_[i] <= rom_a[i][2*CB-1:CB];
        end else begin
          // the partner tap: word D-1-k, halves swapped
          ce_[i] <= rom_b[T-1-i][2*CB-1:CB];
          co_[i] <= rom_b[T-1-i][CB-1:0];
        end
      end
      k2   <= k1;
      v2   <= v1;
      odd2 <= odd1;
    end

  // stage 3: products; then the sums (exact) in a pairwise tree of LV
  // registered levels (one adder per level and clock: 11 taps, 4 levels)
  localparam integer PW = WI + CB;
  localparam integer AW = PW + $clog2(T) + 1;
  localparam integer LV = $clog2(T);
  reg signed [AW-1:0] te [0:(LV+1)*T-1];   // level l, term j at l*T + j
  reg signed [AW-1:0] to [0:(LV+1)*T-1];
  reg [LD-1:0] kd [0:LV];
  reg          vd [0:LV];
  reg          od [0:LV];
  integer l, c;
  initial
    for (l = 0; l <= LV; l = l + 1) begin
      kd[l] = 0; vd[l] = 1'b0; od[l] = 1'b0;
      for (i = 0; i < T; i = i + 1) begin te[l*T + i] = 0; to[l*T + i] = 0; end
    end
  always @(posedge clk)
    if (ce) begin
      for (i = 0; i < T; i = i + 1) begin
        te[i] <= xe[i] * ce_[i];
        to[i] <= xo[i] * co_[i];
      end
      kd[0] <= k2; vd[0] <= v2; od[0] <= odd2;
      c = T;
      for (l = 0; l < LV; l = l + 1) begin
        for (i = 0; i < T; i = i + 1)
          if (2 * i + 1 < c) begin
            te[(l+1)*T + i] <= te[l*T + 2*i] + te[l*T + 2*i + 1];
            to[(l+1)*T + i] <= to[l*T + 2*i] + to[l*T + 2*i + 1];
          end else if (2 * i < c) begin
            te[(l+1)*T + i] <= te[l*T + 2*i];
            to[(l+1)*T + i] <= to[l*T + 2*i];
          end
        c = (c + 1) / 2;
        kd[l+1] <= kd[l]; vd[l+1] <= vd[l]; od[l+1] <= od[l];
      end
    end
  wire signed [AW-1:0] ae = te[LV*T];
  wire signed [AW-1:0] ao = to[LV*T];
  wire [LD-1:0] k4 = kd[LV];
  wire v4 = vd[LV], odd4 = od[LV];

  // stage 5: round down by BSH bits (half up), saturate to W
  function signed [W-1:0] fit;
    input signed [AW-1:0] v;
    reg signed [AW-1:0] h;
    begin
      h = (v + (1 <<< (BSH - 1))) >>> BSH;
      if (h > $signed({{(AW-W+1){1'b0}}, {(W-1){1'b1}}}))
        fit = {1'b0, {(W-1){1'b1}}};
      else if (h < -$signed({{(AW-W){1'b0}}, 1'b1, {(W-1){1'b0}}}))
        fit = {1'b1, {(W-1){1'b0}}};
      else
        fit = h[W-1:0];
    end
  endfunction

  always @(posedge clk)
    if (ce) begin
      out_re    <= fit(ae);
      out_im    <= fit(ao);
      out_idx   <= k4;
      out_valid <= v4;
      out_odd   <= odd4;
    end

endmodule

`default_nettype wire
