// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The bin selector and the power line on the model's bins
// (vectors/bins.hex; the Nyquist bin dropped, as pfb_chain gives them):
// three frames (the third repeats the first), one bin per clock.
// * pfb_select: frame 0 with mask A (77 bins, more than NSEL = 64: the
//   lowest 64 go, `truncated` is set; bin N - 1 is asked for and never
//   sent), committed before it; mask B written and committed during frame
//   0, so frames 1 and 2 use it. Every word is checked: headers (gen,
//   frame) and bins (re, im << 5).
// * pfb_power: a line of the first two frames against vectors/power.hex,
//   in its 16 chunks (header with chunk and line, 64 float pairs).

module tb_out;
  localparam integer W = 25, LOGN = 11, N = 1 << LOGN, VF = 2, FRAMES = 3, NSEL = 64;

  reg clk = 0;
  always #4 clk = ~clk;

  reg [2*W-1:0] bins_v [0:VF*(N+1)-1];
  reg [31:0]    pow_v  [0:N-1];
  initial begin
    $readmemh("vectors/bins.hex", bins_v);
    $readmemh("vectors/power.hex", pow_v);
  end

  reg signed [W-1:0] re = 0, im = 0;
  reg [LOGN-1:0]     k = N - 1;
  reg                valid = 1'b0;

  // the masks
  reg [N-1:0] mask_a, mask_b;
  integer b;
  initial begin
    mask_a = 0;
    mask_b = 0;
    for (b = 100; b <= 170; b = b + 1) mask_a[b] = 1'b1;
    mask_a[0] = 1; mask_a[5] = 1; mask_a[236] = 1; mask_a[237] = 1; mask_a[1000] = 1;
    mask_a[2046] = 1; mask_a[2047] = 1;
    mask_b[3] = 1; mask_b[2046] = 1; mask_b[2047] = 1;
  end

  reg        mask_we = 0;
  reg [5:0]  mask_addr = 0;
  reg [31:0] mask_data = 0;
  reg [3:0]  gen_req = 0;
  wire [3:0] gen;
  wire       truncated;
  wire [63:0] sel_d, pow_d;
  wire        sel_v, sel_f, pow_v_o, pow_f;

  pfb_select #(.W(W), .LOGN(LOGN), .NSEL(NSEL)) sel (
    .clk(clk), .ce(1'b1), .enable(1'b1),
    .in_re(re), .in_im(im), .in_k(k), .in_valid(valid),
    .mask_we(mask_we), .mask_addr(mask_addr), .mask_data(mask_data),
    .gen_req(gen_req), .gen(gen), .truncated(truncated),
    .s_data(sel_d), .s_valid(sel_v), .s_first(sel_f));

  pfb_power #(.W(W), .LOGN(LOGN)) pow (
    .clk(clk), .ce(1'b1), .enable(1'b1), .frames(16'd2),
    .in_re(re), .in_im(im), .in_k(k), .in_valid(valid),
    .s_data(pow_d), .s_valid(pow_v_o), .s_first(pow_f));

  task write_mask(input [N-1:0] m);
    integer w;
    begin
      for (w = 0; w < N / 32; w = w + 1) begin
        @(negedge clk);
        mask_we = 1; mask_addr = w; mask_data = m[32*w +: 32];
      end
      @(negedge clk);
      mask_we = 0;
    end
  endtask

  // the input: frames back to back, then idle
  integer f, kk, t;
  initial begin
    write_mask(mask_a);
    gen_req = 1;
    for (f = 0; f < FRAMES; f = f + 1)
      for (kk = 0; kk < N; kk = kk + 1) begin
        @(negedge clk);
        valid = 1;
        k = kk;
        t = (f % VF) * (N + 1) + kk;
        re = bins_v[t][2*W-1:W];
        im = bins_v[t][W-1:0];
        // mask B during frame 0
        if (f == 0 && kk == 10) fork
          begin write_mask(mask_b); gen_req = 2; end
        join_none
      end
    @(negedge clk);
    valid = 0;
    repeat (40) @(negedge clk);
    finish_checks;
  end

  // ---- expected selector words, built as the frames go
  reg [63:0] exp_sel [0:4095];
  integer n_exp = 0, n_sel = 0, errors = 0;
  function [63:0] bin_word(input integer fr, input integer bk);
    reg [2*W-1:0] v;
    reg signed [31:0] i32, q32;
    begin
      v = bins_v[(fr % VF) * (N + 1) + bk];
      i32 = $signed(v[2*W-1:W]) <<< 5;
      q32 = $signed(v[W-1:0]) <<< 5;
      bin_word = {q32, i32};
    end
  endfunction
  integer ff, bb, cnt;
  initial begin
    for (ff = 0; ff < FRAMES; ff = ff + 1) begin
      exp_sel[n_exp] = {16'h5042, 4'd1, (ff == 0) ? 4'd1 : 4'd2, 8'd0, ff[31:0]};
      n_exp = n_exp + 1;
      cnt = 0;
      for (bb = 0; bb < N - 1; bb = bb + 1)
        if (((ff == 0) ? mask_a[bb] : mask_b[bb]) && cnt < NSEL) begin
          exp_sel[n_exp] = bin_word(ff, bb);
          n_exp = n_exp + 1;
          cnt = cnt + 1;
        end
    end
  end

  always @(posedge clk)
    if (sel_v) begin
      if (n_sel >= n_exp || sel_d !== exp_sel[n_sel]) begin
        if (errors < 10) $display("select word %0d: got %h want %h", n_sel, sel_d, exp_sel[n_sel]);
        errors = errors + 1;
      end
      if (sel_f !== (sel_d[63:48] == 16'h5042 && sel_d[47:44] == 4'd1)) begin
        if (errors < 10) $display("select word %0d: s_first %b", n_sel, sel_f);
        errors = errors + 1;
      end
      n_sel = n_sel + 1;
    end

  // ---- power words: 16 chunks of a header and 64 pairs
  integer n_pow = 0;
  reg [63:0] want_p;
  always @(posedge clk)
    if (pow_v_o) begin
      if (n_pow % 65 == 0)
        want_p = {16'h5042, 4'd2, 4'(n_pow / 65), 8'd0, 32'd0};
      else begin
        bb = (n_pow / 65) * 128 + 2 * (n_pow % 65 - 1);
        want_p = {pow_v[bb + 1], pow_v[bb]};
      end
      if (pow_d !== want_p || pow_f !== (n_pow % 65 == 0)) begin
        if (errors < 10) $display("power word %0d: got %h (first %b) want %h", n_pow, pow_d, pow_f, want_p);
        errors = errors + 1;
      end
      n_pow = n_pow + 1;
    end

  task finish_checks;
    begin
      if (n_sel != n_exp) begin
        $display("select: %0d words, want %0d", n_sel, n_exp);
        errors = errors + 1;
      end
      if (n_pow != 16 * 65) begin
        $display("power: %0d words, want %0d", n_pow, 16 * 65);
        errors = errors + 1;
      end
      if (!truncated) begin
        $display("truncated not set");
        errors = errors + 1;
      end
      if (errors == 0) $display("tb_out: PASSED (%0d select words, %0d power words)", n_sel, n_pow);
      else $display("tb_out: FAILED (%0d errors)", errors);
      $finish;
    end
  endtask

endmodule

`default_nettype wire
