// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The R2²SDF FFT against the fixed-point model, bit for bit: feeds
// vectors/packed.hex (FRAMES frames of N complex points, back to back)
// and compares every output with vectors/fft.hex at its out_idx.

module tb_fft;
  localparam integer W = 25, LOGN = 11, N = 1 << LOGN, FRAMES = 2;

  reg clk = 0;
  always #4 clk = ~clk;

  reg [2*W-1:0] in_v  [0:FRAMES*N-1];
  reg [2*W-1:0] ref_v [0:FRAMES*N-1];
  initial begin
    $readmemh("vectors/packed.hex", in_v);
    $readmemh("vectors/fft.hex", ref_v);
  end

  reg signed [W-1:0] in_re = 0, in_im = 0;
  reg [LOGN-1:0]     in_idx = 0;
  wire signed [W-1:0] out_re, out_im;
  wire [LOGN-1:0]     out_idx;

  r22sdf_fft #(.W(W), .LOGN(LOGN), .TW_FILE("vectors/tw.hex")) dut (
    .clk(clk), .ce(1'b1),
    .in_re(in_re), .in_im(in_im), .in_idx(in_idx),
    .out_re(out_re), .out_im(out_im), .out_idx(out_idx));

  // inputs: the frames, then zeros to flush the last one out
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
    t <= t + 1;
  end

  // outputs: frame f starts where out_idx is 0 after f's first input
  integer f = -1, checked = 0, bad = 0;
  reg [2*W-1:0] want;
  always @(posedge clk) begin
    if (t > N && out_idx == 0) f = f + 1;
    if (f >= 0 && f < FRAMES) begin
      want = ref_v[f * N + out_idx];
      if ({out_re, out_im} !== want) begin
        if (bad < 10)
          $display("frame %0d idx %0d: got (%0d, %0d) want (%0d, %0d)", f, out_idx,
                   out_re, out_im, $signed(want[2*W-1:W]), $signed(want[W-1:0]));
        bad = bad + 1;
      end
      checked = checked + 1;
    end
    if (f >= FRAMES || t > (FRAMES + 3) * N) begin
      if (checked == FRAMES * N && bad == 0)
        $display("tb_fft: PASSED (%0d outputs bit-exact)", checked);
      else
        $display("tb_fft: FAILED (%0d of %0d outputs wrong)", bad, checked);
      $finish;
    end
  end
endmodule

`default_nettype wire
