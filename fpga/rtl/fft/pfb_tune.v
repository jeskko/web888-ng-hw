// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The bins tuner (hw/docs/channelizer.md §3.8): NU receivers at 12 kS/s
// from the channelizer's bins, each a frequency, all time-shared on one
// datapath. scripts/tune_model.py is the bit-exact model.
//
// * Tuning: user u's 48-bit frequency word (f / fs * 2^48, the stock RX
//   NCOs' encoding) through cfg: word 2u its low 32 bits, word 2u + 1
//   {enable, 15'd0, high 16 bits} (written second: it commits). From it,
//   the bin k = round(inc / 2^36) and the offset's phase step at the frame
//   rate, pinc = (inc - k * 2^36) >> 5; the phase restarts at 0.
// * Capture: as the bins stream past (k = 0..2047, one per valid), each
//   user's comparator keeps its bin's sample; at the frame's end all are
//   moved to a shift register for the mixer.
// * Mixer (per frame, a user per clock): x * e^-jp (sincos32), rounded to
//   18 bits (saturating at -6 dBFS), into the user's 128-sample history
//   (block RAM, {user, frame mod 128}); p += pinc. Disabled users store 0.
// * Decimator (after every 5th frame's mixer pass): per user, 120 taps
//   (tune_fir.mem, DC gain 2^18) over the history, one tap a clock on two
//   multipliers; out = (acc + 2^6) >> 7: a full-scale sine reads 2^29, as
//   RX samples. The words {Q, I} go out in user order, a frame of NU, if
//   `run` was set when the pass began (whole frames for the ring writer).

module pfb_tune #(
  parameter integer NU        = 32,
  parameter integer T         = 120,
  parameter         COEF_FILE = "tune_fir.mem",
  parameter         ROM_FILE  = "sincos_qw.mem"
) (
  input  wire               clk,
  input  wire signed [24:0] in_re,
  input  wire signed [24:0] in_im,
  input  wire [10:0]        in_k,
  input  wire               in_valid,

  input  wire               cfg_we,
  input  wire [5:0]         cfg_idx,
  input  wire [31:0]        cfg_data,

  input  wire               run,
  output reg  [63:0]        m_data = 64'd0,
  output reg                m_valid = 1'b0,
  output reg  [31:0]        m_frame = 32'd0     // the pass's frame (tests)
);

  localparam integer UW = $clog2(NU);
  localparam integer LS = 8;                    // sincos32 latency

  // ---------------------------------------------------------------- tuning
  reg [31:0] lo [0:NU-1];
  reg [10:0] bin_r [0:NU-1];
  reg [31:0] pinc_r [0:NU-1];
  reg [NU-1:0] en_r = {NU{1'b0}};
  reg [NU-1:0] prst = {NU{1'b0}};               // phase to restart
  integer i;
  initial for (i = 0; i < NU; i = i + 1) begin
    lo[i] = 32'd0; bin_r[i] = 11'd0; pinc_r[i] = 32'd0;
  end

  // commit in three steps: the word, the rounded bin, the offset
  reg               c1_v = 1'b0, c2_v = 1'b0;
  reg [UW-1:0]      c1_u = 0, c2_u = 0;
  reg               c1_en = 1'b0, c2_en = 1'b0;
  reg [47:0]        c1_inc = 48'd0, c2_inc = 48'd0;
  reg [12:0]        c2_k = 13'd0;
  wire [48:0]       c1_round = {1'b0, c1_inc} + (49'd1 << 35);
  wire [10:0]       c2_kc = c2_k > 13'd2047 ? 11'd2047 : c2_k[10:0];
  wire signed [48:0] c2_d = $signed({1'b0, c2_inc}) - $signed({2'b0, c2_kc, 36'd0});
  always @(posedge clk) begin
    if (cfg_we && !cfg_idx[0] && cfg_idx[5:1] < NU)
      lo[cfg_idx[5:1]] <= cfg_data;
    c1_v   <= cfg_we && cfg_idx[0] && cfg_idx[5:1] < NU;
    c1_u   <= cfg_idx[5:1];
    c1_en  <= cfg_data[31];
    c1_inc <= {cfg_data[15:0], lo[cfg_idx[5:1]]};
    c2_v   <= c1_v;
    c2_u   <= c1_u;
    c2_en  <= c1_en;
    c2_inc <= c1_inc;
    c2_k   <= c1_round[48:36];
    if (c2_v) begin
      bin_r[c2_u]  <= c2_kc;
      pinc_r[c2_u] <= c2_d[36:5];
    end
  end

  // ---------------------------------------------------------------- capture
  reg signed [24:0] r_re = 25'sd0, r_im = 25'sd0;
  reg [10:0]        r_k = 11'd0;
  reg               r_v = 1'b0;
  always @(posedge clk) begin
    r_re <= in_re; r_im <= in_im; r_k <= in_k; r_v <= in_valid;
  end

  reg [49:0] cap [0:NU-1];
  reg [49:0] sh  [0:NU-1];
  initial for (i = 0; i < NU; i = i + 1) begin cap[i] = 50'd0; sh[i] = 50'd0; end
  reg eof = 1'b0;
  always @(posedge clk) begin
    for (i = 0; i < NU; i = i + 1)
      if (r_v && r_k == bin_r[i]) cap[i] <= {r_re, r_im};
    eof <= r_v && r_k == 11'd2047;
  end

  // ---------------------------------------------------------------- mixer
  reg          a_busy = 1'b0;
  reg [UW:0]   a_u = 0;
  reg [6:0]    slot = 7'd0, a_slot = 7'd0;
  reg [2:0]    m5 = 3'd0, a_m5 = 3'd0;
  reg [31:0]   nfr = 32'd0, a_n = 32'd0;
  reg [31:0]   p_r [0:NU-1];
  initial for (i = 0; i < NU; i = i + 1) p_r[i] = 32'd0;

  wire [UW-1:0] u0 = a_u[UW-1:0];
  wire [31:0]   pp = prst[u0] ? 32'd0 : p_r[u0];
  wire          go = a_busy;

  always @(posedge clk) begin
    if (eof) begin
      for (i = 0; i < NU; i = i + 1) sh[i] <= cap[i];
      a_busy <= 1'b1;
      a_u    <= 0;
      a_slot <= slot;
      a_m5   <= m5;
      a_n    <= nfr;
      slot   <= slot + 7'd1;
      m5     <= m5 == 3'd4 ? 3'd0 : m5 + 3'd1;
      nfr    <= nfr + 32'd1;
    end else if (a_busy) begin
      for (i = 0; i < NU - 1; i = i + 1) sh[i] <= sh[i + 1];
      p_r[u0] <= en_r[u0] ? pp + pinc_r[u0] : pp;
      a_u     <= a_u + 1'b1;
      if (a_u == NU - 1) a_busy <= 1'b0;
    end
  end

  // enables and phase restarts: a commit wins over the mixer's clear
  always @(posedge clk) begin
    if (a_busy && !eof) prst[u0] <= 1'b0;
    if (c2_v) begin
      en_r[c2_u] <= c2_en;
      prst[c2_u] <= 1'b1;
    end
  end

  wire signed [17:0] cs, sn;
  sincos32 #(.ROM_FILE(ROM_FILE)) nco (.clk(clk), .ph(pp), .cos_o(cs), .sin_o(sn));

  // the sample, its user and enable, alongside the lookup
  reg [49:0]   t_x  [0:LS-1];
  reg [UW-1:0] t_u  [0:LS-1];
  reg [LS-1:0] t_v = {LS{1'b0}}, t_en = {LS{1'b0}};
  initial for (i = 0; i < LS; i = i + 1) begin t_x[i] = 50'd0; t_u[i] = 0; end
  always @(posedge clk) begin
    t_x[0] <= sh[0];
    t_u[0] <= u0;
    t_v    <= {t_v[LS-2:0], go && !eof};
    t_en   <= {t_en[LS-2:0], en_r[u0]};
    for (i = 1; i < LS; i = i + 1) begin
      t_x[i] <= t_x[i - 1];
      t_u[i] <= t_u[i - 1];
    end
  end

  wire signed [24:0] xr = t_x[LS-1][49:25];
  wire signed [24:0] xi = t_x[LS-1][24:0];

  // products, sums, rounding to 18 bits
  reg signed [42:0] p_rc = 43'sd0, p_is = 43'sd0, p_ic = 43'sd0, p_rs = 43'sd0;
  reg signed [43:0] y_r = 44'sd0, y_i = 44'sd0;
  reg               m1_v = 1'b0, m2_v = 1'b0, m1_en = 1'b0, m2_en = 1'b0;
  reg [UW-1:0]      m1_u = 0, m2_u = 0;
  always @(posedge clk) begin
    p_rc <= xr * cs;  p_is <= xi * sn;
    p_ic <= xi * cs;  p_rs <= xr * sn;
    m1_v <= t_v[LS-1]; m1_en <= t_en[LS-1]; m1_u <= t_u[LS-1];
    y_r  <= p_rc + p_is;
    y_i  <= p_ic - p_rs;
    m2_v <= m1_v; m2_en <= m1_en; m2_u <= m1_u;
  end

  wire signed [43:0] y_rr = (y_r + 44'sd4194304) >>> 23;
  wire signed [43:0] y_ir = (y_i + 44'sd4194304) >>> 23;
  function [17:0] sat18(input signed [43:0] v);
    sat18 = v > 44'sd131071 ? 18'h1ffff : v < -44'sd131072 ? 18'h20000 : v[17:0];
  endfunction

  reg [35:0]   q_d = 36'd0;
  reg          q_v = 1'b0;
  reg [UW-1:0] q_u = 0;
  always @(posedge clk) begin
    q_d <= m2_en ? {sat18(y_rr), sat18(y_ir)} : 36'd0;
    q_v <= m2_v;
    q_u <= m2_u;
  end

  // ---------------------------------------------------------------- history
  reg [35:0] hist [0:NU*128-1];
  initial for (i = 0; i < NU * 128; i = i + 1) hist[i] = 36'd0;
  wire [UW+6:0] h_waddr = {q_u, a_slot};
  always @(posedge clk)
    if (q_v) hist[h_waddr] <= q_d;

  // the pass is done when its last user is written
  reg a_done = 1'b0;
  always @(posedge clk) a_done <= q_v && q_u == NU - 1;

  // ---------------------------------------------------------------- decimator
  reg signed [17:0] coef [0:127];
  initial begin
    for (i = 0; i < 128; i = i + 1) coef[i] = 18'sd0;
    $readmemh(COEF_FILE, coef, 0, T - 1);
  end

  reg          b_busy = 1'b0, b_emit = 1'b0;
  reg [UW-1:0] b_u = 0;
  reg [6:0]    b_j = 7'd0, b_slot = 7'd0;
  always @(posedge clk) begin
    if (a_done && a_m5 == 3'd4 && !b_busy) begin
      b_busy  <= 1'b1;
      b_u     <= 0;
      b_j     <= 7'd0;
      b_slot  <= a_slot;
      b_emit  <= run;
      m_frame <= a_n;
    end else if (b_busy) begin
      if (b_j == T - 1) begin
        b_j <= 7'd0;
        b_u <= b_u + 1'b1;
        if (b_u == NU - 1) b_busy <= 1'b0;
      end else
        b_j <= b_j + 7'd1;
    end
  end

  // read: history (2 clocks) and taps, aligned; then M, then the sum (a
  // tap issued in clock c is in M after c + 3: the tags' third stage)
  wire [UW+6:0] h_raddr = {b_u, b_slot - b_j};
  reg [35:0]  h_rd = 36'd0, h_rd2 = 36'd0;
  reg signed [17:0] c_rd = 18'sd0, c_rd2 = 18'sd0;
  reg [2:0]   s_v = 3'd0, s_first = 3'd0, s_last = 3'd0;
  always @(posedge clk) begin
    h_rd    <= hist[h_raddr];
    h_rd2   <= h_rd;
    c_rd    <= coef[b_j];
    c_rd2   <= c_rd;
    s_v     <= {s_v[1:0], b_busy};
    s_first <= {s_first[1:0], b_busy && b_j == 7'd0};
    s_last  <= {s_last[1:0], b_busy && b_j == T - 1};
  end

  wire signed [17:0] hr = h_rd2[35:18];
  wire signed [17:0] hi = h_rd2[17:0];
  reg signed [35:0] mr = 36'sd0, mi = 36'sd0;
  reg signed [47:0] acc_r = 48'sd0, acc_i = 48'sd0;
  reg               e_v = 1'b0;
  always @(posedge clk) begin
    mr <= c_rd2 * hr;
    mi <= c_rd2 * hi;
    if (s_v[2]) begin
      acc_r <= s_first[2] ? mr : acc_r + mr;
      acc_i <= s_first[2] ? mi : acc_i + mi;
    end
    e_v <= s_v[2] && s_last[2];
  end

  wire signed [47:0] o_r = (acc_r + 48'sd64) >>> 7;
  wire signed [47:0] o_i = (acc_i + 48'sd64) >>> 7;
  always @(posedge clk) begin
    // b_emit holds for the whole pass (the next starts 5 frames later)
    m_valid <= e_v && b_emit;
    m_data  <= {o_i[31:0], o_r[31:0]};
  end

endmodule

`default_nettype wire
