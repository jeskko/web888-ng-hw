// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The channelizer with its outputs (hw/docs/channelizer.md §3.7): ADC
// samples -> pfb_chain -> the bin selector and the power line, each into
// a DDR ring through an AXI3 master (axi_ring_writer, frames marked by
// their headers). Configuration and status are ports, for the register
// file of the bitstream around it (and for synthesising it alone).

module pfb_top #(
  parameter integer NSEL = 64,
  // ROM tables (rtl/gen; Vivado finds them by name among the sources)
  parameter         COEF_PREFIX = "pfb_coef_",
  parameter         TW_PREFIX   = "pfb_tw_",
  parameter         SPLIT_FILE  = "pfb_split_tw.mem"
) (
  input  wire        clk,
  input  wire        rst,
  input  wire signed [15:0] adc,

  // bins: the mask (pfb_select), the ring
  input  wire        bins_enable,
  input  wire        mask_we,
  input  wire [5:0]  mask_addr,
  input  wire [31:0] mask_data,
  input  wire [3:0]  gen_req,
  output wire [3:0]  gen,
  output wire        truncated,
  input  wire [31:0] bins_addr,
  input  wire [15:0] bins_len_m1,
  output wire [15:0] bins_ptr,
  output wire        bins_done,          // a burst written (interrupt)
  output wire        bins_overflow,
  output wire [31:0] bins_frames,
  output wire [31:0] bins_drops,
  output wire        bins_bresp_err,

  // the power line: frames per line (0: off), the ring
  input  wire        power_enable,
  input  wire [15:0] power_frames,
  input  wire [31:0] power_addr,
  input  wire [15:0] power_len_m1,
  output wire [15:0] power_ptr,
  output wire        power_done,
  output wire        power_overflow,
  output wire [31:0] power_frames_out,
  output wire [31:0] power_drops,
  output wire        power_bresp_err,

  output wire [5:0]   m_axi_bn_awid,
  output wire [31:0]  m_axi_bn_awaddr,
  output wire [3:0]   m_axi_bn_awlen,
  output wire [2:0]   m_axi_bn_awsize,
  output wire [1:0]   m_axi_bn_awburst,
  output wire [1:0]   m_axi_bn_awlock,
  output wire [3:0]   m_axi_bn_awcache,
  output wire [2:0]   m_axi_bn_awprot,
  output wire [3:0]   m_axi_bn_awqos,
  output wire         m_axi_bn_awvalid,
  output wire [5:0]   m_axi_bn_wid,
  output wire [63:0]  m_axi_bn_wdata,
  output wire [7:0]   m_axi_bn_wstrb,
  output wire         m_axi_bn_wlast,
  output wire         m_axi_bn_wvalid,
  output wire         m_axi_bn_bready,
  output wire [5:0]   m_axi_bn_arid,
  output wire [31:0]  m_axi_bn_araddr,
  output wire [3:0]   m_axi_bn_arlen,
  output wire [2:0]   m_axi_bn_arsize,
  output wire [1:0]   m_axi_bn_arburst,
  output wire [1:0]   m_axi_bn_arlock,
  output wire [3:0]   m_axi_bn_arcache,
  output wire [2:0]   m_axi_bn_arprot,
  output wire [3:0]   m_axi_bn_arqos,
  output wire         m_axi_bn_arvalid,
  output wire         m_axi_bn_rready,
  input  wire         m_axi_bn_awready,
  input  wire         m_axi_bn_wready,
  input  wire [5:0]   m_axi_bn_bid,
  input  wire [1:0]   m_axi_bn_bresp,
  input  wire         m_axi_bn_bvalid,
  input  wire         m_axi_bn_arready,
  input  wire [5:0]   m_axi_bn_rid,
  input  wire [63:0]  m_axi_bn_rdata,
  input  wire [1:0]   m_axi_bn_rresp,
  input  wire         m_axi_bn_rlast,
  input  wire         m_axi_bn_rvalid,
  output wire [5:0]   m_axi_pw_awid,
  output wire [31:0]  m_axi_pw_awaddr,
  output wire [3:0]   m_axi_pw_awlen,
  output wire [2:0]   m_axi_pw_awsize,
  output wire [1:0]   m_axi_pw_awburst,
  output wire [1:0]   m_axi_pw_awlock,
  output wire [3:0]   m_axi_pw_awcache,
  output wire [2:0]   m_axi_pw_awprot,
  output wire [3:0]   m_axi_pw_awqos,
  output wire         m_axi_pw_awvalid,
  output wire [5:0]   m_axi_pw_wid,
  output wire [63:0]  m_axi_pw_wdata,
  output wire [7:0]   m_axi_pw_wstrb,
  output wire         m_axi_pw_wlast,
  output wire         m_axi_pw_wvalid,
  output wire         m_axi_pw_bready,
  output wire [5:0]   m_axi_pw_arid,
  output wire [31:0]  m_axi_pw_araddr,
  output wire [3:0]   m_axi_pw_arlen,
  output wire [2:0]   m_axi_pw_arsize,
  output wire [1:0]   m_axi_pw_arburst,
  output wire [1:0]   m_axi_pw_arlock,
  output wire [3:0]   m_axi_pw_arcache,
  output wire [2:0]   m_axi_pw_arprot,
  output wire [3:0]   m_axi_pw_arqos,
  output wire         m_axi_pw_arvalid,
  output wire         m_axi_pw_rready,
  input  wire         m_axi_pw_awready,
  input  wire         m_axi_pw_wready,
  input  wire [5:0]   m_axi_pw_bid,
  input  wire [1:0]   m_axi_pw_bresp,
  input  wire         m_axi_pw_bvalid,
  input  wire         m_axi_pw_arready,
  input  wire [5:0]   m_axi_pw_rid,
  input  wire [63:0]  m_axi_pw_rdata,
  input  wire [1:0]   m_axi_pw_rresp,
  input  wire         m_axi_pw_rlast,
  input  wire         m_axi_pw_rvalid
);

  wire signed [24:0] re, im;
  wire [10:0]        k;
  wire               valid;
  wire [15:0]        frame;
  pfb_chain #(.COEF_PREFIX(COEF_PREFIX), .TW_PREFIX(TW_PREFIX), .SPLIT_FILE(SPLIT_FILE)) chain (
    .clk(clk), .ce(1'b1), .adc(adc),
    .out_re(re), .out_im(im), .out_k(k), .out_valid(valid), .out_frame(frame));

  // ---- bins
  wire        bn_run;
  wire [63:0] bn_d;
  wire        bn_v, bn_f;
  pfb_select #(.NSEL(NSEL)) sel (
    .clk(clk), .ce(1'b1), .enable(bn_run),
    .in_re(re), .in_im(im), .in_k(k), .in_valid(valid),
    .mask_we(mask_we), .mask_addr(mask_addr), .mask_data(mask_data),
    .gen_req(gen_req), .gen(gen), .truncated(truncated),
    .s_data(bn_d), .s_valid(bn_v), .s_first(bn_f));

  axi_ring_writer #(.FIFO_AW(9), .FRAME(NSEL + 1), .VARLEN(1)) bins_dma (
    .clk(clk), .rst(rst), .enable(bins_enable), .base_addr(bins_addr), .len_m1(bins_len_m1),
    .oneshot(16'd0), .running(bn_run), .ptr(bins_ptr), .burst_done(bins_done),
    .overflow(bins_overflow), .frames(bins_frames), .drops(bins_drops), .bursts(),
    .bresp_err(bins_bresp_err), .s_data(bn_d), .s_valid(bn_v), .s_first(bn_f),
    .m_axi_awid(m_axi_bn_awid),
    .m_axi_awaddr(m_axi_bn_awaddr),
    .m_axi_awlen(m_axi_bn_awlen),
    .m_axi_awsize(m_axi_bn_awsize),
    .m_axi_awburst(m_axi_bn_awburst),
    .m_axi_awlock(m_axi_bn_awlock),
    .m_axi_awcache(m_axi_bn_awcache),
    .m_axi_awprot(m_axi_bn_awprot),
    .m_axi_awqos(m_axi_bn_awqos),
    .m_axi_awvalid(m_axi_bn_awvalid),
    .m_axi_wid(m_axi_bn_wid),
    .m_axi_wdata(m_axi_bn_wdata),
    .m_axi_wstrb(m_axi_bn_wstrb),
    .m_axi_wlast(m_axi_bn_wlast),
    .m_axi_wvalid(m_axi_bn_wvalid),
    .m_axi_bready(m_axi_bn_bready),
    .m_axi_arid(m_axi_bn_arid),
    .m_axi_araddr(m_axi_bn_araddr),
    .m_axi_arlen(m_axi_bn_arlen),
    .m_axi_arsize(m_axi_bn_arsize),
    .m_axi_arburst(m_axi_bn_arburst),
    .m_axi_arlock(m_axi_bn_arlock),
    .m_axi_arcache(m_axi_bn_arcache),
    .m_axi_arprot(m_axi_bn_arprot),
    .m_axi_arqos(m_axi_bn_arqos),
    .m_axi_arvalid(m_axi_bn_arvalid),
    .m_axi_rready(m_axi_bn_rready),
    .m_axi_awready(m_axi_bn_awready),
    .m_axi_wready(m_axi_bn_wready),
    .m_axi_bid(m_axi_bn_bid),
    .m_axi_bresp(m_axi_bn_bresp),
    .m_axi_bvalid(m_axi_bn_bvalid),
    .m_axi_arready(m_axi_bn_arready),
    .m_axi_rid(m_axi_bn_rid),
    .m_axi_rdata(m_axi_bn_rdata),
    .m_axi_rresp(m_axi_bn_rresp),
    .m_axi_rlast(m_axi_bn_rlast),
    .m_axi_rvalid(m_axi_bn_rvalid));

  // ---- the power line
  wire        pw_run;
  wire [63:0] pw_d;
  wire        pw_v, pw_f;
  pfb_power pow (
    .clk(clk), .ce(1'b1), .enable(pw_run), .frames(power_frames),
    .in_re(re), .in_im(im), .in_k(k), .in_valid(valid),
    .s_data(pw_d), .s_valid(pw_v), .s_first(pw_f));

  axi_ring_writer #(.FIFO_AW(9), .FRAME(65), .VARLEN(1)) power_dma (
    .clk(clk), .rst(rst), .enable(power_enable), .base_addr(power_addr), .len_m1(power_len_m1),
    .oneshot(16'd0), .running(pw_run), .ptr(power_ptr), .burst_done(power_done),
    .overflow(power_overflow), .frames(power_frames_out), .drops(power_drops), .bursts(),
    .bresp_err(power_bresp_err), .s_data(pw_d), .s_valid(pw_v), .s_first(pw_f),
    .m_axi_awid(m_axi_pw_awid),
    .m_axi_awaddr(m_axi_pw_awaddr),
    .m_axi_awlen(m_axi_pw_awlen),
    .m_axi_awsize(m_axi_pw_awsize),
    .m_axi_awburst(m_axi_pw_awburst),
    .m_axi_awlock(m_axi_pw_awlock),
    .m_axi_awcache(m_axi_pw_awcache),
    .m_axi_awprot(m_axi_pw_awprot),
    .m_axi_awqos(m_axi_pw_awqos),
    .m_axi_awvalid(m_axi_pw_awvalid),
    .m_axi_wid(m_axi_pw_wid),
    .m_axi_wdata(m_axi_pw_wdata),
    .m_axi_wstrb(m_axi_pw_wstrb),
    .m_axi_wlast(m_axi_pw_wlast),
    .m_axi_wvalid(m_axi_pw_wvalid),
    .m_axi_bready(m_axi_pw_bready),
    .m_axi_arid(m_axi_pw_arid),
    .m_axi_araddr(m_axi_pw_araddr),
    .m_axi_arlen(m_axi_pw_arlen),
    .m_axi_arsize(m_axi_pw_arsize),
    .m_axi_arburst(m_axi_pw_arburst),
    .m_axi_arlock(m_axi_pw_arlock),
    .m_axi_arcache(m_axi_pw_arcache),
    .m_axi_arprot(m_axi_pw_arprot),
    .m_axi_arqos(m_axi_pw_arqos),
    .m_axi_arvalid(m_axi_pw_arvalid),
    .m_axi_rready(m_axi_pw_rready),
    .m_axi_awready(m_axi_pw_awready),
    .m_axi_wready(m_axi_pw_wready),
    .m_axi_bid(m_axi_pw_bid),
    .m_axi_bresp(m_axi_pw_bresp),
    .m_axi_bvalid(m_axi_pw_bvalid),
    .m_axi_arready(m_axi_pw_arready),
    .m_axi_rid(m_axi_pw_rid),
    .m_axi_rdata(m_axi_pw_rdata),
    .m_axi_rresp(m_axi_pw_rresp),
    .m_axi_rlast(m_axi_pw_rlast),
    .m_axi_rvalid(m_axi_pw_rvalid));

endmodule

`default_nettype wire
