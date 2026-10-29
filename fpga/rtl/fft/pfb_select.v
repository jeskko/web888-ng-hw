// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The channelizer's bin selector (hw/docs/channelizer.md §3.7): of each
// frame's bins (one per enabled clock, k = 0..N-1 in order, as pfb_chain
// gives them), the ones set in a 2048-bit mask go to the DMA, after a
// header word:
//   header  {16'h5042, 4'd1, gen[3:0], 8'd0, frame[31:0]}
//   bin     {Q[31:0], I[31:0]}   (re, im << SH: a full-scale sine is 2^29)
// `s_first` marks the header (axi_ring_writer VARLEN). At most NSEL bins
// per frame, the lowest NSEL set in the mask; with more set, `truncated`
// (sticky) says so. `enable` counts from a frame's start, so every frame
// out is whole. Bin N - 1 can't be selected: the
// bins go out one clock after they come, and its slot is the next frame's
// header (it is the band edge below Nyquist).
//
// The mask is two banks of LUT RAM, 64 words of 32 bits (bit b of word w
// is bin 32w + b). Writes (`mask_we`, `mask_addr`, `mask_data`) go to the
// bank not in use; when `gen_req` differs from the generation in use, the
// next frame switches banks and takes it as its `gen`. Software writes a
// whole mask, then a new `gen_req`, and waits for headers with that gen
// before writing the next.

module pfb_select #(
  parameter integer W    = 25,
  parameter integer LOGN = 11,
  parameter integer NSEL = 64,
  parameter integer SH   = 5
) (
  input  wire                clk,
  input  wire                ce,
  input  wire                enable,
  input  wire signed [W-1:0] in_re,
  input  wire signed [W-1:0] in_im,
  input  wire [LOGN-1:0]     in_k,
  input  wire                in_valid,

  input  wire                mask_we,
  input  wire [LOGN-6:0]     mask_addr,
  input  wire [31:0]         mask_data,
  input  wire [3:0]          gen_req,
  output reg  [3:0]          gen = 4'd0,
  output reg                 truncated = 1'b0,

  output reg  [63:0]         s_data = 64'd0,
  output reg                 s_valid = 1'b0,
  output reg                 s_first = 1'b0
);

  localparam integer MW = 1 << (LOGN - 5);    // mask words
  localparam [LOGN-1:0] LAST = {LOGN{1'b1}};

  // ---- the mask: two banks, `bank` in use
  reg [31:0] m0 [0:MW-1];
  reg [31:0] m1 [0:MW-1];
  reg        bank = 1'b0;
  integer i;
  initial for (i = 0; i < MW; i = i + 1) begin m0[i] = 32'd0; m1[i] = 32'd0; end
  always @(posedge clk)
    if (mask_we) begin
      if (bank) m0[mask_addr] <= mask_data;
      else      m1[mask_addr] <= mask_data;
    end

  // ---- the bin and its mask bit in both banks, a clock later (the mask
  // read, the bank's pick and the count in one clock failed timing)
  reg signed [W-1:0] r_re = 0, r_im = 0;
  reg [LOGN-1:0]     r_k = 0;
  reg                r_valid = 1'b0, r_m0 = 1'b0, r_m1 = 1'b0;
  always @(posedge clk)
    if (ce) begin
      r_re    <= in_re;
      r_im    <= in_im;
      r_k     <= in_k;
      r_valid <= in_valid;
      r_m0    <= m0[in_k[LOGN-1:5]][in_k[4:0]];
      r_m1    <= m1[in_k[LOGN-1:5]][in_k[4:0]];
    end

  // ---- per frame: switch banks at its start, count its bins
  wire        start = ce && r_valid && (r_k == 0);
  wire        swap  = start && (gen_req != gen);
  wire        bnk   = swap ? ~bank : bank;   // the bank for this bin
  wire        mbit  = bnk ? r_m1 : r_m0;
  reg  [31:0] frame = 32'd0;
  reg  [$clog2(NSEL+1)-1:0] nsel = 0;
  reg         en_f = 1'b0;                   // enabled at this frame's start
  wire        en_now = start ? enable : en_f;
  wire [$clog2(NSEL+1)-1:0] n_now = start ? 0 : nsel;
  wire        want  = en_now && r_valid && mbit && (r_k != LAST);
  wire        take  = want && (n_now < NSEL);

  // the bin, one clock later (the header takes the frame's first slot)
  reg         b_take = 1'b0;
  reg  [63:0] b_word = 64'd0;
  wire signed [31:0] i32 = {{(32-W-SH){r_re[W-1]}}, r_re, {SH{1'b0}}};
  wire signed [31:0] q32 = {{(32-W-SH){r_im[W-1]}}, r_im, {SH{1'b0}}};

  always @(posedge clk)
    if (ce) begin
      if (swap) begin
        bank <= ~bank;
        gen  <= gen_req;
      end
      if (start) en_f <= enable;
      if (want && !take) truncated <= 1'b1;
      nsel   <= n_now + take;
      b_take <= take;
      b_word <= {q32, i32};
      if (start && enable) begin
        // the previous frame's last bin can't be in this slot (bin N - 1)
        s_data  <= {16'h5042, 4'd1, swap ? gen_req : gen, 8'd0, frame};
        s_valid <= 1'b1;
        s_first <= 1'b1;
      end else begin
        s_data  <= b_word;
        s_valid <= b_take;
        s_first <= 1'b0;
      end
      if (start) frame <= frame + 1'b1;
    end

endmodule

`default_nettype wire
