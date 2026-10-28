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
// frame's parity (the model's frame count). Latency: 6 clocks after the
// frame's last sample to its first output.

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
      for (i = 0; i < T; i = i + 1) sel1[i] <= bank_of(i, jb, hb);
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

  // stage 3: products; stage 4: sums (exact)
  localparam integer PW = WI + CB;
  localparam integer AW = PW + $clog2(T) + 1;
  reg signed [PW-1:0] pe [0:T-1];
  reg signed [PW-1:0] po [0:T-1];
  reg signed [AW-1:0] ae = 0, ao = 0;
  reg [LD-1:0] k3 = 0, k4 = 0;
  reg          v3 = 1'b0, v4 = 1'b0, odd3 = 1'b0, odd4 = 1'b0;
  reg signed [AW-1:0] se, so;
  always @(posedge clk)
    if (ce) begin
      for (i = 0; i < T; i = i + 1) begin
        pe[i] <= xe[i] * ce_[i];
        po[i] <= xo[i] * co_[i];
      end
      k3 <= k2; v3 <= v2; odd3 <= odd2;
      se = 0;
      so = 0;
      for (i = 0; i < T; i = i + 1) begin
        se = se + pe[i];
        so = so + po[i];
      end
      ae <= se;
      ao <= so;
      k4 <= k3; v4 <= v3; odd4 <= odd3;
    end

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
