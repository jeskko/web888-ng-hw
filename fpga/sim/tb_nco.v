// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps

// Dumps NCO output for spectral analysis (sim/analyze.py nco).
module tb_nco;
  reg clk = 0;
  always #4 clk = ~clk;

  reg         rst = 1;
  reg  [47:0] inc;
  wire signed [17:0] c, s;

  nco #(.ROM_FILE("../rtl/gen/sincos_qw.mem")) dut (
    .clk(clk), .rst(rst), .inc(inc), .cos_o(c), .sin_o(s));

  integer f, i;
  initial begin
    // 7.0745 MHz at fs = 122.88 MHz, deliberately not a nice fraction
    inc = 48'd16288409534489;
    if ($value$plusargs("inc=%d", inc)) ;
    f = $fopen("out/nco.txt", "w");
    repeat (4) @(posedge clk);
    rst = 0;
    repeat (20) @(posedge clk);
    for (i = 0; i < 65536; i = i + 1) begin
      @(posedge clk);
      $fdisplay(f, "%0d %0d", c, s);
    end
    $fclose(f);
    $finish;
  end
endmodule
