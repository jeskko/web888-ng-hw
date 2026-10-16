// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// Shared (time-multiplexed) back end for all RX paths:
//   CIC1 combs (N=3, 36 bit)  ->  CIC2 integrators (N=5, 62 bit)
//   -> decimate by R2 (1..63; driver uses 5..40)  ->  CIC2 combs (N=5)
//   -> gain normalisation to a fixed output scale -> s32 tokens.
//
// Output scale: a full-scale DC input (+-2^15 ADC, NCO amplitude ~1) maps to
// +-2^30, independent of R2 (server: RXOUT_SCALE = 30). A full-scale real
// sine therefore gives |I + jQ| = 2^29.
// Path order is preserved: ch0 I, ch0 Q, ch1 I, ... once per output sample.

module rx_serial_cic #(
  parameter integer NPATH = 24,
  parameter         Q_NEG = 1      // Q = -adc*sin  ->  x * exp(-j w n)
) (
  input  wire               clk,
  input  wire               rst,
  input  wire [5:0]         r2,

  input  wire               in_valid,
  input  wire [4:0]         in_path,
  input  wire signed [35:0] in_data,

  output reg                out_valid,
  output reg  [4:0]         out_path,
  output reg  signed [31:0] out_data
);

  // ---- CIC1 combs (pruned widths 36/35/34 -> use 36 throughout)
  wire        c1v0, c1v1, c1v2;
  wire [4:0]  c1p0, c1p1, c1p2;
  wire signed [35:0] c1d0, c1d1, c1d2;

  cic_serial_comb #(.W(36)) c1_0 (.clk(clk), .rst(rst),
    .in_valid(in_valid), .in_path(in_path), .in_data(in_data),
    .out_valid(c1v0), .out_path(c1p0), .out_data(c1d0));
  cic_serial_comb #(.W(36)) c1_1 (.clk(clk), .rst(rst),
    .in_valid(c1v0), .in_path(c1p0), .in_data(c1d0),
    .out_valid(c1v1), .out_path(c1p1), .out_data(c1d1));
  cic_serial_comb #(.W(36)) c1_2 (.clk(clk), .rst(rst),
    .in_valid(c1v1), .in_path(c1p1), .in_data(c1d1),
    .out_valid(c1v2), .out_path(c1p2), .out_data(c1d2));

  // CIC1 output: bits [47:16] of full precision, full scale +-2^31
  wire signed [61:0] x2 = {{30{c1d2[35]}}, c1d2[35:4]};

  // ---- CIC2 integrators
  wire        iv [0:5];
  wire [4:0]  ip [0:5];
  wire signed [61:0] id [0:5];
  assign iv[0] = c1v2;
  assign ip[0] = c1p2;
  assign id[0] = x2;

  genvar k;
  generate
    for (k = 0; k < 5; k = k + 1) begin : integ
      cic_serial_integrator #(.W(62)) st (.clk(clk), .rst(rst),
        .in_valid(iv[k]), .in_path(ip[k]), .in_data(id[k]),
        .out_valid(iv[k+1]), .out_path(ip[k+1]), .out_data(id[k+1]));
    end
  endgenerate

  // ---- decimation by R2: count input frames (one frame = NPATH tokens)
  reg [5:0] dcnt;
  wire      last_tok = iv[5] && (ip[5] == NPATH-1);
  wire      keep     = (dcnt == r2 - 1'b1);

  always @(posedge clk) begin
    if (rst)
      dcnt <= 6'd0;
    else if (last_tok)
      dcnt <= keep ? 6'd0 : dcnt + 1'b1;
  end

  // ---- CIC2 combs
  wire        cv [0:5];
  wire [4:0]  cp [0:5];
  wire signed [61:0] cd [0:5];
  assign cv[0] = iv[5] && keep;
  assign cp[0] = ip[5];
  assign cd[0] = id[5];

  generate
    for (k = 0; k < 5; k = k + 1) begin : comb
      cic_serial_comb #(.W(62)) st (.clk(clk), .rst(rst),
        .in_valid(cv[k]), .in_path(cp[k]), .in_data(cd[k]),
        .out_valid(cv[k+1]), .out_path(cp[k+1]), .out_data(cd[k+1]));
    end
  endgenerate

  // ---- gain normalisation: out = ((y >>> sh1) * g) >>> 9
  wire [5:0]  gain_sh1;
  wire [16:0] gain_g;
  rx_gain_rom gain_rom (.r2(r2), .sh1(gain_sh1), .g(gain_g));

  reg [5:0]  sh1_r;
  reg [16:0] g_r;
  always @(posedge clk) begin
    sh1_r <= gain_sh1;
    g_r   <= gain_g;
  end

  // G1: coarse shift (and Q sign)
  reg               gv1;
  reg [4:0]         gp1;
  reg signed [24:0] ys;
  wire signed [61:0] yshift = cd[5] >>> sh1_r;
  wire               negate = Q_NEG && cp[5][0];
  always @(posedge clk) begin
    gv1 <= cv[5];
    gp1 <= cp[5];
    ys  <= negate ? -yshift[24:0] : yshift[24:0];
  end

  // G2..G4: DSP multiply (A/B, M, P)
  reg signed [24:0] ga;
  reg signed [17:0] gb;
  reg signed [42:0] gm, gpr;
  reg               gv2, gv3, gv4;
  reg [4:0]         gp2, gp3, gp4;
  always @(posedge clk) begin
    ga  <= ys;
    gb  <= $signed({1'b0, g_r});
    gm  <= ga * gb;
    gpr <= gm + 43'sd256;
    gv2 <= gv1; gv3 <= gv2; gv4 <= gv3;
    gp2 <= gp1; gp3 <= gp2; gp4 <= gp3;
  end

  // G5: >>> 9 with saturation to s32
  wire signed [33:0] scaled = gpr[42:9];
  always @(posedge clk) begin
    out_valid <= gv4 && !rst;
    out_path  <= gp4;
    if (scaled > 34'sd2147483647)
      out_data <= 32'sh7fffffff;
    else if (scaled < -34'sd2147483648)
      out_data <= 32'sh80000000;
    else
      out_data <= scaled[31:0];
  end

endmodule

`default_nettype wire
