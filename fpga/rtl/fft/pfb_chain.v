// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The channelizer's datapath (hw/docs/channelizer.md §3.6): polyphase FIR
// -> R2²SDF FFT -> split, one ADC sample in and one bin out per enabled
// clock. Bins k = 0..D-1 of each frame in order (D = M/2 = 2048: 30 kHz
// apart at 122.88 MS/s, each a 60 kS/s stream). `out_valid` frames are
// bit-exact to the fixed-point model (web888-dsp `pfbfx`, radix-2²,
// without its Nyquist bin); `out_frame` counts them from 0.
//
// The FFT carries no side data, so each frame's {valid, odd} crosses it in
// a two-entry queue: pushed where the FIR's output index wraps (a frame
// starts), popped where the FFT's does. Its latency is under two frames.
// Pops wait out the first clocks, while the FFT's index registers still
// hold their initial values.

module pfb_chain #(
  parameter integer WI   = 16,
  parameter integer W    = 25,
  parameter integer T    = 11,
  parameter integer LOGM = 12,
  // ROM tables (rtl/gen; Vivado finds them by name among the sources)
  parameter         COEF_PREFIX = "pfb_coef_",
  parameter         TW_PREFIX   = "pfb_tw_",
  parameter         SPLIT_FILE  = "pfb_split_tw.mem"
) (
  input  wire                   clk,
  input  wire                   ce,
  input  wire signed [WI-1:0]   adc,
  output wire signed [W-1:0]    out_re,
  output wire signed [W-1:0]    out_im,
  output wire [LOGM-2:0]        out_k,
  output wire                   out_valid,
  output reg  [15:0]            out_frame = 0
);

  localparam integer LOGN = LOGM - 1;
  localparam [LOGN-1:0] LAST = {LOGN{1'b1}};

  wire signed [W-1:0] f_re, f_im;
  wire [LOGN-1:0]     f_idx;
  wire                f_odd, f_valid;
  pfb_fir #(.WI(WI), .W(W), .T(T), .LOGM(LOGM), .COEF_PREFIX(COEF_PREFIX)) fir (
    .clk(clk), .ce(ce), .adc(adc),
    .out_re(f_re), .out_im(f_im), .out_idx(f_idx), .out_odd(f_odd), .out_valid(f_valid));

  wire signed [W-1:0] z_re, z_im;
  wire [LOGN-1:0]     z_idx;
  r22sdf_fft #(.W(W), .LOGN(LOGN), .TW_PREFIX(TW_PREFIX)) fft (
    .clk(clk), .ce(ce), .in_re(f_re), .in_im(f_im), .in_idx(f_idx),
    .out_re(z_re), .out_im(z_im), .out_idx(z_idx));

  // frame starts on both sides of the FFT
  reg [LOGN-1:0] f_prev = LAST, z_prev = LAST;
  reg [8:0]      boot = 0;
  wire push = (f_idx == 0) && (f_prev == LAST);
  wire pop  = (z_idx == 0) && (z_prev == LAST) && boot[8];

  // the queue of {valid, odd}: q[0] oldest
  reg [1:0] q [0:1];
  reg [1:0] n = 0;
  initial begin q[0] = 2'b00; q[1] = 2'b00; end
  // what a pop takes: the oldest, or (empty) the one pushed now
  wire [1:0] head = (n != 0) ? q[0] : {f_valid, f_odd};
  reg  [1:0] cur = 2'b00;      // the frame coming out of the FFT
  always @(posedge clk)
    if (ce) begin
      f_prev <= f_idx;
      z_prev <= z_idx;
      if (!boot[8]) boot <= boot + 1'b1;
      if (pop) cur <= head;
      case ({push, pop})
        2'b10: begin q[n[0]] <= {f_valid, f_odd}; n <= n + 1'b1; end
        2'b01: if (n != 0) begin q[0] <= q[1]; n <= n - 1'b1; end
        2'b11: if (n != 0) begin
                 // one out, one in
                 if (n == 1) q[0] <= {f_valid, f_odd};
                 else begin q[0] <= q[1]; q[1] <= {f_valid, f_odd}; end
               end
        default: ;
      endcase
    end
  wire [1:0] now = pop ? head : cur;

  wire [15:0] s_frame;
  pfb_split #(.W(W), .LOGN(LOGN), .TW_FILE(SPLIT_FILE)) split (
    .clk(clk), .ce(ce), .in_re(z_re), .in_im(z_im), .in_idx(z_idx),
    .in_odd(now[0]), .in_valid(now[1]),
    .out_re(out_re), .out_im(out_im), .out_k(out_k), .out_frame(s_frame),
    .out_valid(out_valid));

  // count valid frames out
  always @(posedge clk)
    if (ce && out_valid && out_k == LAST) out_frame <= out_frame + 1'b1;

endmodule

`default_nettype wire
