// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The polyphase FIR against the fixed-point model, bit for bit: feeds
// vectors/adc.hex and compares each valid output frame with
// vectors/packed.hex (the FFT's input, FRAMES frames), and the parity.

module tb_fir;
  localparam integer W = 25, LOGM = 12, D = 1 << (LOGM - 1), T = 11, FRAMES = 2;
  localparam integer NS = (2 * T + FRAMES - 1) * D;   // history + one half-block per frame

  reg clk = 0;
  always #4 clk = ~clk;

  reg [15:0]    adc_v [0:NS-1];
  reg [2*W-1:0] ref_v [0:FRAMES*D-1];
  initial begin
    $readmemh("vectors/adc.hex", adc_v);
    $readmemh("vectors/packed.hex", ref_v);
  end

  reg signed [15:0] adc = 0;
  reg run = 1'b0;   // enabled from the first real sample on
  wire signed [W-1:0] out_re, out_im;
  wire [LOGM-2:0] out_idx;
  wire out_odd, out_valid;

  pfb_fir #(.T(T), .LOGM(LOGM), .COEF_PREFIX("../rtl/gen/pfb_coef_")) dut (
    .clk(clk), .ce(run), .adc(adc),
    .out_re(out_re), .out_im(out_im), .out_idx(out_idx),
    .out_odd(out_odd), .out_valid(out_valid));

  integer t = 0;
  always @(posedge clk) begin
    adc <= (t < NS) ? adc_v[t] : 16'sd0;
    run <= 1'b1;
    t <= t + 1;
  end

  integer f = -1, checked = 0, bad = 0;
  reg [2*W-1:0] want;
  always @(posedge clk) begin
    if (out_valid && out_idx == 0) f = f + 1;
    if (out_valid && f >= 0 && f < FRAMES) begin
      want = ref_v[f * D + out_idx];
      if ({out_re, out_im} !== want || out_odd !== f[0]) begin
        if (bad < 10)
          $display("frame %0d k %0d: got (%0d, %0d) odd %b, want (%0d, %0d) odd %b", f, out_idx,
                   out_re, out_im, out_odd, $signed(want[2*W-1:W]), $signed(want[W-1:0]), f[0]);
        bad = bad + 1;
      end
      checked = checked + 1;
    end
    if (f >= FRAMES || t > NS + 4 * D) begin
      if (checked == FRAMES * D && bad == 0)
        $display("tb_fir: PASSED (%0d branch-sum pairs bit-exact)", checked);
      else
        $display("tb_fir: FAILED (%0d of %0d wrong)", bad, checked);
      $finish;
    end
  end
endmodule

`default_nettype wire
