// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The whole datapath (FIR -> FFT -> split) against the fixed-point model,
// bit for bit: vectors/adc.hex in, bins 0..D-1 of each valid frame
// compared with vectors/bins.hex (D + 1 bins a frame there).

module tb_chain;
  localparam integer W = 25, LOGM = 12, D = 1 << (LOGM - 1), T = 11, FRAMES = 2;
  localparam integer NS = (2 * T + FRAMES - 1) * D;

  reg clk = 0;
  always #4 clk = ~clk;

  reg [15:0]    adc_v [0:NS-1];
  reg [2*W-1:0] ref_v [0:FRAMES*(D+1)-1];
  initial begin
    $readmemh("vectors/adc.hex", adc_v);
    $readmemh("vectors/bins.hex", ref_v);
  end

  reg signed [15:0] adc = 0;
  reg run = 1'b0;
  wire signed [W-1:0] out_re, out_im;
  wire [LOGM-2:0] out_k;
  wire out_valid;
  wire [15:0] out_frame;

  pfb_chain #(.T(T), .LOGM(LOGM), .COEF_PREFIX("../rtl/gen/pfb_coef_"),
              .TW_PREFIX("../rtl/gen/pfb_tw_"), .SPLIT_FILE("../rtl/gen/pfb_split_tw.mem")) dut (
    .clk(clk), .ce(run), .adc(adc),
    .out_re(out_re), .out_im(out_im), .out_k(out_k),
    .out_valid(out_valid), .out_frame(out_frame));

  integer t = 0;
  always @(posedge clk) begin
    adc <= (t < NS) ? adc_v[t] : 16'sd0;
    run <= 1'b1;
    t <= t + 1;
  end

  integer checked = 0, bad = 0;
  reg [2*W-1:0] want;
  always @(posedge clk) begin
    if (run && out_valid && out_frame < FRAMES) begin
      want = ref_v[out_frame * (D + 1) + out_k];
      if ({out_re, out_im} !== want) begin
        if (bad < 10)
          $display("frame %0d bin %0d: got (%0d, %0d) want (%0d, %0d)", out_frame, out_k,
                   out_re, out_im, $signed(want[2*W-1:W]), $signed(want[W-1:0]));
        bad = bad + 1;
      end
      checked = checked + 1;
    end
    if (t > NS + 4 * D) begin
      if (checked == FRAMES * D && bad == 0)
        $display("tb_chain: PASSED (%0d bins bit-exact, ADC to bins)", checked);
      else
        $display("tb_chain: FAILED (%0d of %0d wrong)", bad, checked);
      $finish;
    end
  end
endmodule

`default_nettype wire
