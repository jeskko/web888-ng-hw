// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// AXI3 slave (from PS M_AXI_GP0) exposing the zynqsdr register windows:
//   base + 0x0000000  CFG  read/write, byte strobes honoured (the driver uses
//                          strb/strh and kernel-emulated unaligned stores)
//   base + 0x1000000  STS  read only
//   base + 0x2000000  PPS  read pops one word from the PPS FIFO
//   base + 0x3000000  EV   write only: each word written comes out as a
//                          one-clock event (ev_idx, ev_data); reads 0
//                          (the channelizer's bin mask, web888_core PFB)
// Region is selected by addr[25:24]; word index by addr[WIDX+1:2].
// INCR and FIXED bursts are supported; one transaction per direction at a time.

module axi_regs #(
  parameter integer CFG_WORDS = 40,
  parameter integer STS_WORDS = 16,
  parameter integer ID_W      = 12
) (
  input  wire                   clk,
  input  wire                   rst,

  output wire [CFG_WORDS*32-1:0] cfg,
  input  wire [STS_WORDS*32-1:0] sts,

  input  wire [31:0]            pps_data,
  input  wire                   pps_valid,
  output reg                    pps_pop,

  output wire                   ev_valid,
  output wire [9:0]             ev_idx,
  output wire [31:0]            ev_data,

  input  wire [ID_W-1:0]        s_axi_awid,
  input  wire [31:0]            s_axi_awaddr,
  input  wire [3:0]             s_axi_awlen,
  input  wire [2:0]             s_axi_awsize,
  input  wire [1:0]             s_axi_awburst,
  input  wire [1:0]             s_axi_awlock,
  input  wire [3:0]             s_axi_awcache,
  input  wire [2:0]             s_axi_awprot,
  input  wire [3:0]             s_axi_awqos,
  input  wire                   s_axi_awvalid,
  output reg                    s_axi_awready,
  input  wire [ID_W-1:0]        s_axi_wid,
  input  wire [31:0]            s_axi_wdata,
  input  wire [3:0]             s_axi_wstrb,
  input  wire                   s_axi_wlast,
  input  wire                   s_axi_wvalid,
  output reg                    s_axi_wready,
  output reg  [ID_W-1:0]        s_axi_bid,
  output wire [1:0]             s_axi_bresp,
  output reg                    s_axi_bvalid,
  input  wire                   s_axi_bready,
  input  wire [ID_W-1:0]        s_axi_arid,
  input  wire [31:0]            s_axi_araddr,
  input  wire [3:0]             s_axi_arlen,
  input  wire [2:0]             s_axi_arsize,
  input  wire [1:0]             s_axi_arburst,
  input  wire [1:0]             s_axi_arlock,
  input  wire [3:0]             s_axi_arcache,
  input  wire [2:0]             s_axi_arprot,
  input  wire [3:0]             s_axi_arqos,
  input  wire                   s_axi_arvalid,
  output reg                    s_axi_arready,
  output reg  [ID_W-1:0]        s_axi_rid,
  output reg  [31:0]            s_axi_rdata,
  output wire [1:0]             s_axi_rresp,
  output reg                    s_axi_rlast,
  output reg                    s_axi_rvalid,
  input  wire                   s_axi_rready
);

  assign s_axi_bresp = 2'b00;
  assign s_axi_rresp = 2'b00;

  reg [31:0] cfg_r [0:CFG_WORDS-1];
  genvar g;
  generate
    for (g = 0; g < CFG_WORDS; g = g + 1) begin : cfg_out
      assign cfg[g*32 +: 32] = cfg_r[g];
    end
  endgenerate

  // ---------------- write path
  reg        w_busy;
  reg [1:0]  w_region;
  reg [9:0]  w_idx;
  reg        w_incr;
  integer    i, bt;

  // Accepted W beats are registered before they reach cfg_r: the PS7 GP0
  // pins are far from the fabric, and a direct wdata -> cfg_r path limits
  // timing. B is sent after the last beat is applied, so a read issued after
  // the write response always sees the new value.
  // wp_data/strb are broadcast to all cfg words across the die: replicate.
  reg        wp_valid, wp_en, wp_ev, wp_last;
  reg [9:0]  wp_idx;
  (* max_fanout = 8 *) reg [31:0] wp_data;
  (* max_fanout = 8 *) reg [3:0]  wp_strb;

  always @(posedge clk) begin
    if (rst) begin
      s_axi_awready <= 1'b1;
      s_axi_wready  <= 1'b0;
      s_axi_bvalid  <= 1'b0;
      w_busy        <= 1'b0;
      wp_valid      <= 1'b0;
      for (i = 0; i < CFG_WORDS; i = i + 1) cfg_r[i] <= 32'd0;
    end else begin
      wp_valid <= 1'b0;
      if (wp_valid) begin
        if (wp_en)
          for (bt = 0; bt < 4; bt = bt + 1)
            if (wp_strb[bt]) cfg_r[wp_idx][bt*8 +: 8] <= wp_data[bt*8 +: 8];
        if (wp_last) s_axi_bvalid <= 1'b1;
      end

      if (!w_busy && s_axi_awvalid && s_axi_awready) begin
        w_busy        <= 1'b1;
        s_axi_awready <= 1'b0;
        s_axi_wready  <= 1'b1;
        s_axi_bid     <= s_axi_awid;
        w_region      <= s_axi_awaddr[25:24];
        w_idx         <= s_axi_awaddr[11:2];
        w_incr        <= (s_axi_awburst != 2'b00);
      end

      if (w_busy && s_axi_wvalid && s_axi_wready) begin
        wp_valid <= 1'b1;
        wp_en    <= (w_region == 2'd0 && w_idx < CFG_WORDS);
        wp_ev    <= (w_region == 2'd3);
        wp_idx   <= w_idx;
        wp_data  <= s_axi_wdata;
        wp_strb  <= s_axi_wstrb;
        wp_last  <= s_axi_wlast;
        if (w_incr) w_idx <= w_idx + 1'b1;
        if (s_axi_wlast) s_axi_wready <= 1'b0;
      end

      if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid  <= 1'b0;
        s_axi_awready <= 1'b1;
        w_busy        <= 1'b0;
      end
    end
  end

  assign ev_valid = wp_valid && wp_ev;
  assign ev_idx   = wp_idx;
  assign ev_data  = wp_data;

  // ---------------- read path
  reg        r_busy;
  reg [1:0]  r_region;
  reg [9:0]  r_idx;
  reg        r_incr;
  reg [3:0]  r_left;

  reg [31:0] rd_word;
  always @(*) begin
    rd_word = 32'd0;
    case (r_region)
      2'd0: if (r_idx < CFG_WORDS) rd_word = cfg_r[r_idx];
      2'd1: if (r_idx < STS_WORDS) rd_word = sts[r_idx*32 +: 32];
      2'd2: rd_word = pps_valid ? pps_data : 32'd0;
      default: rd_word = 32'd0;
    endcase
  end

  // r_load: a beat is pending to be placed on R
  reg r_load;

  always @(posedge clk) begin
    pps_pop <= 1'b0;
    if (rst) begin
      s_axi_arready <= 1'b1;
      s_axi_rvalid  <= 1'b0;
      r_busy        <= 1'b0;
      r_load        <= 1'b0;
    end else begin
      if (!r_busy && s_axi_arvalid && s_axi_arready) begin
        r_busy        <= 1'b1;
        s_axi_arready <= 1'b0;
        s_axi_rid     <= s_axi_arid;
        r_region      <= s_axi_araddr[25:24];
        r_idx         <= s_axi_araddr[11:2];
        r_incr        <= (s_axi_arburst != 2'b00);
        r_left        <= s_axi_arlen;
        r_load        <= 1'b1;
      end

      if (r_load && (!s_axi_rvalid || s_axi_rready)) begin
        s_axi_rdata  <= rd_word;
        s_axi_rlast  <= (r_left == 0);
        s_axi_rvalid <= 1'b1;
        if (r_region == 2'd2 && pps_valid) pps_pop <= 1'b1;
        if (r_incr) r_idx <= r_idx + 1'b1;
        if (r_left == 0) r_load <= 1'b0;
        else             r_left <= r_left - 1'b1;
      end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
        if (s_axi_rlast) begin
          r_busy        <= 1'b0;
          s_axi_arready <= 1'b1;
        end
      end
    end
  end

endmodule

`default_nettype wire
