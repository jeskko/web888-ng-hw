// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// RX front end: NCH x (NCO + I/Q mixer + CIC stage 1 integrators, N=3, R=256)
// running at the ADC rate, followed by a time-multiplexed decimating sampler.
//
// Mixer: x * exp(-j w n): I = adc*cos, Q = adc*sin (Q sign is fixed up at
// the CIC output), product rounded to 24 bits (full scale +-2^23).
// CIC1 register widths use Hogenauer pruning for Bin=24, Bmax=48, Bout=32:
// integrators keep bits [47:0], [47:2], [47:9]; the comb section (in
// rx_serial_cic) takes bits [47:12].
//
// Decimation by 256 is staggered: the counter value 2c samples both I and Q
// of channel c (Q is held one clock), so the output is a token stream
//   path 0 (ch0 I), path 1 (ch0 Q), ..., path 2*NCH-1
// on consecutive clocks, once every 256 clocks. Each channel is sampled at a
// constant 2c-clock offset, which is irrelevant to the per-channel signal.

module rx_frontend #(
  parameter integer NCH      = 12,
  parameter         ROM_FILE = "sincos_qw.mem"
) (
  input  wire                  clk,
  input  wire                  rst,
  input  wire signed [15:0]    adc,
  input  wire [NCH*48-1:0]     inc,

  output reg                   tok_valid,
  output reg  [4:0]            tok_path,
  output reg  signed [35:0]    tok_data
);

  wire [35:0] top_i [0:NCH-1];
  wire [35:0] top_q [0:NCH-1];

  genvar c;
  generate
    for (c = 0; c < NCH; c = c + 1) begin : ch
      wire signed [17:0] cosv, sinv;

      nco #(.ROM_FILE(ROM_FILE)) nco_i (
        .clk(clk), .rst(rst), .inc(inc[c*48 +: 48]),
        .cos_o(cosv), .sin_o(sinv)
      );

      // mixer (DSP48: A/B, M, P registers, rounding constant on C)
      // per-channel fabric copy of the ADC sample (timing: one IOB register
      // otherwise drives 2*NCH DSP inputs across the die). `keep` stops it
      // from being folded into the DSP's own A/B register cascade.
      (* keep = "true" *) reg signed [15:0] adc_c;
      reg signed [15:0] ma;
      reg signed [17:0] mbc, mbs;
      reg signed [33:0] mmi, mmq, mpi, mpq;
      always @(posedge clk) begin
        adc_c <= adc;
        ma  <= adc_c;
        mbc <= cosv;
        mbs <= sinv;
        mmi <= ma * mbc;
        mmq <= ma * mbs;
        mpi <= mmi + 34'sd256;
        mpq <= mmq + 34'sd256;
      end

      // |adc*nco| < 2^32 (NCO amplitude 2^17-8), so bit 33 is a copy of bit 32
      wire signed [23:0] xi = mpi[32:9];
      wire signed [23:0] xq = mpq[32:9];

      // CIC1 integrators (pruned)
      reg signed [47:0] i1i, i1q;
      reg signed [45:0] i2i, i2q;
      reg signed [38:0] i3i, i3q;
      always @(posedge clk) begin
        if (rst) begin
          i1i <= 0; i1q <= 0; i2i <= 0; i2q <= 0; i3i <= 0; i3q <= 0;
        end else begin
          i1i <= i1i + xi;
          i1q <= i1q + xq;
          i2i <= i2i + i1i[47:2];
          i2q <= i2q + i1q[47:2];
          i3i <= i3i + i2i[45:7];
          i3q <= i3q + i2q[45:7];
        end
      end

      assign top_i[c] = i3i[38:3];   // bits [47:12] of full precision
      assign top_q[c] = i3q[38:3];
    end
  endgenerate

  // staggered decimate-by-256 sampler
  reg [7:0]  cnt;
  reg [35:0] qhold;
  wire [3:0] sel = cnt[4:1];

  always @(posedge clk) begin
    if (rst) begin
      cnt       <= 8'd0;
      tok_valid <= 1'b0;
    end else begin
      cnt       <= cnt + 1'b1;
      tok_valid <= (cnt < 2*NCH);
      tok_path  <= cnt[4:0];
      if (!cnt[0]) begin
        tok_data <= top_i[sel];
        qhold    <= top_q[sel];
      end else begin
        tok_data <= qhold;
      end
    end
  end

endmodule

`default_nettype wire
