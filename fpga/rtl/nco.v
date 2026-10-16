// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// Numerically controlled oscillator: 48-bit phase accumulator, cos/sin out.
//
// Phase word: inc = f / fs * 2^48 (same encoding the server/driver use).
// Lookup: 12-bit phase index (2 quadrant bits + 1024-entry quarter-wave
// table holding sin at half-sample offsets) plus first-order Taylor
// correction from the next 12 phase bits:
//   sin(t0 + d) ~ s0 + d*c0,  cos(t0 + d) ~ c0 - d*s0
// Residual phase error <= (2*pi/8192)^2 / 2 (~ -130 dBc); amplitude
// quantisation is 18 bit. Resources: 1 x RAMB18 (dual port), 2 x DSP48.
// Latency from acc to outputs: 8 clocks (constant, irrelevant for mixing).

module nco #(
  parameter ROM_FILE = "sincos_qw.mem"
) (
  input  wire               clk,
  input  wire               rst,
  input  wire [47:0]        inc,
  output reg  signed [17:0] cos_o,
  output reg  signed [17:0] sin_o
);

  reg [16:0] rom [0:1023];
  initial $readmemh(ROM_FILE, rom);

  // T0: phase accumulator
  reg [47:0] acc;
  always @(posedge clk)
    if (rst) acc <= 48'd0;
    else     acc <= acc + inc;

  wire [1:0]  q = acc[47:46];
  wire [9:0]  a = acc[45:36];
  wire [11:0] f = acc[35:24];

  // T1: table addresses, signs, Taylor offset d = f - 2048 (in 1/4096 steps)
  reg [9:0]         addr_s, addr_c;
  reg               neg_s1, neg_c1;
  reg signed [11:0] d1;
  always @(posedge clk) begin
    addr_s <= q[0] ? ~a : a;
    addr_c <= q[0] ? a : ~a;
    neg_s1 <= q[1];
    neg_c1 <= q[1] ^ q[0];
    d1     <= {~f[11], f[10:0]};
  end

  // T2/T3: block RAM read + output register
  reg [16:0] s_rd, c_rd, s_rd2, c_rd2;
  always @(posedge clk) begin
    s_rd  <= rom[addr_s];
    c_rd  <= rom[addr_c];
    s_rd2 <= s_rd;
    c_rd2 <= c_rd;
  end

  reg               neg_s2, neg_c2, neg_s3, neg_c3;
  reg signed [11:0] d2, d3;
  always @(posedge clk) begin
    neg_s2 <= neg_s1; neg_c2 <= neg_c1;
    neg_s3 <= neg_s2; neg_c3 <= neg_c2;
    d2 <= d1; d3 <= d2;
  end

  // T4: signed table values; d in radians: d_rad = 2*pi*d/2^24 ~ 201*d/2^29
  reg signed [17:0] s0, c0;
  reg signed [19:0] m;
  wire signed [19:0] d3x = d3;
  always @(posedge clk) begin
    s0 <= neg_s3 ? -$signed({1'b0, s_rd2}) : $signed({1'b0, s_rd2});
    c0 <= neg_c3 ? -$signed({1'b0, c_rd2}) : $signed({1'b0, c_rd2});
    m  <= (d3x <<< 7) + (d3x <<< 6) + (d3x <<< 3) + d3x;
  end

  // T5..T7: two DSP multipliers m*c0, m*s0 (A/B, M, P registers)
  reg signed [19:0] ma;
  reg signed [17:0] mbc, mbs;
  reg signed [37:0] mmc, mms, mpc, mps;
  reg signed [17:0] s05, c05, s06, c06, s07, c07;
  always @(posedge clk) begin
    ma  <= m;  mbc <= c0;  mbs <= s0;
    mmc <= ma * mbc;
    mms <= ma * mbs;
    mpc <= mmc + 38'sd268435456;   // + 2^28: round at bit 29
    mps <= mms + 38'sd268435456;
    s05 <= s0;  c05 <= c0;
    s06 <= s05; c06 <= c05;
    s07 <= s06; c07 <= c06;
  end

  wire signed [8:0] corr_s = mpc[37:29];  // d*c0, |.| < 128
  wire signed [8:0] corr_c = mps[37:29];  // d*s0

  // T8: outputs
  always @(posedge clk) begin
    sin_o <= s07 + corr_s;
    cos_o <= c07 - corr_c;
  end

endmodule

`default_nettype wire
