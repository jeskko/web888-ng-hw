// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The zoom engine (hw/docs/channelizer.md §3.9): jobs "bins k0 .. k0 + B - 1,
// FFT length n = 2^logn", each bin's n frames windowed and transformed, the
// middle n/2 points' power out as float32 in chunks for the power ring.
// scripts/zoom_model.py is the bit-exact model.
//
// * Jobs: {tag[5:0], shift[2:0], logn[3:0], B - 1 [7:0], k0[10:0]} into a
//   16-deep queue (a write when full is dropped: q_ovf). At the head a job
//   with logn outside 3..11, B * n > 4096 or k0 + B > 2048 is discarded
//   (bad_job); otherwise the head waits for its context(s), S = B * n <=
//   2048 one, a larger job both. enable = 0 clears the queue, the contexts
//   and the flags; a chunk being sent finishes.
// * Work RAM: 4096 x 44 bits ({re, im}, 22 bits each), true dual port.
//   Context c owns addresses c * 2048 .. and port c (A, B); a double job
//   0 .. 4095 and port A. Capture (pfb_zoom_ctx): from the first frame
//   start, bin k0 + b of frame t, rounded by `shift` (half up) and
//   saturated to 22 bits, at base + (b << logn | bitrev(t)).
// * FFT (one, a job at a time): per bin a window pass (the pair at 2i,
//   2i + 1: times t0 = bitrev(2i) and t0 + n/2, window entries
//   t0 * 2048/n and 1024 - t0 * 2048/n), then logn radix-2 DIT passes in
//   place. An op (a butterfly or a window pair) reads its two words through
//   both ports in one clock and writes them nine clocks later, so an op
//   issues every second clock; the pipeline drains between passes. It is
//   clock-enabled: it stalls in any clock a capture writes. Block floating
//   point per bin: a pass's outputs are scaled by 2^-sh (rounded half up),
//   sh from the top five size bits of all the pass before wrote (0 under
//   13, 1 under 26, else 2); the bin's exponent e is the sum.
// * Out: per bin FFT points 3n/4 .. n-1, 0 .. n/4-1 through the job's own
//   port (never stalled), |X|^2 as float32 times 2^(2 (e + shift)), mantissa
//   truncated, two a word {f[2i+1], f[2i]}, chunks of up to 64 words after a
//   header {16'h5042, 4'd3, chunk, 2'd0, tag, sat, 11'd0, chunks - 1,
//   frame0} (s_first). A chunk starts in a clock with out_ok = 1 and is out
//   in the 140 clocks after it; the next waits until it is.

module pfb_zoom #(
  parameter WIN_FILE = "zoom_win.mem"
) (
  input  wire               clk,
  input  wire               rst,
  // the channelizer's bins, k = 0..2047 ascending each frame
  input  wire signed [24:0] in_re,
  input  wire signed [24:0] in_im,
  input  wire [10:0]        in_k,
  input  wire               in_valid,
  input  wire [15:0]        in_frame,

  input  wire               enable,
  input  wire               job_we,
  input  wire [31:0]        job_data,
  output wire [4:0]         q_free,
  output reg  [15:0]        jobs_done = 16'd0,
  output reg                q_ovf = 1'b0,
  output reg                bad_job = 1'b0,

  // the split stage's twiddle ROM (W_4096^a, a < 1024): tw_q the clock after
  output wire [9:0]         tw_addr,
  input  wire [35:0]        tw_q,

  input  wire               out_ok,
  output reg  [63:0]        s_data = 64'd0,
  output reg                s_valid = 1'b0,
  output reg                s_first = 1'b0
);

  integer i;
  wire clr = rst || !enable;

  function [9:0] rev10(input [9:0] v);
    rev10 = {v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9]};
  endfunction

  function [4:0] lz16(input [15:0] v);    // leading zeros (16: none set)
    casez (v)
      16'b1???????????????: lz16 = 5'd0;
      16'b01??????????????: lz16 = 5'd1;
      16'b001?????????????: lz16 = 5'd2;
      16'b0001????????????: lz16 = 5'd3;
      16'b00001???????????: lz16 = 5'd4;
      16'b000001??????????: lz16 = 5'd5;
      16'b0000001?????????: lz16 = 5'd6;
      16'b00000001????????: lz16 = 5'd7;
      16'b000000001???????: lz16 = 5'd8;
      16'b0000000001??????: lz16 = 5'd9;
      16'b00000000001?????: lz16 = 5'd10;
      16'b000000000001????: lz16 = 5'd11;
      16'b0000000000001???: lz16 = 5'd12;
      16'b00000000000001??: lz16 = 5'd13;
      16'b000000000000001?: lz16 = 5'd14;
      16'b0000000000000001: lz16 = 5'd15;
      default:              lz16 = 5'd16;
    endcase
  endfunction

  // a pass's scaling: (u + 2^(s-1)) >> s, the low 22 bits
  function [21:0] scl(input [25:0] u, input [1:0] s);
    case (s)
      2'd1:    scl = u[22:1] + {21'd0, u[0]};
      2'd2:    scl = u[23:2] + {21'd0, u[1]};
      default: scl = u[21:0];
    endcase
  endfunction

  // a component's top five size bits: (v < 0 ? ~v : v) >> 16
  function [4:0] sz5(input [21:0] w);
    sz5 = w[21] ? ~w[20:16] : w[20:16];
  endfunction

  // ---------------------------------------------------------------- queue
  reg [31:0] qm [0:15];
  reg [3:0]  qwp = 4'd0, qrp = 4'd0;
  reg [4:0]  qfree = 5'd16;
  reg [1:0]  hs = 2'd0;                  // head: 0 empty, 1 read, 2, 3 checked
  wire       q_wr = job_we && !clr && qfree != 5'd0;
  wire       q_rd = !clr && hs == 2'd0 && qfree != 5'd16;
  assign q_free = qfree;
  initial for (i = 0; i < 16; i = i + 1) qm[i] = 32'd0;
  always @(posedge clk)
    if (q_wr) qm[qwp] <= job_data;
  always @(posedge clk)
    if (clr) begin
      qwp   <= 4'd0;
      qrp   <= 4'd0;
      qfree <= 5'd16;
      q_ovf <= 1'b0;
    end else begin
      if (job_we && qfree == 5'd0) q_ovf <= 1'b1;
      if (q_wr) qwp <= qwp + 4'd1;
      if (q_rd) qrp <= qrp + 4'd1;
      qfree <= qfree - {4'd0, q_wr} + {4'd0, q_rd};
    end

  // the head: checked in two steps, then dispatched or discarded
  reg  [31:0] hj = 32'd0;
  wire [2:0]  h_sh  = hj[25:23];
  wire [3:0]  h_lg  = hj[22:19];
  wire [7:0]  h_bm1 = hj[18:11];
  wire [10:0] h_k0  = hj[10:0];
  reg  [7:0]  h_szm = 8'd0, h_sgm = 8'd0;  // B - 1 bits that make S > 4096, > 2048
  reg  [11:0] h_kend = 12'd0, h_n = 12'd0, h_nm2 = 12'd0;
  reg  [10:0] h_irev = 11'd0;
  reg  [6:0]  h_rnd = 7'd0;
  reg         h_lgok = 1'b0, h_bad = 1'b0, h_dbl = 1'b0;
  wire        go0, go1;
  always @(posedge clk)
    if (clr) begin
      hs      <= 2'd0;
      bad_job <= 1'b0;
    end else
      case (hs)
        2'd0: if (q_rd) begin
          hj <= qm[qrp];
          hs <= 2'd1;
        end
        2'd1: begin
          h_lgok <= h_lg >= 4'd3 && h_lg <= 4'd11;
          h_szm  <= 8'hff << (4'd12 - h_lg);
          h_sgm  <= 8'hff << (4'd11 - h_lg);
          h_kend <= {1'b0, h_k0} + {4'd0, h_bm1} + 12'd1;
          h_n    <= 12'd1 << h_lg;
          h_irev <= 11'd1024 >> (h_lg - 4'd1);
          h_rnd  <= h_sh == 3'd0 ? 7'd0 : 7'd1 << (h_sh - 3'd1);
          hs     <= 2'd2;
        end
        2'd2: begin
          h_bad <= !h_lgok || (h_bm1 & h_szm) != 8'd0 || (h_kend[11] && h_kend[10:0] != 11'd0);
          h_dbl <= (h_bm1 & h_sgm) != 8'd0;
          h_nm2 <= h_n - 12'd2;
          hs    <= 2'd3;
        end
        default: if (h_bad) begin
          bad_job <= 1'b1;
          hs      <= 2'd0;
        end else if (go0 || go1)
          hs <= 2'd0;
      endcase

  // ---------------------------------------------------------------- capture
  reg signed [24:0] re1 = 25'sd0, im1 = 25'sd0;
  reg [10:0]        k1 = 11'd0;
  reg               v1 = 1'b0, zl1 = 1'b0, zh1 = 1'b0;
  reg [15:0]        fr1 = 16'd0;
  always @(posedge clk) begin
    re1 <= in_re;
    im1 <= in_im;
    k1  <= in_k;
    v1  <= in_valid;
    zl1 <= in_k[5:0] == 6'd0;
    zh1 <= in_k[10:6] == 5'd0;
    fr1 <= in_frame;
  end

  localparam [1:0] C_IDLE = 2'd0, C_CAP = 2'd1, C_WAIT = 2'd2, C_BUSY = 2'd3;
  wire [1:0]  c0_st, c1_st;
  wire [31:0] c0_jw, c1_jw;
  wire        c0_dbl, c1_dbl, c0_sat, c1_sat;
  wire [15:0] c0_fr0, c1_fr0;
  wire        c0_hit, c1_hit, c0_we, c1_we;
  wire [11:0] c0_addr, c1_addr;
  wire [43:0] c0_d, c1_d;
  reg         pabort = 1'b0, rel = 1'b0, pctx = 1'b0, pdbl = 1'b0;
  wire        take0, take1;

  wire h_rdy = hs == 2'd3 && !h_bad && !clr && !pabort;
  assign go0 = h_rdy && c0_st == C_IDLE && (!h_dbl || c1_st == C_IDLE);
  assign go1 = h_rdy && !h_dbl && c0_st != C_IDLE && c1_st == C_IDLE;

  pfb_zoom_ctx #(.BASE(12'd0)) c0 (
    .clk(clk), .clr(clr), .re1(re1), .im1(im1), .k1(k1), .v1(v1), .zl1(zl1), .zh1(zh1),
    .fr1(fr1), .go(go0), .hold(1'b0), .job(hj), .dbl(h_dbl), .kend(h_kend), .n(h_n),
    .nm2(h_nm2), .irev(h_irev), .rnd(h_rnd), .take(take0), .done_rel(rel && (!pctx || pdbl)),
    .state(c0_st), .jw(c0_jw), .jdbl(c0_dbl), .frame0(c0_fr0), .sat(c0_sat),
    .hit3(c0_hit), .we(c0_we), .addr(c0_addr), .d(c0_d));

  pfb_zoom_ctx #(.BASE(12'd2048)) c1 (
    .clk(clk), .clr(clr), .re1(re1), .im1(im1), .k1(k1), .v1(v1), .zl1(zl1), .zh1(zh1),
    .fr1(fr1), .go(go1), .hold(go0 && h_dbl), .job(hj), .dbl(1'b0), .kend(h_kend), .n(h_n),
    .nm2(h_nm2), .irev(h_irev), .rnd(h_rnd), .take(take1), .done_rel(rel && (pctx || pdbl)),
    .state(c1_st), .jw(c1_jw), .jdbl(c1_dbl), .frame0(c1_fr0), .sat(c1_sat),
    .hit3(c1_hit), .we(c1_we), .addr(c1_addr), .d(c1_d));

  // the FFT's clock enable: no capture write this clock
  reg  stall = 1'b0;
  always @(posedge clk) stall <= c0_hit || c1_hit;
  wire ce = !stall;

  // ---------------------------------------------------------------- processor
  localparam [3:0] P_IDLE = 4'd0, P_J1 = 4'd1, P_J2 = 4'd2, P_BIN = 4'd3,
                   P_PASS1 = 4'd4, P_PASS2 = 4'd5, P_RUN = 4'd6, P_DRAIN = 4'd7,
                   P_ABORT = 4'd8, P_OS1 = 4'd9, P_OS2 = 4'd10, P_OS3 = 4'd11,
                   P_OWAIT = 4'd12, P_ORUN = 4'd13, P_ODRAIN = 4'd14;
  reg [3:0] ps = P_IDLE;

  // contexts waiting for the processor: the one waiting longer first
  wire c0w = c0_st == C_WAIT, c1w = c1_st == C_WAIT;
  reg  wold = 1'b0;
  always @(posedge clk) begin
    if (c0w && !c1w) wold <= 1'b0;
    if (c1w && !c0w) wold <= 1'b1;
  end
  wire tk_any = ps == P_IDLE && !clr && (c0w || c1w);
  wire tk1    = c1w && (!c0w || wold);
  assign take0 = tk_any && !tk1;
  assign take1 = tk_any && tk1;

  // the job
  reg        psat = 1'b0;
  reg [5:0]  ptag = 6'd0;
  reg [2:0]  psh = 3'd0;
  reg [3:0]  plg = 4'd0;
  reg [7:0]  pbm1 = 8'd0;
  reg [15:0] pfr0 = 16'd0;
  reg [11:0] pbase = 12'd0, pn = 12'd0, pmask = 12'd0, pj0 = 12'd0;
  reg signed [11:0] popc0 = 12'sd0;      // n/2 - 2
  reg [12:0] pS = 13'd0;
  reg [8:0]  pE0 = 9'd0;                 // 174 + 2 shift: a float's exponent less lz, 2e
  reg [3:0]  pnch = 4'd0;

  // FFT sequencer
  reg [11:0] binaddr = 12'd0;
  reg [7:0]  fbin = 8'd0;
  reg signed [8:0] bl = 9'sd0;           // bins left - 1
  reg [3:0]  pd = 4'd0;                  // passes left
  reg [1:0]  sh = 2'd0;                  // this pass's scaling
  reg [4:0]  e_acc = 5'd0;
  reg        acc13 = 1'b0, acc26 = 1'b0;
  reg        ph = 1'b0;                  // 0: read slot, 1: write slot
  // the next op
  reg [11:0] op_a = 12'd0, op_b = 12'd0;  // also the output's read address
  reg [11:0] inc_w = 12'd0, inc_n = 12'd0, half = 12'd0, step = 12'd0;
  reg [10:0] twk = 11'd0;
  reg        byp = 1'b0, pwin = 1'b0;
  reg [9:0]  wa0 = 10'd0, ipre = 10'd0;
  reg [10:0] wa1 = 11'd0;
  reg signed [11:0] jd = 12'sd0, opc = 12'sd0;   // group, pass: ops left - 2
  reg [4:0]  eram [0:255];               // the bins' exponents
  initial for (i = 0; i < 256; i = i + 1) eram[i] = 5'd0;

  // output sequencer
  reg [11:0] obin = 12'd0, oj = 12'd0;
  reg signed [11:0] ojc = 12'sd0;        // the bin's points left - 2
  reg signed [12:0] optl = 13'sd0;       // the job's
  reg signed [7:0]  ocpl = 8'sd0;        // the chunk's
  reg [7:0]  erd = 8'd0;
  reg [8:0]  ecur = 9'd0, enext = 9'd0;
  reg [3:0]  och = 4'd0;
  reg        godd = 1'b0, ojdone = 1'b0;
  reg [16:0] g = 17'd0;                  // a point issued: {v, header, odd, last, chunk, E}
  reg        o_end = 1'b0;

  wire [8:0] vv;                         // the FFT pipeline's ops, steps 1..9
  reg  [3:0] g13 = 4'd0, g26 = 4'd0;
  wire       issue = ps == P_RUN && ce && !ph && !pabort;
  wire       fm = ps == P_BIN || ps == P_PASS1 || ps == P_PASS2 || ps == P_RUN ||
                  ps == P_DRAIN || ps == P_ABORT;
  // the clock an output chunk takes out_ok (the testbench checks its bound)
  wire       o_take = ps == P_OWAIT && !pabort && out_ok;

  always @(posedge clk)
    if (!fm) ph <= 1'b0;
    else if (ce) ph <= !ph;

  always @(posedge clk) enext <= pE0 + {3'd0, eram[erd], 1'b0};

  always @(posedge clk) begin
    rel <= 1'b0;
    g   <= 17'd0;
    if (ce && vv[8]) begin
      acc13 <= acc13 || g13 != 4'd0;
      acc26 <= acc26 || g26 != 4'd0;
    end
    if (clr && ps != P_IDLE) pabort <= 1'b1;
    if (rst) begin
      ps        <= P_IDLE;
      pabort    <= 1'b0;
      jobs_done <= 16'd0;
    end else
      case (ps)
        P_IDLE: begin
          pabort <= 1'b0;
          if (tk_any) begin
            pctx <= tk1;
            pdbl <= !tk1 && c0_dbl;
            pbase <= tk1 ? 12'd2048 : 12'd0;
            {ptag, psh, plg, pbm1} <= tk1 ? c1_jw[31:11] : c0_jw[31:11];
            pfr0 <= tk1 ? c1_fr0 : c0_fr0;
            psat <= tk1 ? c1_sat : c0_sat;
            ps   <= P_J1;
          end
        end
        P_J1: begin
          pn  <= 12'd1 << plg;
          pS  <= {5'd0, pbm1} << plg;
          pE0 <= 9'd174 + {5'd0, psh, 1'b0};
          ps  <= P_J2;
        end
        P_J2: begin
          pS      <= pS + {1'b0, pn};
          pmask   <= pn - 12'd1;
          pj0     <= {1'b0, pn[11:1]} + {2'b0, pn[11:2]};
          popc0   <= $signed({1'b0, pn[11:1]}) - 12'sd2;
          binaddr <= pbase;
          fbin    <= 8'd0;
          bl      <= $signed({1'b0, pbm1}) - 9'sd1;
          ps      <= P_BIN;
        end
        // a bin: the window pass's ops (shift 0)
        P_BIN: if (ce) begin
          e_acc <= 5'd0;
          pd    <= plg;
          pwin  <= 1'b1;
          sh    <= 2'd0;
          acc13 <= 1'b0;
          acc26 <= 1'b0;
          op_a  <= binaddr;
          op_b  <= binaddr | 12'd1;
          inc_w <= 12'd2;
          inc_n <= 12'd2;
          jd    <= 12'sd2047;
          ipre  <= 10'd1;
          wa0   <= 10'd0;
          wa1   <= 11'd1024;
          opc   <= popc0;
          ps    <= P_RUN;
        end
        // a pass: half, the twiddle step and the scaling, then its ops
        P_PASS1: if (ce) begin
          pwin  <= 1'b0;
          pd    <= pd - 4'd1;
          half  <= pwin ? 12'd1 : {half[10:0], 1'b0};
          step  <= pwin ? 12'd2048 : {1'b0, step[11:1]};
          sh    <= acc26 ? 2'd2 : acc13 ? 2'd1 : 2'd0;
          e_acc <= e_acc + (acc26 ? 5'd2 : acc13 ? 5'd1 : 5'd0);
          acc13 <= 1'b0;
          acc26 <= 1'b0;
          ps    <= P_PASS2;
        end
        P_PASS2: if (ce) begin
          op_a  <= binaddr;
          op_b  <= binaddr | half;
          twk   <= 11'd0;
          byp   <= 1'b1;
          jd    <= $signed(half) - 12'sd2;
          inc_w <= half + 12'd1;
          inc_n <= 12'd1;
          opc   <= popc0;
          ps    <= P_RUN;
        end
        P_RUN: if (ce) begin
          if (pabort)
            ps <= P_ABORT;
          else if (!ph) begin
            // the op goes out this clock; the next one
            op_a <= op_a + (jd[11] ? inc_w : inc_n);
            op_b <= op_b + (jd[11] ? inc_w : inc_n);
            twk  <= jd[11] ? 11'd0 : twk + step[10:0];
            byp  <= jd[11];
            jd   <= jd[11] ? $signed(half) - 12'sd2 : jd - 12'sd1;
            ipre <= ipre + 10'd1;
            wa0  <= rev10(ipre);
            wa1  <= 11'd1024 - {1'b0, rev10(ipre)};
            opc  <= opc - 12'sd1;
            if (opc[11]) ps <= P_DRAIN;
          end
        end
        P_DRAIN: if (ce) begin
          if (pabort)
            ps <= P_ABORT;
          else if (vv == 9'd0) begin
            if (pd == 4'd0) begin
              eram[fbin] <= e_acc;
              if (bl[8])
                ps <= P_OS1;
              else begin
                bl      <= bl - 9'sd1;
                fbin    <= fbin + 8'd1;
                binaddr <= binaddr + pn;
                ps      <= P_BIN;
              end
            end else
              ps <= P_PASS1;
          end
        end
        P_ABORT: if (ce && vv == 9'd0) begin
          rel <= 1'b1;
          ps  <= P_IDLE;
        end
        // output: counters, the first bin's exponent
        P_OS1: begin
          obin <= pbase;
          oj   <= pj0;
          ojc  <= popc0;
          optl <= $signed({1'b0, pS[12:1]}) - 13'sd2;
          pnch <= (pS - 13'd1) >> 8;
          erd  <= 8'd0;
          och  <= 4'd0;
          ps   <= P_OS2;
        end
        P_OS2: ps <= P_OS3;
        P_OS3: begin
          ecur <= enext;
          erd  <= 8'd1;
          ps   <= P_OWAIT;
        end
        P_OWAIT:
          if (pabort) begin
            rel <= 1'b1;
            ps  <= P_IDLE;
          end else if (out_ok) begin
            g    <= {1'b1, 1'b1, 1'b0, 1'b0, och, 9'd0};
            ocpl <= 8'sd126;
            godd <= 1'b0;
            ps   <= P_ORUN;
          end
        // a chunk's points, one a clock
        P_ORUN: begin
          op_a <= obin | (oj & pmask);
          op_b <= obin | (oj & pmask);
          g    <= {1'b1, 1'b0, godd, ocpl[7] || optl[12], och, ecur};
          godd <= !godd;
          if (ojc[11]) begin
            oj   <= pj0;
            ojc  <= popc0;
            obin <= obin + pn;
            ecur <= enext;
            erd  <= erd + 8'd1;
          end else begin
            oj  <= oj + 12'd1;
            ojc <= ojc - 12'sd1;
          end
          ocpl <= ocpl - 8'sd1;
          optl <= optl - 13'sd1;
          if (ocpl[7] || optl[12]) begin
            ojdone <= optl[12];
            ps     <= P_ODRAIN;
          end
        end
        P_ODRAIN: if (o_end) begin
          if (ojdone) jobs_done <= jobs_done + 16'd1;
          if (pabort || ojdone) begin
            rel <= 1'b1;
            ps  <= P_IDLE;
          end else begin
            och <= och + 4'd1;
            ps  <= P_OWAIT;
          end
        end
        default: ps <= P_IDLE;
      endcase
  end

  // ---------------------------------------------------------------- work RAM
  // the FFT's write step (9) and addresses
  reg  [43:0] wd_a = 44'd0, wd_b = 44'd0;
  reg  [107:0] fav = 108'd0, fbv = 108'd0;   // steps 1..9, step 1 lowest
  wire [11:0]  fa9 = fav[107:96], fb9 = fbv[107:96];

  (* ram_style = "block" *) reg [43:0] wram [0:4095];
`ifndef SYNTHESIS
  initial for (i = 0; i < 4096; i = i + 1) wram[i] = 44'd0;
`endif
  reg  [43:0] q_a = 44'd0, q_b = 44'd0;
  wire        f_we = ce && vv[8];
  wire [11:0] ad_a = c0_we ? c0_addr : ph ? fa9 : op_a;
  wire [11:0] ad_b = c1_we ? c1_addr : ph ? fb9 : op_b;
  wire        we_a = c0_we || f_we;
  wire        we_b = c1_we || f_we;
  wire [43:0] d_a  = c0_we ? c0_d : wd_a;
  wire [43:0] d_b  = c1_we ? c1_d : wd_b;
  always @(posedge clk)
    if (we_a) wram[ad_a] <= d_a;
    else      q_a <= wram[ad_a];
  always @(posedge clk)
    if (we_b) wram[ad_b] <= d_b;
    else      q_b <= wram[ad_b];

  // ---------------------------------------------------------------- tables
  (* rom_style = "block" *) reg [16:0] wrom [0:1023];
  initial $readmemh(WIN_FILE, wrom);
  reg [16:0] wq0 = 17'd0, wq1 = 17'd0;
  always @(posedge clk) begin
    wq0 <= wrom[wa0];
    wq1 <= wrom[wa1[9:0]];
  end
  assign tw_addr = twk[9:0];

  // ---------------------------------------------------------------- FFT datapath
  // The clock after a read, its words, twiddle and window entries go into
  // plain registers (not clock-enabled: read in a clock with ce, so the
  // registers hold until the op's step 2, the next issue). Everything else
  // advances with ce: step k is the k-th enabled clock after the issue.
  reg        rd1 = 1'b0, f1024 = 1'b0;
  reg [43:0] xa = 44'd0, xb = 44'd0;
  reg [35:0] xtw = 36'd0;
  reg [16:0] xw0 = 17'd0, xw1 = 17'd0;
  always @(posedge clk) begin
    rd1 <= issue;
    if (issue) f1024 <= wa1[10];
    if (rd1) begin
      xa  <= q_a;
      xb  <= q_b;
      xtw <= tw_q;
      xw0 <= wq0;
      xw1 <= f1024 ? 17'h1ffff : wq1;
    end
  end

  reg [8:0] vr = 9'd0;
  assign vv = vr;
  // per step 1..6 (step 1 lowest): {window, W^0, twiddle from the second quadrant}
  reg [17:0] flv = 18'd0;
  always @(posedge clk)
    if (rst) vr <= 9'd0;
    else if (ce) vr <= {vr[7:0], issue};
  always @(posedge clk)
    if (ce) begin
      flv <= {flv[14:0], pwin, byp, twk[10]};
      fav <= {fav[95:0], op_a};
      fbv <= {fbv[95:0], op_b};
    end

  wire signed [21:0] xa_re = xa[43:22], xa_im = xa[21:0];
  wire signed [21:0] xb_re = xb[43:22], xb_im = xb[21:0];
  wire signed [17:0] t_re = xtw[35:18], t_im = xtw[17:0];
  wire               w2 = flv[5], b2 = flv[4], q2 = flv[3];
  wire               w3 = flv[8];
  wire               w5 = flv[14];
  wire               sr5 = !flv[14] && !flv[13] && !flv[12];  // tr = P1 - P2
  wire               si5 = !flv[14] && !flv[13] && flv[12];   // ti = P4 - P3
  wire               w6 = flv[17];

  // The four multipliers (A, B, M, P registers; P = M + rounding):
  //   butterfly   P1 = br wr', P2 = bi wi', P3 = br wi', P4 = bi wr'
  //               (wr', wi' = the table's re, im, swapped in the second
  //               quadrant), tr = P1 -+ P2, ti = P4 +- P3; W^0: br, br, bi,
  //               bi times 2^16, tr = P1 + P2, ti = P4 + P3 (= b exactly)
  //   window      P1 = re0 w0, P2 = re1 w1, P3 = im1 w1, P4 = im0 w0
  reg signed [21:0] ma1 = 22'sd0, ma2 = 22'sd0, ma3 = 22'sd0, ma4 = 22'sd0;
  reg signed [17:0] mbx = 18'sd0, mby = 18'sd0;
  reg signed [39:0] mm1 = 40'sd0, mm2 = 40'sd0, mm3 = 40'sd0, mm4 = 40'sd0;
  reg               c23 = 1'b0;
  reg signed [40:0] pp1 = 41'sd0, pp2 = 41'sd0, pp3 = 41'sd0, pp4 = 41'sd0;
  reg signed [21:0] ar3 = 22'sd0, ai3 = 22'sd0, ar4 = 22'sd0, ai4 = 22'sd0;
  reg signed [21:0] ar5 = 22'sd0, ai5 = 22'sd0, ar6 = 22'sd0, ai6 = 22'sd0;
  reg signed [41:0] dr = 42'sd0, di = 42'sd0;
  reg signed [40:0] e2 = 41'sd0, e3 = 41'sd0;
  reg signed [25:0] u_ar = 26'sd0, u_ai = 26'sd0, u_br = 26'sd0, u_bi = 26'sd0;
  reg [21:0]        w_ar = 22'd0, w_ai = 22'd0, w_br = 22'd0, w_bi = 22'd0;

  wire signed [41:0] o2 = w5 ? 42'sd0 : pp2;
  wire signed [41:0] o3 = w5 ? 42'sd0 : pp3;
  wire signed [24:0] tr6 = dr[41:17], ti6 = di[41:17];
  wire signed [23:0] e2s = e2[40:17], e3s = e3[40:17];

  always @(posedge clk)
    if (ce && fm) begin
      // step 2: the multipliers' inputs
      ma1 <= w2 ? xa_re : xb_re;
      ma2 <= (w2 || b2) ? xb_re : xb_im;
      ma3 <= (w2 || b2) ? xb_im : xb_re;
      ma4 <= w2 ? xa_im : xb_im;
      mbx <= w2 ? $signed({1'b0, xw0}) : b2 ? 18'sd65536 : q2 ? t_im : t_re;
      mby <= w2 ? $signed({1'b0, xw1}) : b2 ? 18'sd65536 : q2 ? t_re : t_im;
      ar3 <= xa_re;
      ai3 <= xa_im;
      // 3: products
      mm1 <= ma1 * mbx;
      mm2 <= ma2 * mby;
      mm3 <= ma3 * mby;
      mm4 <= ma4 * mbx;
      c23 <= w3;
      ar4 <= ar3;
      ai4 <= ai3;
      // 4: rounding (P2, P3: the window's only)
      pp1 <= mm1 + 41'sd65536;
      pp2 <= mm2 + (c23 ? 41'sd65536 : 41'sd0);
      pp3 <= mm3 + (c23 ? 41'sd65536 : 41'sd0);
      pp4 <= mm4 + 41'sd65536;
      ar5 <= ar4;
      ai5 <= ai4;
      // 5: t = b W (or the window's first sample) and the second, aside
      dr  <= sr5 ? pp1 - o2 : pp1 + o2;
      di  <= si5 ? pp4 - o3 : pp4 + o3;
      e2  <= pp2;
      e3  <= pp3;
      ar6 <= ar5;
      ai6 <= ai5;
      // 6: a + t, a - t (the window: the two samples)
      u_ar <= (w6 ? 26'sd0 : ar6) + tr6;
      u_ai <= (w6 ? 26'sd0 : ai6) + ti6;
      u_br <= (w6 ? e2s : ar6) - (w6 ? 25'sd0 : tr6);
      u_bi <= (w6 ? e3s : ai6) - (w6 ? 25'sd0 : ti6);
      // 7: the pass's scaling
      w_ar <= scl(u_ar, sh);
      w_ai <= scl(u_ai, sh);
      w_br <= scl(u_br, sh);
      w_bi <= scl(u_bi, sh);
      // 8: the words to write (step 9) and their sizes
      wd_a <= {w_ar, w_ai};
      wd_b <= {w_br, w_bi};
      g13  <= {sz5(w_ar) >= 5'd13, sz5(w_ai) >= 5'd13, sz5(w_br) >= 5'd13, sz5(w_bi) >= 5'd13};
      g26  <= {sz5(w_ar) >= 5'd26, sz5(w_ai) >= 5'd26, sz5(w_br) >= 5'd26, sz5(w_bi) >= 5'd26};
    end

  // ---------------------------------------------------------------- output datapath
  // read (2), plain register (3), squares (4-6), sum (7), float (8-11), out
  reg  [169:0] obv = 170'd0;             // stages 2..11, 2 lowest
  wire [16:0]  ob10 = obv[152:136], ob11 = obv[169:153];
  reg [43:0] xo = 44'd0;
  reg signed [21:0] o_ar = 22'sd0, o_ai = 22'sd0;
  reg signed [43:0] o_mr = 44'sd0, o_mi = 44'sd0, o_pr = 44'sd0, o_pi = 44'sd0;
  reg [43:0] o_pw = 44'd0;
  reg [47:0] x8 = 48'd0, x9 = 48'd0, x10 = 48'd0;
  reg [4:0]  z8a = 5'd0, z8b = 5'd0, z8c = 5'd0;
  reg [5:0]  lz9 = 6'd0, lz10 = 6'd0;
  reg        nz9 = 1'b0, nz10 = 1'b0;
  reg [31:0] f11 = 32'd0, even = 32'd0;
  wire [47:0] xs10 = x10 << lz10[2:0];   // the leading one at bit 47
  wire [8:0]  ex10 = ob10[8:0] - {3'd0, lz10};
  wire        orun = ps == P_ORUN || ps == P_ODRAIN;   // a chunk's points in the pipeline

  always @(posedge clk) begin
    if (rst) obv <= 170'd0;
    else     obv <= {obv[152:0], g};
  end
  always @(posedge clk)
    if (orun) begin
      xo   <= pctx ? q_b : q_a;
      o_ar <= xo[43:22];
      o_ai <= xo[21:0];
      o_mr <= o_ar * o_ar;
      o_mi <= o_ai * o_ai;
      o_pr <= o_mr;
      o_pi <= o_mi;
      o_pw <= o_pr[43:0] + o_pi[43:0];
      x8   <= {4'd0, o_pw};
      z8a  <= lz16({4'd0, o_pw[43:32]});
      z8b  <= lz16(o_pw[31:16]);
      z8c  <= lz16(o_pw[15:0]);
      x9   <= x8;
      nz9  <= x8 != 48'd0;
      lz9  <= z8a != 5'd16 ? {1'b0, z8a} : z8b != 5'd16 ? 6'd16 + {1'b0, z8b} : 6'd32 + {1'b0, z8c};
      x10  <= x9 << {lz9[5:3], 3'b000};
      lz10 <= lz9;
      nz10 <= nz9;
      f11  <= nz10 ? {1'b0, ex10[7:0], xs10[46:24]} : 32'd0;
  end

  always @(posedge clk) begin
    s_valid <= 1'b0;
    s_first <= 1'b0;
    o_end   <= 1'b0;
    if (ob11[16]) begin
      if (ob11[15]) begin
        s_data  <= {16'h5042, 4'd3, ob11[12:9], 2'd0, ptag, psat, 11'd0, pnch, pfr0};
        s_valid <= 1'b1;
        s_first <= 1'b1;
      end else if (!ob11[14])
        even <= f11;
      else begin
        s_data  <= {f11, even};
        s_valid <= 1'b1;
        o_end   <= ob11[13];
      end
    end
  end

endmodule

// A capture context: its job, its frames, the rounding and saturation, the
// writes for its port (we, addr, d; hit3 = we the clock after). States:
// idle, capturing (from `go`), waiting for the processor (its samples all
// written), busy (taken, or the other half of a double job: `hold`) until
// `done_rel`.
module pfb_zoom_ctx #(
  parameter [11:0] BASE = 12'd0
) (
  input  wire               clk,
  input  wire               clr,
  input  wire signed [24:0] re1,
  input  wire signed [24:0] im1,
  input  wire [10:0]        k1,
  input  wire               v1,
  input  wire               zl1,
  input  wire               zh1,
  input  wire [15:0]        fr1,
  input  wire               go,
  input  wire               hold,
  input  wire [31:0]        job,
  input  wire               dbl,
  input  wire [11:0]        kend,
  input  wire [11:0]        n,
  input  wire [11:0]        nm2,
  input  wire [10:0]        irev,          // 1 << (11 - logn)
  input  wire [6:0]         rnd,           // 2^(shift - 1)
  input  wire               take,
  input  wire               done_rel,
  output reg  [1:0]         state = 2'd0,
  output reg  [31:0]        jw = 32'd0,
  output reg                jdbl = 1'b0,
  output reg  [15:0]        frame0 = 16'd0,
  output reg                sat = 1'b0,
  output reg                hit3 = 1'b0,
  output reg                we = 1'b0,
  output reg  [11:0]        addr = 12'd0,
  output reg  [43:0]        d = 44'd0
);

  localparam [1:0] IDLE = 2'd0, CAP = 2'd1, WAIT = 2'd2, BUSY = 2'd3;

  function [10:0] rev11(input [10:0] v);
    rev11 = {v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10]};
  endfunction

  // the 26-bit rounded sum, shifted right by s: does it fit 22 bits?
  function ovf(input [25:0] s, input [2:0] sh);
    case (sh)
      3'd0:    ovf = !(&s[25:21] || !(|s[25:21]));
      3'd1:    ovf = !(&s[25:22] || !(|s[25:22]));
      3'd2:    ovf = !(&s[25:23] || !(|s[25:23]));
      3'd3:    ovf = s[25] != s[24];
      default: ovf = 1'b0;
    endcase
  endfunction

  function [21:0] sat22(input [21:0] v, input o, input neg);
    sat22 = !o ? v : neg ? 22'h200000 : 22'h1fffff;
  endfunction

  reg [10:0]        k0r = 11'd0, irr = 11'd0;
  reg [11:0]        ke = 12'd0, nr = 12'd0;
  reg signed [12:0] nm2r = 13'sd0;
  reg [6:0]         rr = 7'd0;
  reg [2:0]         shr = 3'd0;
  reg [1:0]         arm = 2'd0;            // the job's settings reached stage 2
  reg               started = 1'b0, cap_on = 1'b0;
  reg signed [12:0] tcnt = 13'sd0;         // frames after this one - 1
  reg [10:0]        rt = 11'd0, rt_inc = 11'd0;   // bitrev(t), bitrev(t + 1)
  reg [11:0]        cstart = 12'd0, cptr = 12'd0, a3 = 12'd0;
  reg [2:0]         dn = 3'd0;

  // stage 2: the range, the rounding
  reg               ge2 = 1'b0, lt2 = 1'b0, v2 = 1'b0, st2 = 1'b0;
  reg [15:0]        fr2 = 16'd0;
  reg signed [25:0] sr2 = 26'sd0, si2 = 26'sd0;
  always @(posedge clk) begin
    ge2 <= k1 >= k0r;
    lt2 <= {1'b0, k1} < ke;
    v2  <= v1;
    st2 <= v1 && zl1 && zh1;
    fr2 <= fr1;
    sr2 <= re1 + $signed({19'd0, rr});
    si2 <= im1 + $signed({19'd0, rr});
  end

  // stage 3: the frame, the write's address; the shift
  wire        capt   = state == CAP && arm[1];
  wire        fs     = capt && st2;
  wire        lastf  = tcnt[12];
  wire        on_now = fs ? (!started || !lastf) : cap_on;
  wire        hit    = capt && on_now && v2 && ge2 && lt2;
  wire        done_ev = capt && cap_on && lastf && ((v2 && !lt2) || st2);
  wire [11:0] cur    = fs ? cstart : cptr;
  wire signed [25:0] shr_r = sr2 >>> shr;
  wire signed [25:0] shi_r = si2 >>> shr;
  reg  [21:0] xr3 = 22'd0, xi3 = 22'd0;
  reg         or3 = 1'b0, oi3 = 1'b0, nr3 = 1'b0, ni3 = 1'b0;
  always @(posedge clk) begin
    xr3 <= shr_r[21:0];
    xi3 <= shi_r[21:0];
    or3 <= ovf(sr2, shr);
    oi3 <= ovf(si2, shr);
    nr3 <= sr2[25];
    ni3 <= si2[25];
    // stage 4: the write
    we   <= hit3;
    addr <= a3;
    d    <= {sat22(xr3, or3, nr3), sat22(xi3, oi3, ni3)};
  end

  always @(posedge clk) begin
    rt_inc <= rev11(rev11(rt) + irr);
    cstart <= BASE | (started ? {1'b0, rt_inc} : 12'd0);
    hit3   <= hit;
    a3     <= cur;
    cptr   <= hit ? cur + nr : cur;
    if (hit3 && (or3 || oi3)) sat <= 1'b1;
    dn     <= {dn[1:0], done_ev};
    arm    <= {arm[0], 1'b1};
    if (fs) begin
      if (!started) begin
        started <= 1'b1;
        frame0  <= fr2;
        tcnt    <= nm2r;
        rt      <= 11'd0;
        cap_on  <= 1'b1;
      end else if (!lastf) begin
        tcnt <= tcnt - 13'sd1;
        rt   <= rt_inc;
      end
    end
    if (done_ev) cap_on <= 1'b0;
    if (clr) begin
      state   <= IDLE;
      started <= 1'b0;
      cap_on  <= 1'b0;
      dn      <= 3'd0;
    end else begin
      if (dn[2] && state == CAP) state <= WAIT;
      if (take && state == WAIT) state <= BUSY;
      if (done_rel && state == BUSY) state <= IDLE;
      if (hold && state == IDLE) state <= BUSY;
      if (go && state == IDLE) begin
        state   <= CAP;
        jw      <= job;
        jdbl    <= dbl;
        k0r     <= job[10:0];
        shr     <= job[25:23];
        ke      <= kend;
        nr      <= n;
        nm2r    <= {1'b0, nm2};
        irr     <= irev;
        rr      <= rnd;
        started <= 1'b0;
        cap_on  <= 1'b0;
        sat     <= 1'b0;
        arm     <= 2'd0;
        rt      <= 11'd0;
        cstart  <= BASE;
      end
    end
  end

endmodule

`default_nettype wire
