// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// Waterfall DDC channel: NCO + I/Q mixer + variable-rate CIC (N=5, M=1,
// R = 1..2^MAXLOG2R) + 16-bit I/Q output packed two samples per 64-bit word.
//
// Integrators run at the ADC rate with full width (18 + 5*MAXLOG2R bits; no
// pruning, since pruning for the largest R would destroy small-R signals).
// At each decimated sample a 24-bit window is taken from the integrator
// output whose MSB tracks the CIC gain (R^5 = 2^(5k) for R = 2^k, the only
// values the server uses), so the comb section is only 24 bits wide and the
// output level is independent of zoom. For non power-of-two R, k = ceil(log2 R).
//
// Output word per sample: {Q[15:0], I[15:0]} (server struct iq_t {s16 i, q}).
// Full-scale DC input -> +-2^15; full-scale real sine -> |I+jQ| = 2^14.
// The first NDISCARD samples after `en` rises are dropped (CIC transient).

module wf_ddc #(
  parameter integer MAXLOG2R = 13,
  parameter integer NDISCARD = 8,
  parameter         Q_NEG    = 1,
  parameter         ROM_FILE = "sincos_qw.mem"
) (
  input  wire               clk,
  input  wire               rst,
  input  wire               en,
  input  wire signed [15:0] adc,
  input  wire [47:0]        inc,
  input  wire [15:0]        decim,

  output reg                m_valid,
  output reg  [63:0]        m_data
);

  localparam integer WI = 18 + 5*MAXLOG2R;   // integrator width
  localparam integer WC = 24;                // comb width

  // ---- NCO + mixer, product rounded to 18 bits (full scale +-2^17)
  wire signed [17:0] cosv, sinv;
  nco #(.ROM_FILE(ROM_FILE)) nco_i (
    .clk(clk), .rst(rst), .inc(inc), .cos_o(cosv), .sin_o(sinv));

  reg signed [15:0] ma;
  reg signed [17:0] mbc, mbs;
  reg signed [33:0] mmi, mmq, mpi, mpq;
  always @(posedge clk) begin
    ma  <= adc;
    mbc <= cosv;
    mbs <= sinv;
    mmi <= ma * mbc;
    mmq <= ma * mbs;
    mpi <= mmi + 34'sd16384;
    mpq <= mmq + 34'sd16384;
  end
  wire signed [17:0] xi = mpi[32:15];
  wire signed [17:0] xq = mpq[32:15];

  // ---- decimation control
  reg [15:0] r_m1;          // R - 1
  reg [3:0]  k;             // ceil(log2 R), clamped to MAXLOG2R
  integer b;
  always @(posedge clk) begin
    r_m1 <= (decim == 0) ? 16'd0 : decim - 1'b1;
    k    <= 4'd0;
    for (b = 0; b < 16; b = b + 1)
      if (r_m1 >= (16'd1 << b)) k <= (b + 1 > MAXLOG2R) ? MAXLOG2R : b + 1;
  end

  reg [15:0] dcnt;
  reg        strobe;
  always @(posedge clk) begin
    if (rst || !en) begin
      dcnt   <= 16'd0;
      strobe <= 1'b0;
    end else begin
      strobe <= (dcnt >= r_m1);
      dcnt   <= (dcnt >= r_m1) ? 16'd0 : dcnt + 1'b1;
    end
  end

  // ---- integrators (I and Q)
  // The mixer output is registered sign-extended with fanout replication, so
  // the sign bit doesn't fan out to the whole first-integrator carry chain
  // through one net (timing). Same one-clock latency on I and Q.
  (* max_fanout = 16 *) reg signed [WI-1:0] xie, xqe;
  always @(posedge clk) begin
    xie <= xi;
    xqe <= xq;
  end

  reg signed [WI-1:0] ii [0:4];
  reg signed [WI-1:0] iq [0:4];
  integer s;
  always @(posedge clk) begin
    if (rst) begin
      for (s = 0; s < 5; s = s + 1) begin ii[s] <= 0; iq[s] <= 0; end
    end else begin
      ii[0] <= ii[0] + xie;
      iq[0] <= iq[0] + xqe;
      for (s = 1; s < 5; s = s + 1) begin
        ii[s] <= ii[s] + ii[s-1];
        iq[s] <= iq[s] + iq[s-1];
      end
    end
  end

  // ---- gain-tracking window: ext = {int, 5'b0}; window = ext[23+5k -: 24]
  wire [WI+4:0] exi = {ii[4], 5'b0};
  wire [WI+4:0] exq = {iq[4], 5'b0};

  reg signed [WC-1:0] wi, wq;
  reg                 wv;
  always @(posedge clk) begin
    wv <= strobe && en && !rst;
    if (strobe) begin
      wi <= exi[5*k +: WC];
      wq <= exq[5*k +: WC];
    end
  end

  // ---- combs (one per decimated sample; may run every clock at R = 1)
  reg signed [WC-1:0] cdi [0:4], cdq [0:4];   // delay elements
  reg signed [WC-1:0] coi [0:4], coq [0:4];   // stage outputs
  reg [5:0]           cv;
  integer t;
  always @(posedge clk) begin
    cv <= {cv[4:0], wv};
    if (rst || !en) cv <= 6'd0;
    if (wv) begin
      coi[0] <= wi - cdi[0]; cdi[0] <= wi;
      coq[0] <= wq - cdq[0]; cdq[0] <= wq;
    end
    for (t = 1; t < 5; t = t + 1)
      if (cv[t-1]) begin
        coi[t] <= coi[t-1] - cdi[t]; cdi[t] <= coi[t-1];
        coq[t] <= coq[t-1] - cdq[t]; cdq[t] <= coq[t-1];
      end
  end

  // ---- round to 16 bits (>>> WC-17 = 7), saturate, Q sign
  wire signed [WC:0] ri = coi[4] + (1 << (WC-18));
  wire signed [WC:0] rq = coq[4] + (1 << (WC-18));
  wire signed [WC-7:0] ti = ri >>> (WC-17);
  wire signed [WC-7:0] tq_p = rq >>> (WC-17);
  wire signed [WC-7:0] tq = Q_NEG ? -tq_p : tq_p;

  function [15:0] sat16(input signed [WC-7:0] v);
    if (v > 32767)       sat16 = 16'h7fff;
    else if (v < -32768) sat16 = 16'h8000;
    else                 sat16 = v[15:0];
  endfunction

  // pipeline register between rounding/negation and saturation/packing
  reg signed [WC-7:0] ti_r, tq_r;
  always @(posedge clk)
    if (cv[4]) begin ti_r <= ti; tq_r <= tq; end

  // ---- discard transient, pack pairs
  reg [3:0]  ndisc;
  reg        half;
  reg [31:0] first;
  always @(posedge clk) begin
    m_valid <= 1'b0;
    if (rst || !en) begin
      ndisc <= NDISCARD;
      half  <= 1'b0;
    end else if (cv[5]) begin
      if (ndisc != 0) begin
        ndisc <= ndisc - 1'b1;
      end else if (!half) begin
        first <= {sat16(tq_r), sat16(ti_r)};
        half  <= 1'b1;
      end else begin
        m_data  <= {sat16(tq_r), sat16(ti_r), first};
        m_valid <= 1'b1;
        half    <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
