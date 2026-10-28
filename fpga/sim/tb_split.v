// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The split stage against the fixed-point model, bit for bit: feeds
// vectors/fft.hex (the FFT's frames, in its bit-reversed order) and
// compares bins 0..N-1 of each frame with vectors/bins.hex (N + 1 bins a
// frame there; the Nyquist bin is dropped here).

module tb_split;
  localparam integer W = 25, LOGN = 11, N = 1 << LOGN, FRAMES = 2;

  reg clk = 0;
  always #4 clk = ~clk;

  reg [2*W-1:0] in_v  [0:FRAMES*N-1];
  reg [2*W-1:0] ref_v [0:FRAMES*(N+1)-1];
  initial begin
    $readmemh("vectors/fft.hex", in_v);
    $readmemh("vectors/bins.hex", ref_v);
  end

  reg signed [W-1:0] in_re = 0, in_im = 0;
  // (not 0 before the first sample: that would start a frame)
  reg [LOGN-1:0]     in_idx = N - 1;
  reg                in_odd = 0;
  wire signed [W-1:0] out_re, out_im;
  wire [LOGN-1:0]     out_k;
  wire [15:0]         out_frame;

  pfb_split #(.W(W), .LOGN(LOGN), .TW_FILE("vectors/split_tw.hex")) dut (
    .clk(clk), .ce(1'b1),
    .in_re(in_re), .in_im(in_im), .in_idx(in_idx), .in_odd(in_odd),
    .out_re(out_re), .out_im(out_im), .out_k(out_k), .out_frame(out_frame));

  // the frames, then one more (zeros) that reads the last one out
  integer t = 0;
  always @(posedge clk) begin
    if (t < FRAMES * N) begin
      in_re <= in_v[t][2*W-1:W];
      in_im <= in_v[t][W-1:0];
    end else begin
      in_re <= 0;
      in_im <= 0;
    end
    in_idx <= t % N;
    in_odd <= (t / N) % 2;
    t <= t + 1;
  end

  // bins of input frame f come out tagged out_frame = f + 1
  integer checked = 0, bad = 0, f;
  reg [2*W-1:0] want;
  always @(posedge clk) begin
    f = out_frame - 1;
    if (t > 8 && f >= 0 && f < FRAMES) begin
      want = ref_v[f * (N + 1) + out_k];
      if ({out_re, out_im} !== want) begin
        if (bad < 10)
          $display("frame %0d bin %0d: got (%0d, %0d) want (%0d, %0d)", f, out_k,
                   out_re, out_im, $signed(want[2*W-1:W]), $signed(want[W-1:0]));
        bad = bad + 1;
      end
      checked = checked + 1;
    end
    if (t > (FRAMES + 2) * N) begin
      if (checked == FRAMES * N && bad == 0)
        $display("tb_split: PASSED (%0d bins bit-exact)", checked);
      else
        $display("tb_split: FAILED (%0d of %0d bins wrong)", bad, checked);
      $finish;
    end
  end
endmodule

`default_nettype wire
