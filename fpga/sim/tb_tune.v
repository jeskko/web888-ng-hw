// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps

// pfb_tune alone: 32 users on a stream of pseudo-random bins (one a clock,
// k = 0..2047), the users' bins and the outputs dumped for
// scripts/tune_model.py (bit-exact). Users cover bin 0 and 2047, the
// rounding edges at +-15 kHz, a bin centre, users sharing a bin, a
// disabled one, a bin driven to saturation. `run` rises after the first
// pass: that pass must not come out.

module tb_tune;

  localparam integer NU = 32;
  localparam integer FRAMES = 300;
  localparam real    FS = 122.88e6;

  reg clk = 0;
  always #4 clk = ~clk;

  reg signed [24:0] re = 0, im = 0;
  reg [10:0]        k = 0;
  reg               valid = 0;
  reg               cfg_we = 0;
  reg [5:0]         cfg_idx = 0;
  reg [31:0]        cfg_data = 0;
  reg               run = 0;
  wire [63:0]       m_data;
  wire              m_valid;
  wire [31:0]       m_frame;

  pfb_tune #(.NU(NU), .COEF_FILE("../rtl/gen/tune_fir.mem"),
             .ROM_FILE("../rtl/gen/sincos_qw.mem")) dut (
    .clk(clk), .in_re(re), .in_im(im), .in_k(k), .in_valid(valid),
    .cfg_we(cfg_we), .cfg_idx(cfg_idx), .cfg_data(cfg_data),
    .run(run), .m_data(m_data), .m_valid(m_valid), .m_frame(m_frame));

  // user frequencies (Hz); 0 = disabled
  real f [0:NU-1];
  reg [47:0] inc [0:NU-1];
  integer u, n, fin, fout, words, j, seed;
  reg hit;
  initial begin
    f[0] = 7.074e6;   f[1] = 7.0765e6;  f[2] = 1.0e3;     f[3] = 61.43e6;
    f[4] = 7.08e6;    f[5] = 7.0949e6;  f[6] = 7.065e6;   f[7] = 0.0;
    f[8] = 14.074e6;  f[9] = 7.0951e6;  f[10] = 3.5e6;    f[11] = 10.136e6;
    for (u = 12; u < NU; u = u + 1) f[u] = 1.0e6 + u * 1.7317e6;
    for (u = 0; u < NU; u = u + 1) inc[u] = f[u] / FS * 281474976710656.0;
  end

  task cfg(input [5:0] idx, input [31:0] d);
    begin
      @(posedge clk) begin cfg_we <= 1; cfg_idx <= idx; cfg_data <= d; end
      @(posedge clk) cfg_we <= 0;
    end
  endtask

  // a bin's sample: noise of 2^20, the 14.074 MHz bin (469) to saturation
  function signed [24:0] val(input integer kk, input integer frame, input integer part);
    integer s, a;
    begin
      s = kk * 7919 + frame * 104729 + part * 15485863;
      a = $random(s);
      if (kk == 469) val = a >>> 7;
      else           val = a >>> 11;
    end
  endfunction

  initial begin
    fin  = $fopen("out/tune_in.txt", "w");
    fout = $fopen("out/tune_out.txt", "w");
    repeat (4) @(posedge clk);
    for (u = 0; u < NU; u = u + 1) begin
      cfg(2 * u, inc[u][31:0]);
      cfg(2 * u + 1, {f[u] != 0.0, 15'd0, inc[u][47:32]});
      $fwrite(fin, "U %0d %h %0d\n", u, inc[u], f[u] != 0.0);
    end
    repeat (8) @(posedge clk);
    for (n = 0; n < FRAMES; n = n + 1) begin
      $fwrite(fin, "F %0d\n", n);
      if (n == 6) run <= 1;
      for (j = 0; j < 2048; j = j + 1) begin
        @(posedge clk) begin
          valid <= 1;
          k     <= j;
          re    <= val(j, n, 0);
          im    <= val(j, n, 1);
        end
        hit = 0;
        for (u = 0; u < NU; u = u + 1) if (dut.bin_r[u] == j) hit = 1;
        if (hit) $fwrite(fin, "B %0d %0d %0d\n", j, val(j, n, 0), val(j, n, 1));
      end
    end
    @(posedge clk) valid <= 0;
    repeat (20000) @(posedge clk);
    $fclose(fin);
    $fclose(fout);
    if (words % NU != 0 || words < NU * 50) begin
      $display("tb_tune: FAILED, %0d words out", words);
      $finish;
    end
    $display("tb_tune: %0d output frames", words / NU);
    $display("tb_tune: PASSED (compare with scripts/tune_model.py)");
    $finish;
  end

  initial words = 0;
  always @(posedge clk)
    if (m_valid) begin
      if (words % NU == 0) $fwrite(fout, "O %0d\n", m_frame);
      $fwrite(fout, "%0d %0d\n", $signed(m_data[31:0]), $signed(m_data[63:32]));
      words = words + 1;
    end

endmodule
