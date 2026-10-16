// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// Stream -> DDR ring buffer writer (AXI3 master, 64-bit, 16-beat bursts).
//
// Contract (matches the zynqsdr driver):
//   * ring = (len_m1 + 1) bursts of 128 bytes at base_addr
//   * `ptr` = number of completed bursts (B received), modulo ring size;
//     software reads [read_pos, ptr*128)
//   * a rising edge of `enable` restarts at offset 0 with freshly latched
//     base/len/oneshot, after any outstanding bursts have drained
//   * oneshot != 0: stop after that many bursts (waterfall one-shot block)
//
// Up to MAX_OUT bursts may be outstanding (address issued, response not yet
// received); data for a burst is in the FIFO before its address is issued.
// Input is admitted in frames of FRAME words: a frame is accepted only if
// the FIFO has room for all of it at its first word, otherwise the whole
// frame is dropped and `overflow` is set (sticky until the next start). The
// ring therefore never loses frame alignment (the stock format has no sync
// markers, so a single dropped word would shift every later frame).
// The producer must deliver whole frames, starting after `running` rises.
//
// Diagnostics (cleared on the next start): `frames` accepted, `drops`
// dropped frames, `bursts` completed bursts (not wrapped), `bresp_err`
// (sticky: any non-OKAY write response).

module axi_ring_writer #(
  parameter integer FIFO_AW = 10,
  parameter integer FRAME   = 1,     // words per frame (<= 2^FIFO_AW)
  parameter integer MAX_OUT = 8,
  parameter integer ID_W    = 6
) (
  input  wire            clk,
  input  wire            rst,

  input  wire            enable,
  input  wire [31:0]     base_addr,
  input  wire [15:0]     len_m1,
  input  wire [15:0]     oneshot,

  output reg             running,     // producer may push
  output reg  [15:0]     ptr,
  output reg             burst_done,  // one-clock pulse per completed burst
  output reg             overflow,
  output reg  [31:0]     frames,
  output reg  [31:0]     drops,
  output reg  [31:0]     bursts,
  output reg             bresp_err,

  input  wire [63:0]     s_data,
  input  wire            s_valid,

  // AXI3 write channels
  output wire [ID_W-1:0] m_axi_awid,
  output reg  [31:0]     m_axi_awaddr,
  output wire [3:0]      m_axi_awlen,
  output wire [2:0]      m_axi_awsize,
  output wire [1:0]      m_axi_awburst,
  output wire [1:0]      m_axi_awlock,
  output wire [3:0]      m_axi_awcache,
  output wire [2:0]      m_axi_awprot,
  output wire [3:0]      m_axi_awqos,
  output reg             m_axi_awvalid,
  input  wire            m_axi_awready,
  output wire [ID_W-1:0] m_axi_wid,
  output wire [63:0]     m_axi_wdata,
  output wire [7:0]      m_axi_wstrb,
  output wire            m_axi_wlast,
  output wire            m_axi_wvalid,
  input  wire            m_axi_wready,
  input  wire [ID_W-1:0] m_axi_bid,
  input  wire [1:0]      m_axi_bresp,
  input  wire            m_axi_bvalid,
  output wire            m_axi_bready,
  // AXI3 read channels (unused)
  output wire [ID_W-1:0] m_axi_arid,
  output wire [31:0]     m_axi_araddr,
  output wire [3:0]      m_axi_arlen,
  output wire [2:0]      m_axi_arsize,
  output wire [1:0]      m_axi_arburst,
  output wire [1:0]      m_axi_arlock,
  output wire [3:0]      m_axi_arcache,
  output wire [2:0]      m_axi_arprot,
  output wire [3:0]      m_axi_arqos,
  output wire            m_axi_arvalid,
  input  wire            m_axi_arready,
  input  wire [ID_W-1:0] m_axi_rid,
  input  wire [63:0]     m_axi_rdata,
  input  wire [1:0]      m_axi_rresp,
  input  wire            m_axi_rlast,
  input  wire            m_axi_rvalid,
  output wire            m_axi_rready
);

  assign m_axi_awid    = {ID_W{1'b0}};
  assign m_axi_awlen   = 4'd15;
  assign m_axi_awsize  = 3'd3;       // 8 bytes
  assign m_axi_awburst = 2'b01;      // INCR
  assign m_axi_awlock  = 2'b00;
  assign m_axi_awcache = 4'b0011;    // normal, non-cacheable, bufferable
  assign m_axi_awprot  = 3'b000;
  assign m_axi_awqos   = 4'd0;
  assign m_axi_wid     = {ID_W{1'b0}};
  assign m_axi_wstrb   = 8'hff;
  assign m_axi_bready  = 1'b1;

  assign m_axi_arid    = {ID_W{1'b0}};
  assign m_axi_araddr  = 32'd0;
  assign m_axi_arlen   = 4'd0;
  assign m_axi_arsize  = 3'd3;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arlock  = 2'b00;
  assign m_axi_arcache = 4'b0011;
  assign m_axi_arprot  = 3'b000;
  assign m_axi_arqos   = 4'd0;
  assign m_axi_arvalid = 1'b0;
  assign m_axi_rready  = 1'b1;

  // ---- state
  reg [31:0] base_r;
  reg [15:0] len_r, oneshot_r;
  reg [15:0] aw_idx;          // ring index of next burst to issue
  reg [15:0] aw_total;        // bursts issued since start
  reg [7:0]  w_owed;          // bursts issued whose data is not yet sent
  reg [7:0]  b_owed;          // bursts issued whose response is not yet seen
  reg [3:0]  beat;
  reg        enable_d, start_req;

  wire idle = (w_owed == 0) && (b_owed == 0) && !m_axi_awvalid;
  wire aw_fire = m_axi_awvalid && m_axi_awready;

  // ---- FIFO
  reg               fifo_rst;
  wire              fifo_full;
  wire [63:0]       fifo_rdata;
  wire              fifo_rvalid;
  wire [FIFO_AW:0]  fifo_count;
  wire              w_fire = m_axi_wvalid && m_axi_wready;

  // ---- frame admission
  localparam integer FW = (FRAME > 1) ? $clog2(FRAME) : 1;
  reg  [FW-1:0] fword;          // word index within the current frame
  reg           fkeep;          // current frame accepted
  wire          in_word  = s_valid && running;
  wire          fstart   = (fword == 0);
  // Registered for timing: a one-cycle-old count is short by at most the one
  // word written last cycle, hence the +1 (pops only add room).
  reg           room;
  always @(posedge clk)
    room <= ({1'b0, fifo_count} + FRAME + 1) <= (1 << FIFO_AW);
  wire          admit    = fstart ? room : fkeep;
  wire          flast    = (fword == FRAME - 1);

  sync_fifo #(.W(64), .AW(FIFO_AW)) fifo (
    .clk(clk), .rst(rst || fifo_rst),
    .wdata(s_data), .wvalid(in_word && admit), .full(fifo_full),
    .rdata(fifo_rdata), .rvalid(fifo_rvalid), .rready(w_fire),
    .count(fifo_count));

  // While draining after disable the FIFO may run dry; send filler beats.
  assign m_axi_wvalid = (w_owed != 0) && (fifo_rvalid || !running);
  assign m_axi_wdata  = fifo_rvalid ? fifo_rdata : 64'd0;
  assign m_axi_wlast  = (beat == 4'd15);

  // W beats are only sent for accepted addresses; an address is issued once
  // the FIFO holds data for it on top of the bursts already owed.
  //
  // The data check is registered for timing. A one-cycle-old result is
  // conservative (pops during a burst only shrink the estimate) except right
  // after w_owed grows or the FIFO is flushed, so `settle` blocks those cycles.
  wire [FIFO_AW+4:0] need = ({w_owed, 4'd0} + 16);
  reg  have_data, settle;
  wire oneshot_done = (oneshot_r != 0) && (aw_total >= oneshot_r);
  wire can_issue = running && !start_req && !m_axi_awvalid && !settle &&
                   (b_owed < MAX_OUT) && have_data && !oneshot_done;

  wire w_last_fire = w_fire && m_axi_wlast;

  always @(posedge clk) begin
    have_data <= (fifo_count >= need);
    settle    <= aw_fire || (start_req && idle) || rst;
  end

  always @(posedge clk) begin
    fifo_rst   <= 1'b0;
    burst_done <= 1'b0;
    if (rst) begin
      running       <= 1'b0;
      enable_d      <= 1'b0;
      start_req     <= 1'b0;
      m_axi_awvalid <= 1'b0;
      w_owed        <= 0;
      b_owed        <= 0;
      beat          <= 0;
      ptr           <= 0;
      overflow      <= 1'b0;
      fifo_rst      <= 1'b1;
      fword         <= 0;
      fkeep         <= 1'b0;
      frames        <= 0;
      drops         <= 0;
      bursts        <= 0;
      bresp_err     <= 1'b0;
    end else begin
      enable_d <= enable;
      if (enable && !enable_d) start_req <= 1'b1;
      if (!enable) begin
        running   <= 1'b0;
        start_req <= 1'b0;
      end

      if (start_req && idle) begin
        start_req <= 1'b0;
        running   <= 1'b1;
        base_r    <= base_addr;
        len_r     <= len_m1;
        oneshot_r <= oneshot;
        aw_idx    <= 0;
        aw_total  <= 0;
        ptr       <= 0;
        overflow  <= 1'b0;
        fifo_rst  <= 1'b1;
        fword     <= 0;
        frames    <= 0;
        drops     <= 0;
        bursts    <= 0;
        bresp_err <= 1'b0;
      end

      if (in_word) begin
        if (fstart) fkeep <= room;
        fword <= flast ? {FW{1'b0}} : fword + 1'b1;
        if (flast) begin
          if (admit) frames <= frames + 1'b1;
          else       drops  <= drops + 1'b1;
        end
        if (!admit && !oneshot_done) overflow <= 1'b1;
      end

      // address channel
      if (can_issue) begin
        m_axi_awaddr  <= base_r + {aw_idx, 7'd0};
        m_axi_awvalid <= 1'b1;
        aw_idx        <= (aw_idx == len_r) ? 16'd0 : aw_idx + 1'b1;
        aw_total      <= aw_total + 1'b1;
      end else if (aw_fire) begin
        m_axi_awvalid <= 1'b0;
      end

      // owed counters: +1 when the address is accepted, -1 on completion
      w_owed <= w_owed + aw_fire - w_last_fire;
      b_owed <= b_owed + aw_fire - m_axi_bvalid;

      if (w_fire) beat <= beat + 1'b1;

      // response channel
      if (m_axi_bvalid) begin
        burst_done <= 1'b1;
        bursts     <= bursts + 1'b1;
        if (m_axi_bresp != 2'b00) bresp_err <= 1'b1;
        if (running || start_req)
          ptr <= (ptr == len_r) ? 16'd0 : ptr + 1'b1;
      end
    end
  end

endmodule

`default_nettype wire
