// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps

// pfb_zoom alone: bins one a clock (k = 0..2047 a frame) from a function of
// (frame, k) — noise of about 50 LSB rms, tones in a few bins strong enough
// for pass shifts 1 and 2 and one that saturates at shift 0 — and jobs
// through the queue. Each completed job is dumped for scripts/zoom_model.py
// (bit-exact): IN its frames (recomputed from the header's frame0), OUT its
// sat flag and floats. Checked here: chunk framing (header, chunk numbers,
// counts, tag, lengths), no word outside a chunk, every chunk out within
// 192 clocks of the clock it took out_ok (dut.o_take), the queue's
// overflow, a bad job, enable dropped mid-run, jobs_done.
//
// Phases: (A) a double job (n 16, B 256), n 8 B 256 at shift 0 (a
// saturating bin), a bad job, n 32 B 33 at shift 7; two jobs with
// overlapping bins captured together; two more bad ones. (B) enable
// dropped while a job's chunk is out and another captures, a double job
// queued. (C) n 2048 B 1 on one context for 2048 frames while the other
// takes n 512, n 128 (saturating) and a burst of 18 small jobs (the queue
// overflows; one of them double, so it waits for the long one).

module tb_zoom;

  reg clk = 0;
  always #4 clk = ~clk;

  reg               rst = 1;
  reg signed [24:0] re = 0, im = 0;
  reg [10:0]        k = 0;
  reg               valid = 0;
  reg [15:0]        frame = 0;
  reg               enable = 0;
  reg               job_we = 0;
  reg [31:0]        job_data = 0;
  wire [4:0]        q_free;
  wire [15:0]       jobs_done;
  wire              q_ovf, bad_job;
  wire [9:0]        tw_addr;
  reg  [35:0]       tw_q = 0;
  reg               out_ok = 0;
  wire [63:0]       s_data;
  wire              s_valid, s_first;

  pfb_zoom #(.WIN_FILE("../rtl/gen/zoom_win.mem")) dut (
    .clk(clk), .rst(rst), .in_re(re), .in_im(im), .in_k(k), .in_valid(valid),
    .in_frame(frame), .enable(enable), .job_we(job_we), .job_data(job_data),
    .q_free(q_free), .jobs_done(jobs_done), .q_ovf(q_ovf), .bad_job(bad_job),
    .tw_addr(tw_addr), .tw_q(tw_q), .out_ok(out_ok),
    .s_data(s_data), .s_valid(s_valid), .s_first(s_first));

  // the split stage's twiddle ROM, registered read
  reg [35:0] tw [0:2048];
  initial $readmemh("../rtl/gen/pfb_split_tw.mem", tw);
  always @(posedge clk) tw_q <= tw[tw_addr];

  // ---------------------------------------------------------------- bins
  function signed [24:0] val(input integer f, input integer kk, input integer part);
    integer s, a;
    real    x, amp, fq;
    begin
      s = f * 7919 + kk * 104729 + part * 15485863 + 977;
      a = $random(s);
      a = $random(s);
      x = (a >>> 24) * 2.0 / 3.0;
      case (kk)
        10, 115, 301, 500: amp = 15099494.0;   // 0.9 full scale: shift 2 at shift 3
        40, 605, 1201:     amp = 8388608.0;    // 2^23: shift 1 at shift 3
        1900:              amp = 4194304.0;    // 2^22: saturates at shift 0
        default:           amp = 0.0;
      endcase
      if (amp != 0.0) begin
        fq = 0.137 + kk * 0.00113;
        if (part != 0) x = x + amp * $sin(6.283185307179586 * fq * f);
        else           x = x + amp * $cos(6.283185307179586 * fq * f);
      end
      val = $rtoi(x);
    end
  endfunction

  // bins no job submitted so far covers carry a cheap pattern instead (the
  // simulation's time goes mostly to val())
  integer   fr = 0, kn = 0;
  reg [0:2047] need = 0;
  always @(posedge clk) begin
    valid <= 1;
    k     <= kn;
    frame <= fr;
    if (need[kn]) begin
      re <= val(fr, kn, 0);
      im <= val(fr, kn, 1);
    end else begin
      re <= {fr[13:0], kn[10:0]};
      im <= -{kn[10:0], fr[13:0]};
    end
    if (kn == 2047) begin
      kn = 0;
      fr = fr + 1;
    end else
      kn = kn + 1;
  end

  // ---------------------------------------------------------------- out_ok
  // low and high for random stretches (0..299 and 1..400 clocks)
  integer okseed = 5, okcnt = 0;
  always @(posedge clk)
    if (okcnt == 0) begin
      out_ok <= !out_ok;
      if (out_ok) okcnt = {$random(okseed)} % 300;
      else        okcnt = {$random(okseed)} % 400 + 1;
    end else
      okcnt = okcnt - 1;

  // ---------------------------------------------------------------- jobs
  // per tag: 0 unused, 1 expected, 2 done, 3 dropped (queue full), 4 bad,
  // 5 lost (enable dropped)
  integer    t_st [0:63];
  integer    t_sub [0:63];
  reg [3:0]  t_lg [0:63];
  reg [7:0]  t_bm1 [0:63];
  reg [10:0] t_k0 [0:63];
  reg [2:0]  t_sh [0:63];
  integer    n_drop = 0, n_bad = 0, n_lost = 0;
  integer    ti;
  initial for (ti = 0; ti < 64; ti = ti + 1) t_st[ti] = 0;

  task fail(input [8*64-1:0] msg);
    begin
      $display("tb_zoom: FAILED at clock %0d: %0s", cyc, msg);
      $finish;
    end
  endtask

  task submit(input [5:0] tag, input [3:0] lg, input [7:0] bm1, input [10:0] k0,
              input [2:0] sh, input bad);
    begin
      if (t_st[tag] != 0) fail("tag reused");
      for (ti = k0; ti <= k0 + bm1 && ti < 2048; ti = ti + 1) need[ti] = 1'b1;
      @(posedge clk) begin
        job_we   <= 1;
        job_data <= {tag, sh, lg, bm1, k0};
      end
      @(posedge clk) begin
        job_we <= 0;
        t_lg[tag]  = lg;
        t_bm1[tag] = bm1;
        t_k0[tag]  = k0;
        t_sh[tag]  = sh;
        t_sub[tag] = fr;
        // q_free as the engine saw it at the write
        if (q_free == 0) begin
          t_st[tag] = 3;
          n_drop = n_drop + 1;
        end else if (bad) begin
          t_st[tag] = 4;
          n_bad = n_bad + 1;
        end else
          t_st[tag] = 1;
      end
    end
  endtask

  function integer jobs_pending(input dummy);
    integer t;
    begin
      jobs_pending = 0;
      for (t = 0; t < 64; t = t + 1) if (t_st[t] == 1) jobs_pending = jobs_pending + 1;
    end
  endfunction

  task wait_all(input integer max_frames);
    integer f0;
    begin
      f0 = fr;
      while (jobs_pending(0) != 0 && fr - f0 < max_frames) repeat (64) @(posedge clk);
      if (jobs_pending(0) != 0) fail("jobs not done in time");
    end
  endtask

  // ---------------------------------------------------------------- output
  integer    fin, fout;
  integer    cyc = 0;
  integer    t_take = -1, max_lat = 0;
  integer    ch_open = 0, ch_words = 0, ch_need = 0, ch_hdr = 0;
  integer    cur_tag = -1, cur_ch = 0, cur_nch = 0, cur_pts = 0, cur_S = 0;
  integer    n_done = 0, n_chunks = 0, drop_cyc = -1;
  reg        cur_sat = 0;
  reg [15:0] cur_fr0 = 0;
  reg [31:0] pts [0:2047];
  reg [5:0]  htag;
  reg [3:0]  hch, hnch;
  integer    n_sh1 = 0, n_sh2 = 0;
  integer    seen_ovf = 0, seen_bad = 0, seen_conc = 0, stalls = 0, n_sat = 0;
  integer    lg, nb, nn, tt, bb, pp;

  task dump_job;
    begin
      lg = t_lg[cur_tag];
      nb = t_bm1[cur_tag] + 1;
      nn = 1 << lg;
      $fwrite(fin, "job %0d %0d %0d\n", lg, nb, t_sh[cur_tag]);
      for (tt = 0; tt < nn; tt = tt + 1) begin
        for (bb = 0; bb < nb; bb = bb + 1)
          $fwrite(fin, "%h %h ", val(cur_fr0 + tt, t_k0[cur_tag] + bb, 0),
                  val(cur_fr0 + tt, t_k0[cur_tag] + bb, 1));
        $fwrite(fin, "\n");
      end
      $fwrite(fout, "sat %0d\n", cur_sat);
      for (pp = 0; pp < cur_S / 2; pp = pp + 1) $fwrite(fout, "%h\n", pts[pp]);
      if (cur_sat) n_sat = n_sat + 1;
    end
  endtask

  always @(posedge clk) begin
    cyc = cyc + 1;
    if (q_ovf) seen_ovf = 1;
    if (bad_job) seen_bad = 1;
    if (dut.c0.cap_on && dut.c1.cap_on && dut.c0.k0r < dut.c1.ke && dut.c1.k0r < dut.c0.ke)
      seen_conc = 1;
    if (dut.stall && dut.fm) stalls = stalls + 1;
    if (dut.ps == 5 && dut.ce) begin           // a pass starts (P_PASS2): its scaling
      if (dut.sh == 1) n_sh1 = n_sh1 + 1;
      if (dut.sh == 2) n_sh2 = n_sh2 + 1;
    end
    if (dut.o_take) begin
      if (ch_open) fail("out_ok taken inside a chunk");
      t_take = cyc;
    end
    if (s_valid) begin
      if (t_take < 0 || cyc - t_take > 192 || cyc <= t_take) fail("a word outside the 192 clocks");
      if (cyc - t_take > max_lat) max_lat = cyc - t_take;
      if (s_first) begin
        if (ch_open) fail("a header inside a chunk");
        if (s_data[63:48] != 16'h5042 || s_data[47:44] != 4'd3 || s_data[39:38] != 0 ||
            s_data[30:20] != 0)
          fail("bad header");
        htag = s_data[37:32];
        hch  = s_data[43:40];
        hnch = s_data[19:16];
        if (hch == 0) begin
          // a new job: one left unfinished must have been lost to enable
          if (cur_tag >= 0 && t_st[cur_tag] != 5) fail("a job's chunks cut short");
          if (t_st[htag] != 1 && t_st[htag] != 5) fail("a chunk of an unexpected tag");
          cur_tag = htag;
          cur_ch  = 0;
          cur_pts = 0;
          cur_S   = (t_bm1[htag] + 1) << t_lg[htag];
          cur_nch = (cur_S - 1) / 256 + 1;
          cur_sat = s_data[31];
          cur_fr0 = s_data[15:0];
          if (cur_fr0 < t_sub[htag]) fail("frame0 before the job");
        end else begin
          if (htag != cur_tag || hch != cur_ch + 1) fail("chunk out of sequence");
          if (s_data[31] != cur_sat || s_data[15:0] != cur_fr0) fail("header changed");
          cur_ch = hch;
        end
        if (hnch + 1 != cur_nch) fail("chunk count");
        ch_need  = cur_S / 4 - 64 * cur_ch;
        if (ch_need > 64) ch_need = 64;
        ch_words = 0;
        ch_open  = 1;
        ch_hdr   = cyc;
        n_chunks = n_chunks + 1;
      end else begin
        if (!ch_open) fail("a word outside a chunk");
        pts[cur_pts]     = s_data[31:0];
        pts[cur_pts + 1] = s_data[63:32];
        cur_pts  = cur_pts + 2;
        ch_words = ch_words + 1;
        if (ch_words == ch_need) begin
          ch_open = 0;
          if (cur_ch == cur_nch - 1) begin
            // complete; a lost job only if its last chunk began before the drop
            if (t_st[cur_tag] == 5 && !(drop_cyc >= 0 && ch_hdr < drop_cyc))
              fail("a lost job completed");
            if (t_st[cur_tag] == 5) n_lost = n_lost - 1;
            t_st[cur_tag] = 2;
            n_done = n_done + 1;
            dump_job;
            $display("tb_zoom: job %0d done, frame %0d", cur_tag, fr);
            cur_tag = -1;
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------- the run
  integer b;
  initial begin
    fin  = $fopen("out/zoom_in.txt", "w");
    fout = $fopen("out/zoom_out.txt", "w");
    repeat (10) @(posedge clk);
    rst <= 0;
    enable <= 1;
    repeat (10) @(posedge clk);

    // (A)
    submit(1, 4, 255, 0, 3, 0);             // double: S 4096
    submit(2, 3, 255, 1792, 0, 0);          // to bin 2047, shift 0, bin 1900 saturates
    submit(3, 2, 3, 100, 3, 1);             // bad: logn 2
    submit(4, 5, 32, 1000, 7, 0);           // B 33, shift 7
    wait_all(400);
    if (!seen_bad) fail("bad_job not set");
    submit(5, 6, 19, 100, 3, 0);            // bins 100..119
    submit(6, 5, 29, 110, 7, 0);            // bins 110..139, together
    submit(7, 4, 15, 2040, 3, 1);           // bad: k0 + B > 2048
    submit(8, 9, 15, 0, 3, 1);              // bad: S 8192
    wait_all(400);
    if (!seen_conc) fail("no overlapping captures together");

    // (B) a job's chunk out, another capturing, a double queued: drop enable
    submit(10, 7, 15, 600, 3, 0);
    submit(11, 8, 7, 1200, 3, 0);
    submit(12, 6, 39, 50, 3, 0);
    while (!(s_valid && s_first && s_data[37:32] == 10 && s_data[43:40] == 2)) @(posedge clk);
    repeat (20) @(posedge clk);
    if (!q_ovf && !bad_job && q_free == 16) fail("nothing to clear");
    @(posedge clk) enable <= 0;
    drop_cyc = cyc + 1;
    for (b = 0; b < 64; b = b + 1)
      if (t_st[b] == 1) begin
        t_st[b] = 5;
        n_lost = n_lost + 1;
      end
    repeat (3) @(posedge clk);
    if (q_ovf || bad_job || q_free != 16) fail("enable 0 did not clear");
    @(posedge clk) enable <= 1;
    repeat (300) @(posedge clk);
    if (ch_open || dut.ps != 0) fail("not idle after the drop");

    // (C)
    submit(20, 11, 0, 500, 3, 0);           // n 2048: one context for 2048 frames
    submit(21, 9, 3, 300, 3, 0);
    submit(22, 7, 15, 1195, 0, 0);          // saturates (bin 1201 at shift 0)
    for (b = 0; b < 18; b = b + 1)
      if (b == 15)
        submit(30 + b, 5, 99, 1500, 3, 0);  // double: waits for tag 20
      else
        submit(30 + b, 3 + b % 4, (b * 7) % 32, (b * 97) % 1900,
               b % 3 == 0 ? 3'd0 : b % 3 == 1 ? 3'd3 : 3'd7, 0);
    if (!seen_ovf) fail("the queue did not overflow");
    wait_all(2400);
    repeat (100) @(posedge clk);

    if (ch_open) fail("a chunk open at the end");
    if (jobs_done != n_done) fail("jobs_done");
    if (n_drop == 0 || stalls == 0 || n_sat < 2 || n_sh1 == 0 || n_sh2 == 0) fail("coverage");
    $fclose(fin);
    $fclose(fout);
    $display("tb_zoom: %0d jobs out in %0d chunks (%0d bad, %0d dropped, %0d lost to enable), %0d with sat, passes scaled by 2 %0d and 4 %0d, %0d FFT stall clocks, latest word %0d clocks after out_ok",
             n_done, n_chunks, n_bad, n_drop, n_lost, n_sat, n_sh1, n_sh2, stalls, max_lat);
    $display("tb_zoom: PASSED (compare with scripts/zoom_model.py)");
    $finish;
  end

  initial begin
    #80000000;
    $display("tb_zoom: FAILED, timeout");
    $finish;
  end

endmodule
