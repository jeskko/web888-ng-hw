// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The channelizer with its DMA (pfb_top), ADC samples to DDR: vectors/
// adc.hex in, both rings in AXI memory models (random backpressure), then
// read back as software would and compared with the model:
// * bins: seven selected bins of the two frames (headers, then {Q, I} =
//   bins.hex << 5), sixteen words, one burst
// * power: one line of the two frames, sixteen chunks (power.hex)
// Then the zoom engine runs on the same power ring (power line every second
// frame, the interlock's hardest case): six jobs, and the whole ring is read
// back and checked word by word (check_stream): chunks of type 2 (sixteen in
// a row per line, consecutive line numbers, every value against the power
// recomputed from the chain's bins) and of type 3 (a job's chunks in order,
// none inside a line, tag, counts, lengths); no foreign word. The bins the
// chain produced are recorded (dut.re/im/k/frame) and each job's frames are
// dumped to out/top_zoom_in.txt, its result to out/top_zoom_out.txt, for
// scripts/zoom_model.py check (bit-exact).

module tb_top;
  localparam integer W = 25, N = 2048, NS = 47104, VF = 2, NB = 7;
  localparam integer MAXF = 320;           // frames of bins recorded
  localparam integer NJOBS = 6;
  localparam integer PW_BASE = 32'h0001_0000;   // the power ring (bytes)
  localparam integer PW_LEN_M1 = 15999;     // 16000 bursts (256k words): no wrap in the run

  reg clk = 0;
  always #4 clk = ~clk;

  reg [15:0]    adc_v  [0:NS-1];
  reg [2*W-1:0] bins_v [0:VF*(N+1)-1];
  reg [31:0]    pow_v  [0:N-1];
  initial begin
    $readmemh("vectors/adc.hex", adc_v);
    $readmemh("vectors/bins.hex", bins_v);
    $readmemh("vectors/power.hex", pow_v);
  end

  integer sel_bins [0:NB-1];
  initial begin
    sel_bins[0] = 0; sel_bins[1] = 236; sel_bins[2] = 237; sel_bins[3] = 700;
    sel_bins[4] = 1500; sel_bins[5] = 2000; sel_bins[6] = 2046;
  end

  reg        rst = 1;
  reg        bins_en = 0, power_en = 0;
  reg        mask_we = 0;
  reg [5:0]  mask_addr = 0;
  reg [31:0] mask_data = 0;
  reg [3:0]  gen_req = 0;
  wire [3:0] gen;
  wire       truncated;
  wire [15:0] bins_ptr, power_ptr;
  wire        bins_ovf, power_ovf, bins_berr, power_berr;
  wire [31:0] bins_frames, bins_drops, power_frames_out, power_drops;
  reg         zoom_en = 0, zoom_we = 0;
  reg  [31:0] zoom_word = 0;
  wire [4:0]  zoom_free;
  wire [15:0] zoom_done;
  wire        zoom_ovf, zoom_bad;

`define AXI_WIRES(p) \
  wire [5:0] p``_awid, p``_wid, p``_bid, p``_arid, p``_rid; \
  wire [31:0] p``_awaddr, p``_araddr; \
  wire [3:0] p``_awlen, p``_awcache, p``_awqos, p``_arlen, p``_arcache, p``_arqos; \
  wire [2:0] p``_awsize, p``_awprot, p``_arsize, p``_arprot; \
  wire [1:0] p``_awburst, p``_awlock, p``_arburst, p``_arlock, p``_bresp, p``_rresp; \
  wire p``_awvalid, p``_awready, p``_wlast, p``_wvalid, p``_wready, p``_bvalid, p``_bready, \
       p``_arvalid, p``_rready; \
  wire [63:0] p``_wdata; \
  wire [7:0] p``_wstrb;
  `AXI_WIRES(bn)
  `AXI_WIRES(pw)

`define AXI_PORTS(p) \
  .m_axi_``p``_awid(p``_awid), .m_axi_``p``_awaddr(p``_awaddr), .m_axi_``p``_awlen(p``_awlen), \
  .m_axi_``p``_awsize(p``_awsize), .m_axi_``p``_awburst(p``_awburst), .m_axi_``p``_awlock(p``_awlock), \
  .m_axi_``p``_awcache(p``_awcache), .m_axi_``p``_awprot(p``_awprot), .m_axi_``p``_awqos(p``_awqos), \
  .m_axi_``p``_awvalid(p``_awvalid), .m_axi_``p``_wid(p``_wid), .m_axi_``p``_wdata(p``_wdata), \
  .m_axi_``p``_wstrb(p``_wstrb), .m_axi_``p``_wlast(p``_wlast), .m_axi_``p``_wvalid(p``_wvalid), \
  .m_axi_``p``_bready(p``_bready), .m_axi_``p``_arid(p``_arid), .m_axi_``p``_araddr(p``_araddr), \
  .m_axi_``p``_arlen(p``_arlen), .m_axi_``p``_arsize(p``_arsize), .m_axi_``p``_arburst(p``_arburst), \
  .m_axi_``p``_arlock(p``_arlock), .m_axi_``p``_arcache(p``_arcache), .m_axi_``p``_arprot(p``_arprot), \
  .m_axi_``p``_arqos(p``_arqos), .m_axi_``p``_arvalid(p``_arvalid), .m_axi_``p``_rready(p``_rready), \
  .m_axi_``p``_awready(p``_awready), .m_axi_``p``_wready(p``_wready), .m_axi_``p``_bid(p``_bid), \
  .m_axi_``p``_bresp(p``_bresp), .m_axi_``p``_bvalid(p``_bvalid), .m_axi_``p``_arready(1'b0), \
  .m_axi_``p``_rid(6'd0), .m_axi_``p``_rdata(64'd0), .m_axi_``p``_rresp(2'd0), \
  .m_axi_``p``_rlast(1'b0), .m_axi_``p``_rvalid(1'b0)

  pfb_top #(.COEF_PREFIX("../rtl/gen/pfb_coef_"), .TW_PREFIX("../rtl/gen/pfb_tw_"),
            .SPLIT_FILE("../rtl/gen/pfb_split_tw.mem"),
            .ZOOM_WIN_FILE("../rtl/gen/zoom_win.mem")) dut (
    .clk(clk), .rst(rst), .adc(adc_in),
    .bins_enable(bins_en), .mask_we(mask_we), .mask_addr(mask_addr), .mask_data(mask_data),
    .gen_req(gen_req), .gen(gen), .truncated(truncated),
    .bins_addr(32'd0), .bins_len_m1(16'd63), .bins_ptr(bins_ptr), .bins_overflow(bins_ovf),
    .bins_frames(bins_frames), .bins_drops(bins_drops), .bins_bresp_err(bins_berr),
    .power_enable(power_en), .power_frames(16'd2), .power_addr(PW_BASE), .power_len_m1(PW_LEN_M1[15:0]),
    .power_ptr(power_ptr), .power_overflow(power_ovf), .power_frames_out(power_frames_out),
    .power_drops(power_drops), .power_bresp_err(power_berr),
    .zoom_enable(zoom_en), .zoom_job_we(zoom_we), .zoom_job(zoom_word),
    .zoom_free(zoom_free), .zoom_done(zoom_done), .zoom_ovf(zoom_ovf), .zoom_bad(zoom_bad),
    `AXI_PORTS(bn),
    `AXI_PORTS(pw));

`define MEM(p, seed, aw) \
  axi_mem_slave #(.SEED(seed), .AW_WORDS(aw), .NAME(`"p`")) p``_mem ( \
    .clk(clk), .awid(p``_awid), .awaddr(p``_awaddr), .awlen(p``_awlen), .awsize(p``_awsize), \
    .awburst(p``_awburst), .awvalid(p``_awvalid), .awready(p``_awready), .wdata(p``_wdata), \
    .wstrb(p``_wstrb), .wlast(p``_wlast), .wvalid(p``_wvalid), .wready(p``_wready), \
    .bid(p``_bid), .bresp(p``_bresp), .bvalid(p``_bvalid), .bready(p``_bready));
  `MEM(bn, 5, 16)
  `MEM(pw, 6, 21)

  // ADC samples from the first clock (the chain runs through reset; its
  // frames start with its first sample, as the vectors')
  integer t = 0;
  always @(posedge clk) t <= t + 1;
  // (the vectors repeat after NS samples, so later frames carry signal too;
  // frames 0 and 1 are unchanged)
  wire signed [15:0] adc_in = adc_v[t % NS];

  // ---- the chain's bins, as the power line and the zoom engine get them
  reg signed [W-1:0] rec_re [0:MAXF*N-1];
  reg signed [W-1:0] rec_im [0:MAXF*N-1];
  integer            rec_frames = 0;       // highest frame seen + 1
  always @(posedge clk)
    if (dut.valid && dut.frame < MAXF) begin
      rec_re[dut.frame * N + dut.k] <= dut.re;
      rec_im[dut.frame * N + dut.k] <= dut.im;
      if (dut.frame + 1 > rec_frames) rec_frames <= dut.frame + 1;
    end

  // float32 of an integer, mantissa truncated (the power line's output)
  function [31:0] f32tr(input [63:0] p);
    integer lead, b;
    reg [63:0] m;
    begin
      lead = 0;
      for (b = 0; b < 64; b = b + 1) if (p[b]) lead = b;
      if (p == 0) f32tr = 32'd0;
      else begin
        m = (lead <= 23) ? (p << (23 - lead)) : (p >> (lead - 23));
        f32tr = {1'b0, 8'(127 + lead), m[22:0]};
      end
    end
  endfunction

  // the power of bin kk in line ln: two frames, exact
  function [31:0] pw_ref(input integer ln, input integer kk);
    reg signed [63:0] a, b, s;
    integer fr;
    begin
      s = 0;
      for (fr = 2 * ln; fr < 2 * ln + 2; fr = fr + 1) begin
        a = rec_re[fr * N + kk];
        b = rec_im[fr * N + kk];
        s = s + a * a + b * b;
      end
      pw_ref = f32tr(s);
    end
  endfunction

  // ---- the jobs: per tag (the tag is the job's number + 1)
  reg [3:0]  j_lg  [0:63];
  reg [7:0]  j_bm1 [0:63];
  reg [10:0] j_k0  [0:63];
  reg [2:0]  j_sh  [0:63];
  integer    j_st  [0:63];                 // 0 unused, 1 submitted, 2 complete
  integer    j_fr  [0:63];                 // frame at the submission
  integer    n_sub = 0;
  integer    fin, fout;
  initial begin
    for (i = 0; i < 64; i = i + 1) j_st[i] = 0;
    fin  = $fopen("out/top_zoom_in.txt", "w");
    fout = $fopen("out/top_zoom_out.txt", "w");
  end

  task submit(input [5:0] tag, input [3:0] lg, input [7:0] bm1, input [10:0] k0, input [2:0] sh);
    begin
      @(negedge clk);
      zoom_we = 1;
      zoom_word = {tag, sh, lg, bm1, k0};
      j_lg[tag] = lg; j_bm1[tag] = bm1; j_k0[tag] = k0; j_sh[tag] = sh;
      j_st[tag] = 1; j_fr[tag] = dut.frame;
      n_sub = n_sub + 1;
      @(negedge clk);
      zoom_we = 0;
      $display("tb_top: job tag %0d submitted in frame %0d (logn %0d, B %0d, k0 %0d)",
               tag, dut.frame, lg, bm1 + 1, k0);
    end
  endtask

  // ---- the whole power ring, word by word
  integer    sc_err = 0;
  integer    sc_lines = 0, sc_pchunks = 0, sc_zchunks = 0, sc_jobs = 0, sc_between = 0;
  integer    sc_idx, sc_lim, sc_typ, sc_ch, sc_nw, sc_tg, sc_in_line, sc_next_line, sc_cur_line,
             sc_last_ch, sc_zt, sc_zch, sc_zn, sc_zwords, sc_zbase, sc_trunc, sc_jl, sc_jb, sc_jn,
             sc_ts, sc_tb, sc_p, sc_z0, sc_zdone;
  reg [63:0] sc_h, sc_w, sc_want;
  reg [31:0] sc_pts [0:2047];
  reg        sc_sat;
  reg [15:0] sc_fr0;

  task sc_bad(input [8*48-1:0] msg);
    integer d;
    begin
      sc_err = sc_err + 1;
      if (sc_err <= 8) begin
        $display("stream: word %0d (ring byte %0d): %0s", sc_idx, sc_idx * 8, msg);
        for (d = -2; d <= 3; d = d + 1)
          if (sc_idx + d >= 0) $display("stream:   [%0d] %h", sc_idx + d, pw_mem.mem[PW_BASE / 8 + sc_idx + d]);
      end
    end
  endtask

  task dump_job(input integer tg, input integer fr0, input sat);
    integer tt, bb, pp;
    begin
      sc_jl = j_lg[tg]; sc_jb = j_bm1[tg] + 1; sc_jn = 1 << sc_jl;
      $fwrite(fin, "job %0d %0d %0d\n", sc_jl, sc_jb, j_sh[tg]);
      for (tt = 0; tt < sc_jn; tt = tt + 1) begin
        for (bb = 0; bb < sc_jb; bb = bb + 1)
          $fwrite(fin, "%h %h ", rec_re[(fr0 + tt) * N + j_k0[tg] + bb] & 25'h1ffffff,
                  rec_im[(fr0 + tt) * N + j_k0[tg] + bb] & 25'h1ffffff);
        $fwrite(fin, "\n");
      end
      $fwrite(fout, "sat %0d\n", sat);
      for (pp = 0; pp < sc_jb * sc_jn / 2; pp = pp + 1) $fwrite(fout, "%h\n", sc_pts[pp]);
    end
  endtask

  task check_stream;
    integer m;
    begin
      sc_lim = power_ptr * 16;
      sc_idx = 0; sc_in_line = 0; sc_next_line = 0; sc_cur_line = 0; sc_last_ch = 0;
      sc_zt = -1; sc_zch = 0; sc_trunc = 0; sc_zdone = 0;
      while (sc_idx < sc_lim) begin
        sc_h = pw_mem.mem[PW_BASE / 8 + sc_idx];
        sc_typ = sc_h[47:44];
        sc_ch  = sc_h[43:40];
        if (sc_h[63:48] != 16'h5042) begin
          sc_bad("not a header (foreign or misplaced word)");
          sc_idx = sc_lim;
        end else if (sc_typ == 2) begin
          // ---- a power line's chunk
          sc_nw = 64;
          if (sc_h[39:32] != 0) sc_bad("power header: bits 39:32 not 0");
          if (sc_idx + 1 + sc_nw > sc_lim) begin
            sc_trunc = 1; sc_idx = sc_lim;
          end else begin
            if (sc_ch == 0) begin
              if (sc_in_line) sc_bad("power chunk 0 before chunk 15 of the line");
              if (sc_h[31:0] != sc_next_line) begin
                sc_bad("power line number not consecutive");
                $display("stream:   line %0d, expected %0d", sc_h[31:0], sc_next_line);
              end
              sc_cur_line = sc_h[31:0];
              sc_next_line = sc_cur_line + 1;
              sc_in_line = 1;
            end else begin
              if (!sc_in_line) sc_bad("power chunk without chunk 0");
              if (sc_ch != sc_last_ch + 1) sc_bad("power chunk number not consecutive");
              if (sc_h[31:0] != sc_cur_line) sc_bad("power line number changed inside a line");
            end
            sc_last_ch = sc_ch;
            if (sc_ch == 15) begin sc_in_line = 0; sc_lines = sc_lines + 1; end
            if (2 * sc_cur_line + 2 > rec_frames) sc_bad("line beyond the recorded frames");
            else
              for (m = 1; m <= 64; m = m + 1) begin
                sc_w = pw_mem.mem[PW_BASE / 8 + sc_idx + m];
                sc_want = {pw_ref(sc_cur_line, 128 * sc_ch + 2 * (m - 1) + 1),
                           pw_ref(sc_cur_line, 128 * sc_ch + 2 * (m - 1))};
                if (sc_w !== sc_want) begin
                  sc_idx = sc_idx + m;
                  sc_bad("power value");
                  if (sc_err <= 8) $display("stream:   line %0d chunk %0d word %0d: got %h want %h",
                                            sc_cur_line, sc_ch, m, sc_w, sc_want);
                  sc_idx = sc_idx - m;
                  m = 65;
                end
              end
            sc_pchunks = sc_pchunks + 1;
            sc_idx = sc_idx + 1 + sc_nw;
          end
        end else if (sc_typ == 3) begin
          // ---- a zoom chunk
          sc_tg = sc_h[37:32];
          if (sc_in_line) sc_bad("zoom chunk inside a power line");
          if (sc_h[39:38] != 0 || sc_h[30:20] != 0) sc_bad("zoom header: reserved bits not 0");
          if (j_st[sc_tg] == 0 && sc_zt != sc_tg) begin
            sc_bad("zoom chunk of a tag never submitted");
            sc_idx = sc_lim;
          end else begin
            sc_zwords = ((j_bm1[sc_tg] + 1) << j_lg[sc_tg]) / 4;
            sc_zn = (sc_zwords + 63) / 64;
            if (sc_ch == 0) begin
              if (sc_zt >= 0) sc_bad("job's chunks cut short by a new job");
              if (j_st[sc_tg] != 1) sc_bad("job's tag not pending");
              sc_zt = sc_tg; sc_zch = 0;
              sc_sat = sc_h[31]; sc_fr0 = sc_h[15:0];
              if (sc_fr0 < j_fr[sc_tg]) sc_bad("frame0 before the job");
            end else begin
              if (sc_tg != sc_zt) sc_bad("zoom chunk of another tag inside a job");
              if (sc_ch != sc_zch + 1) sc_bad("zoom chunk number not consecutive");
              if (sc_h[31] != sc_sat || sc_h[15:0] != sc_fr0) sc_bad("zoom header changed inside a job");
              sc_zch = sc_ch;
            end
            if (sc_h[19:16] != sc_zn - 1) sc_bad("zoom chunks - 1 field");
            sc_nw = sc_zwords - 64 * sc_ch;
            if (sc_nw > 64) sc_nw = 64;
            if (sc_nw <= 0) begin
              sc_bad("zoom chunk number beyond the job");
              sc_idx = sc_lim;
            end else if (sc_idx + 1 + sc_nw > sc_lim) begin
              sc_trunc = 1; sc_idx = sc_lim;
            end else begin
              for (m = 1; m <= sc_nw; m = m + 1) begin
                sc_w = pw_mem.mem[PW_BASE / 8 + sc_idx + m];
                sc_pts[128 * sc_ch + 2 * (m - 1)]     = sc_w[31:0];
                sc_pts[128 * sc_ch + 2 * (m - 1) + 1] = sc_w[63:32];
              end
              sc_zchunks = sc_zchunks + 1;
              sc_idx = sc_idx + 1 + sc_nw;
              if (sc_ch == sc_zn - 1) begin
                // complete
                if (sc_fr0 + (1 << j_lg[sc_tg]) > rec_frames) sc_bad("job's frames beyond the recorded");
                else dump_job(sc_tg, sc_fr0, sc_sat);
                j_st[sc_tg] = 2;
                sc_zdone = sc_zdone + 1;
                sc_zt = -1;
              end
            end
          end
        end else begin
          sc_bad("header of a type other than 2, 3");
          sc_idx = sc_lim;
        end
      end
      // nothing written beyond the last complete burst
      for (m = 0; m < 16; m = m + 1)
        if (pw_mem.mem[PW_BASE / 8 + sc_lim + m] !== 64'hdead_beef_dead_beef) begin
          sc_idx = sc_lim + m;
          sc_bad("a word beyond the last burst written");
        end
      for (m = 0; m < 64; m = m + 1)
        if (j_st[m] == 1) begin
          $display("stream: job tag %0d never completed in the ring", m);
          sc_err = sc_err + 1;
        end
      if (sc_zt >= 0) begin
        $display("stream: job tag %0d cut short at the end", sc_zt);
        sc_err = sc_err + 1;
      end
      $display("stream: %0d words, %0d power lines (%0d chunks), %0d zoom chunks, %0d jobs; last chunk %0s",
               sc_lim, sc_lines, sc_pchunks, sc_zchunks, sc_zdone, sc_trunc ? "cut by the last burst" : "whole");
      errors = errors + sc_err;
      if (sc_zdone != NJOBS) begin
        $display("stream: %0d jobs in the ring, %0d submitted", sc_zdone, NJOBS);
        errors = errors + 1;
      end
    end
  endtask

  integer errors = 0, w, i, f, j;
  reg [63:0] got, want;
  reg [2*W-1:0] v;
  reg signed [31:0] i32, q32;
  reg [N-1:0] mask;
  initial begin
    mask = 0;
    for (i = 0; i < NB; i = i + 1) mask[sel_bins[i]] = 1'b1;
    repeat (4) @(negedge clk);
    // the mask before the first frame, then both rings on
    for (w = 0; w < N / 32; w = w + 1) begin
      @(negedge clk);
      mask_we = 1; mask_addr = w; mask_data = mask[32*w +: 32];
    end
    @(negedge clk);
    mask_we = 0;
    gen_req = 1;
    bins_en = 1;
    power_en = 1;
    rst = 0;
    // a burst of bins (two frames), 65 of power (one line)
    wait (bins_ptr >= 1 && power_ptr >= 65);
    repeat (10) @(negedge clk);

    // ---- bins: header, seven bins, twice
    for (f = 0; f < VF; f = f + 1) begin
      got = bn_mem.mem[f * (NB + 1)];
      want = {16'h5042, 4'd1, 4'd1, 8'd0, f[31:0]};
      if (got !== want) begin
        $display("bins frame %0d header: got %h want %h", f, got, want);
        errors = errors + 1;
      end
      for (j = 0; j < NB; j = j + 1) begin
        v = bins_v[f * (N + 1) + sel_bins[j]];
        i32 = $signed(v[2*W-1:W]) <<< 5;
        q32 = $signed(v[W-1:0]) <<< 5;
        got = bn_mem.mem[f * (NB + 1) + 1 + j];
        if (got !== {q32, i32}) begin
          $display("bins frame %0d bin %0d: got %h want %h", f, sel_bins[j], got, {q32, i32});
          errors = errors + 1;
        end
      end
    end
    // ---- power: sixteen chunks
    for (f = 0; f < 16; f = f + 1)
      for (j = 0; j < 65; j = j + 1) begin
        got = pw_mem.mem[PW_BASE / 8 + f * 65 + j];
        want = (j == 0) ? {16'h5042, 4'd2, f[3:0], 8'd0, 32'd0}
                        : {pow_v[f * 128 + 2 * (j - 1) + 1], pow_v[f * 128 + 2 * (j - 1)]};
        if (got !== want) begin
          if (errors < 10) $display("power chunk %0d word %0d: got %h want %h", f, j, got, want);
          errors = errors + 1;
        end
      end
    if (bins_ovf || power_ovf || bins_berr || power_berr || truncated || bins_drops || power_drops) begin
      $display("flags: overflow %b %b, bresp %b %b, truncated %b, drops %0d %0d",
               bins_ovf, power_ovf, bins_berr, power_berr, truncated, bins_drops, power_drops);
      errors = errors + 1;
    end

    // ---- the zoom engine on the same ring
    @(negedge clk) zoom_en = 1;
    // k0 where the stimulus has signal (tones at bins 63, 236, 307, 550, 793)
    submit(1, 3, 15, 230, 3);              // small: B 16, 8 frames, 32 words
    submit(2, 5, 31, 60, 3);               // 4 chunks (512 points), one context
    submit(3, 6, 39, 300, 3);              // both contexts (S 2560), 640 words
    wait (zoom_done >= 1);
    submit(4, 4, 23, 540, 3);              // queued behind the double job
    submit(5, 3, 7, 232, 3);               // the strong tone, 8 frames
    submit(6, 6, 31, 786, 3);              // S 2048, 8 chunks
    wait (zoom_done >= NJOBS);
    // a few more lines, so the last chunk is surely in memory
    repeat (6 * N) @(negedge clk);
    $display("tb_top: %0d jobs done by frame %0d (%0d recorded), clock %0d", zoom_done, dut.frame, rec_frames, t);
    if (rec_frames >= MAXF) begin
      $display("tb_top: more frames than recorded");
      errors = errors + 1;
    end
    check_stream;
    $fclose(fin);
    $fclose(fout);
    if (zoom_done !== NJOBS || zoom_ovf || zoom_bad || power_drops || power_ovf || power_berr || truncated) begin
      $display("status: zoom_done %0d (want %0d), zoom_ovf %b, zoom_bad %b, power_drops %0d, power_ovf %b, bresp %b, truncated %b",
               zoom_done, NJOBS, zoom_ovf, zoom_bad, power_drops, power_ovf, power_berr, truncated);
      errors = errors + 1;
    end
    if (errors == 0) $display("tb_top: PASSED (ADC to DDR: %0d bin frames, a power line; %0d zoom jobs sharing the power ring)", VF, NJOBS);
    else $display("tb_top: FAILED (%0d errors)", errors);
    $finish;
  end

  initial begin
    #40_000_000;
    $display("tb_top: FAILED (timeout: bins ptr %0d, power ptr %0d)", bins_ptr, power_ptr);
    $finish;
  end

endmodule

`default_nettype wire
