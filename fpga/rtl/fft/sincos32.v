// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// cos/sin of a 32-bit phase, nco.v's lookup without its accumulator: a new
// phase every clock (time-shared by pfb_tune's users). 2 quadrant bits, a
// 1024-entry quarter-wave table (sin at half-sample offsets) and a
// first-order Taylor step from the next 12 bits; 18-bit outputs, LAT
// clocks after the phase. scripts/tune_model.py sincos() is the same
// arithmetic.

module sincos32 #(
  parameter ROM_FILE = "sincos_qw.mem"
) (
  input  wire               clk,
  input  wire [31:0]        ph,
  output reg  signed [17:0] cos_o = 18'sd0,
  output reg  signed [17:0] sin_o = 18'sd0
);

  localparam integer LAT = 8;

  reg [16:0] rom [0:1023];
  initial $readmemh(ROM_FILE, rom);

  wire [1:0]  q = ph[31:30];
  wire [9:0]  a = ph[29:20];
  wire [11:0] f = ph[19:8];

  // T1: table addresses, signs, Taylor offset d = f - 2048
  reg [9:0]         addr_s = 10'd0, addr_c = 10'd0;
  reg               neg_s1 = 1'b0, neg_c1 = 1'b0;
  reg signed [11:0] d1 = 12'sd0;
  always @(posedge clk) begin
    addr_s <= q[0] ? ~a : a;
    addr_c <= q[0] ? a : ~a;
    neg_s1 <= q[1];
    neg_c1 <= q[1] ^ q[0];
    d1     <= {~f[11], f[10:0]};
  end

  // T2/T3: block RAM read + output register
  reg [16:0] s_rd = 17'd0, c_rd = 17'd0, s_rd2 = 17'd0, c_rd2 = 17'd0;
  always @(posedge clk) begin
    s_rd  <= rom[addr_s];
    c_rd  <= rom[addr_c];
    s_rd2 <= s_rd;
    c_rd2 <= c_rd;
  end

  reg               neg_s2 = 1'b0, neg_c2 = 1'b0, neg_s3 = 1'b0, neg_c3 = 1'b0;
  reg signed [11:0] d2 = 12'sd0, d3 = 12'sd0;
  always @(posedge clk) begin
    neg_s2 <= neg_s1; neg_c2 <= neg_c1;
    neg_s3 <= neg_s2; neg_c3 <= neg_c2;
    d2 <= d1; d3 <= d2;
  end

  // T4: signed table values; m = 201 * d (d in radians ~ 201*d/2^29)
  reg signed [17:0] s0 = 18'sd0, c0 = 18'sd0;
  reg signed [19:0] m = 20'sd0;
  wire signed [19:0] d3x = d3;
  always @(posedge clk) begin
    s0 <= neg_s3 ? -$signed({1'b0, s_rd2}) : $signed({1'b0, s_rd2});
    c0 <= neg_c3 ? -$signed({1'b0, c_rd2}) : $signed({1'b0, c_rd2});
    m  <= (d3x <<< 7) + (d3x <<< 6) + (d3x <<< 3) + d3x;
  end

  // T5..T7: m*c0, m*s0 (A/B, M, P registers), rounded at bit 29
  reg signed [19:0] ma = 20'sd0;
  reg signed [17:0] mbc = 18'sd0, mbs = 18'sd0;
  reg signed [37:0] mmc = 38'sd0, mms = 38'sd0, mpc = 38'sd0, mps = 38'sd0;
  reg signed [17:0] s05 = 18'sd0, c05 = 18'sd0, s06 = 18'sd0, c06 = 18'sd0;
  reg signed [17:0] s07 = 18'sd0, c07 = 18'sd0;
  always @(posedge clk) begin
    ma  <= m;  mbc <= c0;  mbs <= s0;
    mmc <= ma * mbc;
    mms <= ma * mbs;
    mpc <= mmc + 38'sd268435456;
    mps <= mms + 38'sd268435456;
    s05 <= s0;  c05 <= c0;
    s06 <= s05; c06 <= c05;
    s07 <= s06; c07 <= c06;
  end

  wire signed [8:0] corr_s = mpc[37:29];
  wire signed [8:0] corr_c = mps[37:29];

  // T8
  always @(posedge clk) begin
    sin_o <= s07 + corr_s;
    cos_o <= c07 - corr_c;
  end

endmodule

`default_nettype wire
