// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The twiddle multiply after a radix-2² stage pair with blocks of L = 4q
// (hw/docs/channelizer.md §3.6): the sample at r + p·q of a block, for
// quarter p = 0..3, is multiplied by W_L^e, e = 0, 2r, r, 3r, which is
// W_N^(e·N/L) of the FFT's table. Where e·N/L is 0 the sample passes
// unchanged (18-bit twiddles can't hold 1); otherwise
// (a · w) rounded by TB - 1 bits (round half up), saturated to W.
//
// The stage's own table: W_L^e for e < 3L/4 (`TW_FILE`, {re, im} TB bits
// each; rtl/gen/pfb_tw_<pair>.mem from web888-dsp examples/pfbvectors.rs).
// Six cycles of latency.

module r22_tw #(
  parameter integer W    = 25,
  parameter integer TB   = 18,
  parameter integer LOGN = 11,
  parameter integer L    = 2048,
  parameter         TW_FILE = "tw.hex"
) (
  input  wire                 clk,
  input  wire                 ce,
  input  wire signed [W-1:0]  in_re,
  input  wire signed [W-1:0]  in_im,
  input  wire [LOGN-1:0]      in_idx,
  output reg  signed [W-1:0]  out_re = 0,
  output reg  signed [W-1:0]  out_im = 0,
  output reg  [LOGN-1:0]      out_idx = 0
);

  localparam integer LQ = $clog2(L / 4);
  localparam integer NT = 3 * L / 4;

  reg [2*TB-1:0] tw [0:NT-1];
  initial $readmemh(TW_FILE, tw);

  // stage 0: the exponent from the position in the block (registered: the
  // 3r sum into the table's address was the channelizer's critical path)
  wire [LQ-1:0] r = in_idx[LQ-1:0];
  wire [1:0]    p = in_idx[LQ+1:LQ];
  wire [LQ+1:0] e = (p == 2'd0) ? {(LQ+2){1'b0}} :
                    (p == 2'd1) ? {1'b0, r, 1'b0} :
                    (p == 2'd2) ? {2'b00, r} :
                                  ({2'b00, r} + {1'b0, r, 1'b0});
  reg [LQ+1:0]        e0 = 0;
  reg signed [W-1:0]  a0_re = 0, a0_im = 0;
  reg [LOGN-1:0]      idx0 = 0;
  always @(posedge clk)
    if (ce) begin
      e0    <= e;
      a0_re <= in_re;
      a0_im <= in_im;
      idx0  <= in_idx;
    end

  // stage 1: the sample and its twiddle
  reg signed [W-1:0]  a_re = 0, a_im = 0;
  reg signed [TB-1:0] w_re = 0, w_im = 0;
  reg                 pass = 1'b1;
  reg [LOGN-1:0]      idx1 = 0;
  always @(posedge clk)
    if (ce) begin
      a_re <= a0_re;
      a_im <= a0_im;
      w_re <= tw[e0][2*TB-1:TB];
      w_im <= tw[e0][TB-1:0];
      pass <= (e0 == {(LQ+2){1'b0}});
      idx1 <= idx0;
    end

  // stages 2-5, one carry chain each (122.88 MHz): the four products
  // (DSP48), their sums, the rounding shift, the saturation
  localparam integer PW = W + TB + 1;
  localparam integer HW = PW - TB + 1;          // after the shift
  reg signed [W+TB-1:0] m_rr = 0, m_ii = 0, m_ri = 0, m_ir = 0;
  reg signed [PW-1:0]   s_re = 0, s_im = 0;
  reg signed [HW-1:0]   h_re = 0, h_im = 0;
  reg signed [W-1:0]    a2_re = 0, a2_im = 0, a3_re = 0, a3_im = 0, a4_re = 0, a4_im = 0;
  reg [2:0]             pass_d = 3'b111;
  reg [LOGN-1:0]        idx2 = 0, idx3 = 0, idx4 = 0;

  function signed [W-1:0] sat;
    input signed [HW-1:0] h;
    begin
      if (h > $signed({{(HW-W+1){1'b0}}, {(W-1){1'b1}}}))
        sat = {1'b0, {(W-1){1'b1}}};
      else if (h < -$signed({{(HW-W){1'b0}}, 1'b1, {(W-1){1'b0}}}))
        sat = {1'b1, {(W-1){1'b0}}};
      else
        sat = h[W-1:0];
    end
  endfunction

  always @(posedge clk)
    if (ce) begin
      // 2: products
      m_rr <= a_re * w_re;
      m_ii <= a_im * w_im;
      m_ri <= a_re * w_im;
      m_ir <= a_im * w_re;
      a2_re <= a_re; a2_im <= a_im; pass_d[0] <= pass; idx2 <= idx1;
      // 3: sums
      s_re <= m_rr - m_ii;
      s_im <= m_ri + m_ir;
      a3_re <= a2_re; a3_im <= a2_im; pass_d[1] <= pass_d[0]; idx3 <= idx2;
      // 4: rounded by TB - 1 bits (half up)
      h_re <= (s_re + (1 <<< (TB - 2))) >>> (TB - 1);
      h_im <= (s_im + (1 <<< (TB - 2))) >>> (TB - 1);
      a4_re <= a3_re; a4_im <= a3_im; pass_d[2] <= pass_d[1]; idx4 <= idx3;
      // 5: saturated, or the sample unchanged where the twiddle is 1
      out_re  <= pass_d[2] ? a4_re : sat(h_re);
      out_im  <= pass_d[2] ? a4_im : sat(h_im);
      out_idx <= idx4;
    end

endmodule

`default_nettype wire
