// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// Web-888 open FPGA core (everything in the PL except the PS7 itself).
// Instantiated in the Vivado block design as a module reference; the AXI
// interfaces are inferred from the port name prefixes:
//   s_axi      <- PS M_AXI_GP0  (registers @ 0x40000000)
//   m_axi_rx   -> PS S_AXI_HP0  (12-channel RX ring)
//   m_axi_wf0  -> PS S_AXI_HP1  (waterfall 0 ring)
//   m_axi_wf1  -> PS S_AXI_HP2  (waterfall 1 ring)
// Everything runs in the ADC clock domain; clk_out also clocks the PS AXI
// ports (same as the vendor design).
//
// Register map: see doc/register-map.md (compatible with the stock zynqsdr
// kernel driver from web-888-20260919).

module web888_core #(
  parameter integer NRX             = 12,      // hf build 12, vhf build 13 (as stock); max 13 (CFG slots)
  parameter integer CLKIN_PERIOD_PS = 8138,      // PLL input period (ps)
  parameter integer PLL_MULT        = 8,         // HF: 8, VHF: 14 (see clk_gen.v)
  parameter integer BUILD_ID        = 0,         // e.g. 32'h20261016, reported at STS 0x18
  parameter         ROM_FILE        = "sincos_qw.mem"
) (
  // ADC (LTC2208, CMOS, offset binary)
  input  wire        adc_clk_p_i,
  input  wire        adc_clk_n_i,
  input  wire [15:0] adc_dat_a_i,
  input  wire        adc_ofl_i,
  output wire        adc_pga_o,
  output wire        adc_dith_o,

  // misc board I/O
  input  wire        pps_i,
  output wire [5:0]  antenna_o,
  output wire        led_o,

  // PS interface
  input  wire        ps_resetn,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_out CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:m_axi_rx:m_axi_wf0:m_axi_wf1, FREQ_HZ 122880000" *)
  output wire        clk_out,
  (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
  (* X_INTERFACE_PARAMETER = "SENSITIVITY EDGE_RISING, PortWidth 4" *)
  output wire [3:0]  irq,
  output wire        pps_gpio,

  // AXI3 slave (GP0)
  input  wire [11:0] s_axi_awid,
  input  wire [31:0] s_axi_awaddr,
  input  wire [3:0]  s_axi_awlen,
  input  wire [2:0]  s_axi_awsize,
  input  wire [1:0]  s_axi_awburst,
  input  wire [1:0]  s_axi_awlock,
  input  wire [3:0]  s_axi_awcache,
  input  wire [2:0]  s_axi_awprot,
  input  wire [3:0]  s_axi_awqos,
  input  wire        s_axi_awvalid,
  output wire        s_axi_awready,
  input  wire [11:0] s_axi_wid,
  input  wire [31:0] s_axi_wdata,
  input  wire [3:0]  s_axi_wstrb,
  input  wire        s_axi_wlast,
  input  wire        s_axi_wvalid,
  output wire        s_axi_wready,
  output wire [11:0] s_axi_bid,
  output wire [1:0]  s_axi_bresp,
  output wire        s_axi_bvalid,
  input  wire        s_axi_bready,
  input  wire [11:0] s_axi_arid,
  input  wire [31:0] s_axi_araddr,
  input  wire [3:0]  s_axi_arlen,
  input  wire [2:0]  s_axi_arsize,
  input  wire [1:0]  s_axi_arburst,
  input  wire [1:0]  s_axi_arlock,
  input  wire [3:0]  s_axi_arcache,
  input  wire [2:0]  s_axi_arprot,
  input  wire [3:0]  s_axi_arqos,
  input  wire        s_axi_arvalid,
  output wire        s_axi_arready,
  output wire [11:0] s_axi_rid,
  output wire [31:0] s_axi_rdata,
  output wire [1:0]  s_axi_rresp,
  output wire        s_axi_rlast,
  output wire        s_axi_rvalid,
  input  wire        s_axi_rready,

  // AXI3 masters (HP0..2)
  output wire [5:0] m_axi_rx_awid,
  output wire [31:0] m_axi_rx_awaddr,
  output wire [3:0] m_axi_rx_awlen,
  output wire [2:0] m_axi_rx_awsize,
  output wire [1:0] m_axi_rx_awburst,
  output wire [1:0] m_axi_rx_awlock,
  output wire [3:0] m_axi_rx_awcache,
  output wire [2:0] m_axi_rx_awprot,
  output wire [3:0] m_axi_rx_awqos,
  output wire m_axi_rx_awvalid,
  output wire [5:0] m_axi_rx_wid,
  output wire [63:0] m_axi_rx_wdata,
  output wire [7:0] m_axi_rx_wstrb,
  output wire m_axi_rx_wlast,
  output wire m_axi_rx_wvalid,
  output wire m_axi_rx_bready,
  output wire [5:0] m_axi_rx_arid,
  output wire [31:0] m_axi_rx_araddr,
  output wire [3:0] m_axi_rx_arlen,
  output wire [2:0] m_axi_rx_arsize,
  output wire [1:0] m_axi_rx_arburst,
  output wire [1:0] m_axi_rx_arlock,
  output wire [3:0] m_axi_rx_arcache,
  output wire [2:0] m_axi_rx_arprot,
  output wire [3:0] m_axi_rx_arqos,
  output wire m_axi_rx_arvalid,
  output wire m_axi_rx_rready,
  input  wire m_axi_rx_awready,
  input  wire m_axi_rx_wready,
  input  wire [5:0] m_axi_rx_bid,
  input  wire [1:0] m_axi_rx_bresp,
  input  wire m_axi_rx_bvalid,
  input  wire m_axi_rx_arready,
  input  wire [5:0] m_axi_rx_rid,
  input  wire [63:0] m_axi_rx_rdata,
  input  wire [1:0] m_axi_rx_rresp,
  input  wire m_axi_rx_rlast,
  input  wire m_axi_rx_rvalid,
  output wire [5:0] m_axi_wf0_awid,
  output wire [31:0] m_axi_wf0_awaddr,
  output wire [3:0] m_axi_wf0_awlen,
  output wire [2:0] m_axi_wf0_awsize,
  output wire [1:0] m_axi_wf0_awburst,
  output wire [1:0] m_axi_wf0_awlock,
  output wire [3:0] m_axi_wf0_awcache,
  output wire [2:0] m_axi_wf0_awprot,
  output wire [3:0] m_axi_wf0_awqos,
  output wire m_axi_wf0_awvalid,
  output wire [5:0] m_axi_wf0_wid,
  output wire [63:0] m_axi_wf0_wdata,
  output wire [7:0] m_axi_wf0_wstrb,
  output wire m_axi_wf0_wlast,
  output wire m_axi_wf0_wvalid,
  output wire m_axi_wf0_bready,
  output wire [5:0] m_axi_wf0_arid,
  output wire [31:0] m_axi_wf0_araddr,
  output wire [3:0] m_axi_wf0_arlen,
  output wire [2:0] m_axi_wf0_arsize,
  output wire [1:0] m_axi_wf0_arburst,
  output wire [1:0] m_axi_wf0_arlock,
  output wire [3:0] m_axi_wf0_arcache,
  output wire [2:0] m_axi_wf0_arprot,
  output wire [3:0] m_axi_wf0_arqos,
  output wire m_axi_wf0_arvalid,
  output wire m_axi_wf0_rready,
  input  wire m_axi_wf0_awready,
  input  wire m_axi_wf0_wready,
  input  wire [5:0] m_axi_wf0_bid,
  input  wire [1:0] m_axi_wf0_bresp,
  input  wire m_axi_wf0_bvalid,
  input  wire m_axi_wf0_arready,
  input  wire [5:0] m_axi_wf0_rid,
  input  wire [63:0] m_axi_wf0_rdata,
  input  wire [1:0] m_axi_wf0_rresp,
  input  wire m_axi_wf0_rlast,
  input  wire m_axi_wf0_rvalid,
  output wire [5:0] m_axi_wf1_awid,
  output wire [31:0] m_axi_wf1_awaddr,
  output wire [3:0] m_axi_wf1_awlen,
  output wire [2:0] m_axi_wf1_awsize,
  output wire [1:0] m_axi_wf1_awburst,
  output wire [1:0] m_axi_wf1_awlock,
  output wire [3:0] m_axi_wf1_awcache,
  output wire [2:0] m_axi_wf1_awprot,
  output wire [3:0] m_axi_wf1_awqos,
  output wire m_axi_wf1_awvalid,
  output wire [5:0] m_axi_wf1_wid,
  output wire [63:0] m_axi_wf1_wdata,
  output wire [7:0] m_axi_wf1_wstrb,
  output wire m_axi_wf1_wlast,
  output wire m_axi_wf1_wvalid,
  output wire m_axi_wf1_bready,
  output wire [5:0] m_axi_wf1_arid,
  output wire [31:0] m_axi_wf1_araddr,
  output wire [3:0] m_axi_wf1_arlen,
  output wire [2:0] m_axi_wf1_arsize,
  output wire [1:0] m_axi_wf1_arburst,
  output wire [1:0] m_axi_wf1_arlock,
  output wire [3:0] m_axi_wf1_arcache,
  output wire [2:0] m_axi_wf1_arprot,
  output wire [3:0] m_axi_wf1_arqos,
  output wire m_axi_wf1_arvalid,
  output wire m_axi_wf1_rready,
  input  wire m_axi_wf1_awready,
  input  wire m_axi_wf1_wready,
  input  wire [5:0] m_axi_wf1_bid,
  input  wire [1:0] m_axi_wf1_bresp,
  input  wire m_axi_wf1_bvalid,
  input  wire m_axi_wf1_arready,
  input  wire [5:0] m_axi_wf1_rid,
  input  wire [63:0] m_axi_wf1_rdata,
  input  wire [1:0] m_axi_wf1_rresp,
  input  wire m_axi_wf1_rlast,
  input  wire m_axi_wf1_rvalid
);

  // ---------------------------------------------------------------- clock/reset
  wire clk, pll_locked;
  clk_gen #(.CLKIN_PERIOD_PS(CLKIN_PERIOD_PS), .MULT(PLL_MULT)) clkgen (
    .clk_p(adc_clk_p_i), .clk_n(adc_clk_n_i), .clk(clk), .locked(pll_locked));
  assign clk_out = clk;

  // Two resets:
  //  rst    bus-level: PS reset only. Register file, AXI slave and DMA
  //         masters. Never asserted mid-transaction by a clock glitch, and the
  //         driver's configuration survives an ADC clock PLL relock.
  //  rst_dp datapath: rst or PLL unlocked. DDC/CIC state, PPS, monitors; the
  //         RX packer pads the open frame so the ring stays aligned.
  (* ASYNC_REG = "TRUE" *) reg [3:0] rst_sync;
  (* ASYNC_REG = "TRUE" *) reg [3:0] lock_sync;
  always @(posedge clk or negedge ps_resetn)
    if (!ps_resetn) rst_sync <= 4'hf;
    else            rst_sync <= {rst_sync[2:0], 1'b0};
  always @(posedge clk or negedge ps_resetn)
    if (!ps_resetn) lock_sync <= 4'hf;
    else            lock_sync <= {lock_sync[2:0], !pll_locked};
  wire rst    = rst_sync[3];
  wire rst_dp = rst || lock_sync[3];

  // PLL unlock events since PS reset (counted at the start of each unlock;
  // lock_sync is already high during and right after PS reset)
  reg        unlocked_d;
  reg [15:0] unlock_count;
  always @(posedge clk) begin
    unlocked_d <= lock_sync[3];
    if (rst)                           unlock_count <= 16'd0;
    else if (lock_sync[3] && !unlocked_d && unlock_count != 16'hffff)
                                       unlock_count <= unlock_count + 1'b1;
  end

  // ---------------------------------------------------------------- ADC capture
  (* IOB = "TRUE" *) reg [15:0] adc_iob;
  (* IOB = "TRUE" *) reg        ofl_iob;
  reg signed [15:0] adc;
  reg               adc_ovf;
  always @(posedge clk) begin
    adc_iob <= adc_dat_a_i;
    ofl_iob <= adc_ofl_i;
    adc     <= {~adc_iob[15], adc_iob[14:0]};   // offset binary -> two's complement
    adc_ovf <= ofl_iob;
  end

  // ---------------------------------------------------------------- registers
  localparam integer CFG_WORDS = 40;
  localparam integer STS_WORDS = 16;
  wire [CFG_WORDS*32-1:0] cfg;
  wire [STS_WORDS*32-1:0] sts;


  wire [15:0] ctrl       = cfg[15:0];                  // 0x00
  wire        rx_en      = ctrl[0];
  wire        wf0_en     = ctrl[1];
  wire        wf1_en     = ctrl[2];
  wire        pps_en     = ctrl[7];
  wire [15:0] rx_decim   = cfg[31:16];                 // 0x02
  wire [NRX*48-1:0] rx_inc;                            // 0x04 + 8*ch
  genvar gc;
  generate
    for (gc = 0; gc < NRX; gc = gc + 1) begin : rxinc
      assign rx_inc[gc*48 +: 48] = cfg[(32 + gc*64) +: 48];
    end
  endgenerate
  wire [47:0] wf0_inc    = cfg[27*32 +: 48];           // 0x6c
  wire [15:0] wf0_decim  = cfg[29*32 +: 16];           // 0x74
  wire [47:0] wf1_inc    = cfg[30*32 +: 48];           // 0x78
  wire [15:0] wf1_decim  = cfg[32*32 +: 16];           // 0x80
  wire [31:0] gpio       = cfg[33*32 +: 32];           // 0x84
  wire [31:0] rx_addr    = cfg[35*32 +: 32];           // 0x8c
  wire [15:0] rx_len     = cfg[36*32 +: 16];           // 0x90
  wire [31:0] wf0_addr   = cfg[36*32+16 +: 32];        // 0x92
  wire [15:0] wf0_len    = cfg[37*32+16 +: 16];        // 0x96
  wire [31:0] wf1_addr   = cfg[38*32 +: 32];           // 0x98
  wire [15:0] wf1_len    = cfg[39*32 +: 16];           // 0x9c
  wire [15:0] wf_mode    = cfg[39*32+16 +: 16];        // 0x9e  bit n: 1 = continuous

  wire [31:0] pps_fifo_data;
  wire        pps_fifo_valid, pps_fifo_pop;

  axi_regs #(.CFG_WORDS(CFG_WORDS), .STS_WORDS(STS_WORDS), .ID_W(12)) regs (
    .clk(clk), .rst(rst), .cfg(cfg), .sts(sts),
    .pps_data(pps_fifo_data), .pps_valid(pps_fifo_valid), .pps_pop(pps_fifo_pop),
    .s_axi_awid(s_axi_awid), .s_axi_awaddr(s_axi_awaddr), .s_axi_awlen(s_axi_awlen),
    .s_axi_awsize(s_axi_awsize), .s_axi_awburst(s_axi_awburst), .s_axi_awlock(s_axi_awlock),
    .s_axi_awcache(s_axi_awcache), .s_axi_awprot(s_axi_awprot), .s_axi_awqos(s_axi_awqos),
    .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wid(s_axi_wid), .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wlast(s_axi_wlast), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bid(s_axi_bid), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),
    .s_axi_arid(s_axi_arid), .s_axi_araddr(s_axi_araddr), .s_axi_arlen(s_axi_arlen),
    .s_axi_arsize(s_axi_arsize), .s_axi_arburst(s_axi_arburst), .s_axi_arlock(s_axi_arlock),
    .s_axi_arcache(s_axi_arcache), .s_axi_arprot(s_axi_arprot), .s_axi_arqos(s_axi_arqos),
    .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rid(s_axi_rid), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
    .s_axi_rlast(s_axi_rlast), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready));

  // ---------------------------------------------------------------- RX
  wire        rx_run, rx_wv;
  wire [63:0] rx_wd;
  wire [15:0] rx_ptr;
  wire        rx_done, rx_ovf, rx_seq_err, rx_bresp_err;
  wire [15:0] rx_resyncs;
  wire [31:0] rx_frames, rx_drops, rx_bursts;

  rx_chain #(.NCH(NRX), .ROM_FILE(ROM_FILE)) rx (
    .clk(clk), .rst(rst), .dp_rst(rst_dp), .en(rx_run), .adc(adc), .inc(rx_inc),
    .decim(rx_decim), .m_valid(rx_wv), .m_data(rx_wd),
    .seq_err(rx_seq_err), .resyncs(rx_resyncs));

  axi_ring_writer #(.FIFO_AW(9), .FRAME(NRX)) rx_dma (
    .clk(clk), .rst(rst), .enable(rx_en), .base_addr(rx_addr), .len_m1(rx_len),
    .oneshot(16'd0), .running(rx_run), .ptr(rx_ptr), .burst_done(rx_done),
    .overflow(rx_ovf), .frames(rx_frames), .drops(rx_drops), .bursts(rx_bursts),
    .bresp_err(rx_bresp_err), .s_data(rx_wd), .s_valid(rx_wv),
    .m_axi_awid(m_axi_rx_awid),
    .m_axi_awaddr(m_axi_rx_awaddr),
    .m_axi_awlen(m_axi_rx_awlen),
    .m_axi_awsize(m_axi_rx_awsize),
    .m_axi_awburst(m_axi_rx_awburst),
    .m_axi_awlock(m_axi_rx_awlock),
    .m_axi_awcache(m_axi_rx_awcache),
    .m_axi_awprot(m_axi_rx_awprot),
    .m_axi_awqos(m_axi_rx_awqos),
    .m_axi_awvalid(m_axi_rx_awvalid),
    .m_axi_wid(m_axi_rx_wid),
    .m_axi_wdata(m_axi_rx_wdata),
    .m_axi_wstrb(m_axi_rx_wstrb),
    .m_axi_wlast(m_axi_rx_wlast),
    .m_axi_wvalid(m_axi_rx_wvalid),
    .m_axi_bready(m_axi_rx_bready),
    .m_axi_arid(m_axi_rx_arid),
    .m_axi_araddr(m_axi_rx_araddr),
    .m_axi_arlen(m_axi_rx_arlen),
    .m_axi_arsize(m_axi_rx_arsize),
    .m_axi_arburst(m_axi_rx_arburst),
    .m_axi_arlock(m_axi_rx_arlock),
    .m_axi_arcache(m_axi_rx_arcache),
    .m_axi_arprot(m_axi_rx_arprot),
    .m_axi_arqos(m_axi_rx_arqos),
    .m_axi_arvalid(m_axi_rx_arvalid),
    .m_axi_rready(m_axi_rx_rready),
    .m_axi_awready(m_axi_rx_awready),
    .m_axi_wready(m_axi_rx_wready),
    .m_axi_bid(m_axi_rx_bid),
    .m_axi_bresp(m_axi_rx_bresp),
    .m_axi_bvalid(m_axi_rx_bvalid),
    .m_axi_arready(m_axi_rx_arready),
    .m_axi_rid(m_axi_rx_rid),
    .m_axi_rdata(m_axi_rx_rdata),
    .m_axi_rresp(m_axi_rx_rresp),
    .m_axi_rlast(m_axi_rx_rlast),
    .m_axi_rvalid(m_axi_rx_rvalid));

  // ---------------------------------------------------------------- waterfall
  localparam [15:0] WF_ONESHOT_BURSTS = 16'd256;   // 8192 samples * 4 B / 128 B

  wire        wf0_run, wf0_wv, wf0_done, wf0_ovf, wf0_bresp_err;
  wire [31:0] wf0_bursts;
  wire [63:0] wf0_wd;
  wire [15:0] wf0_ptr;

  wf_ddc #(.ROM_FILE(ROM_FILE)) wf0 (
    .clk(clk), .rst(rst_dp), .en(wf0_run), .adc(adc), .inc(wf0_inc), .decim(wf0_decim),
    .m_valid(wf0_wv), .m_data(wf0_wd));

  axi_ring_writer #(.FIFO_AW(10)) wf0_dma (
    .clk(clk), .rst(rst), .enable(wf0_en), .base_addr(wf0_addr), .len_m1(wf0_len),
    .oneshot(wf_mode[0] ? 16'd0 : WF_ONESHOT_BURSTS), .running(wf0_run), .ptr(wf0_ptr),
    .burst_done(wf0_done), .overflow(wf0_ovf), .frames(), .drops(),
    .bursts(wf0_bursts), .bresp_err(wf0_bresp_err), .s_data(wf0_wd), .s_valid(wf0_wv),
    .m_axi_awid(m_axi_wf0_awid),
    .m_axi_awaddr(m_axi_wf0_awaddr),
    .m_axi_awlen(m_axi_wf0_awlen),
    .m_axi_awsize(m_axi_wf0_awsize),
    .m_axi_awburst(m_axi_wf0_awburst),
    .m_axi_awlock(m_axi_wf0_awlock),
    .m_axi_awcache(m_axi_wf0_awcache),
    .m_axi_awprot(m_axi_wf0_awprot),
    .m_axi_awqos(m_axi_wf0_awqos),
    .m_axi_awvalid(m_axi_wf0_awvalid),
    .m_axi_wid(m_axi_wf0_wid),
    .m_axi_wdata(m_axi_wf0_wdata),
    .m_axi_wstrb(m_axi_wf0_wstrb),
    .m_axi_wlast(m_axi_wf0_wlast),
    .m_axi_wvalid(m_axi_wf0_wvalid),
    .m_axi_bready(m_axi_wf0_bready),
    .m_axi_arid(m_axi_wf0_arid),
    .m_axi_araddr(m_axi_wf0_araddr),
    .m_axi_arlen(m_axi_wf0_arlen),
    .m_axi_arsize(m_axi_wf0_arsize),
    .m_axi_arburst(m_axi_wf0_arburst),
    .m_axi_arlock(m_axi_wf0_arlock),
    .m_axi_arcache(m_axi_wf0_arcache),
    .m_axi_arprot(m_axi_wf0_arprot),
    .m_axi_arqos(m_axi_wf0_arqos),
    .m_axi_arvalid(m_axi_wf0_arvalid),
    .m_axi_rready(m_axi_wf0_rready),
    .m_axi_awready(m_axi_wf0_awready),
    .m_axi_wready(m_axi_wf0_wready),
    .m_axi_bid(m_axi_wf0_bid),
    .m_axi_bresp(m_axi_wf0_bresp),
    .m_axi_bvalid(m_axi_wf0_bvalid),
    .m_axi_arready(m_axi_wf0_arready),
    .m_axi_rid(m_axi_wf0_rid),
    .m_axi_rdata(m_axi_wf0_rdata),
    .m_axi_rresp(m_axi_wf0_rresp),
    .m_axi_rlast(m_axi_wf0_rlast),
    .m_axi_rvalid(m_axi_wf0_rvalid));

  wire        wf1_run, wf1_wv, wf1_done, wf1_ovf, wf1_bresp_err;
  wire [31:0] wf1_bursts;
  wire [63:0] wf1_wd;
  wire [15:0] wf1_ptr;

  wf_ddc #(.ROM_FILE(ROM_FILE)) wf1 (
    .clk(clk), .rst(rst_dp), .en(wf1_run), .adc(adc), .inc(wf1_inc), .decim(wf1_decim),
    .m_valid(wf1_wv), .m_data(wf1_wd));

  axi_ring_writer #(.FIFO_AW(10)) wf1_dma (
    .clk(clk), .rst(rst), .enable(wf1_en), .base_addr(wf1_addr), .len_m1(wf1_len),
    .oneshot(wf_mode[1] ? 16'd0 : WF_ONESHOT_BURSTS), .running(wf1_run), .ptr(wf1_ptr),
    .burst_done(wf1_done), .overflow(wf1_ovf), .frames(), .drops(),
    .bursts(wf1_bursts), .bresp_err(wf1_bresp_err), .s_data(wf1_wd), .s_valid(wf1_wv),
    .m_axi_awid(m_axi_wf1_awid),
    .m_axi_awaddr(m_axi_wf1_awaddr),
    .m_axi_awlen(m_axi_wf1_awlen),
    .m_axi_awsize(m_axi_wf1_awsize),
    .m_axi_awburst(m_axi_wf1_awburst),
    .m_axi_awlock(m_axi_wf1_awlock),
    .m_axi_awcache(m_axi_wf1_awcache),
    .m_axi_awprot(m_axi_wf1_awprot),
    .m_axi_awqos(m_axi_wf1_awqos),
    .m_axi_awvalid(m_axi_wf1_awvalid),
    .m_axi_wid(m_axi_wf1_wid),
    .m_axi_wdata(m_axi_wf1_wdata),
    .m_axi_wstrb(m_axi_wf1_wstrb),
    .m_axi_wlast(m_axi_wf1_wlast),
    .m_axi_wvalid(m_axi_wf1_wvalid),
    .m_axi_bready(m_axi_wf1_bready),
    .m_axi_arid(m_axi_wf1_arid),
    .m_axi_araddr(m_axi_wf1_araddr),
    .m_axi_arlen(m_axi_wf1_arlen),
    .m_axi_arsize(m_axi_wf1_arsize),
    .m_axi_arburst(m_axi_wf1_arburst),
    .m_axi_arlock(m_axi_wf1_arlock),
    .m_axi_arcache(m_axi_wf1_arcache),
    .m_axi_arprot(m_axi_wf1_arprot),
    .m_axi_arqos(m_axi_wf1_arqos),
    .m_axi_arvalid(m_axi_wf1_arvalid),
    .m_axi_rready(m_axi_wf1_rready),
    .m_axi_awready(m_axi_wf1_awready),
    .m_axi_wready(m_axi_wf1_wready),
    .m_axi_bid(m_axi_wf1_bid),
    .m_axi_bresp(m_axi_wf1_bresp),
    .m_axi_bvalid(m_axi_wf1_bvalid),
    .m_axi_arready(m_axi_wf1_arready),
    .m_axi_rid(m_axi_wf1_rid),
    .m_axi_rdata(m_axi_wf1_rdata),
    .m_axi_rresp(m_axi_wf1_rresp),
    .m_axi_rlast(m_axi_wf1_rlast),
    .m_axi_rvalid(m_axi_wf1_rvalid));

  // ---------------------------------------------------------------- PPS
  wire [15:0] pps_count;
  wire [31:0] pps_last;
  wire        pps_edge;

  pps_counter pps (
    .clk(clk), .rst(rst_dp), .en(pps_en), .pps_in(pps_i),
    .fifo_data(pps_fifo_data), .fifo_valid(pps_fifo_valid), .fifo_pop(pps_fifo_pop),
    .fifo_count(pps_count), .last(pps_last), .edge_pulse(pps_edge));

  assign pps_gpio = pps_i;   // EMIO GPIO 54 -> kernel pps-gpio / chrony

  // ---------------------------------------------------------------- DNA
  wire [56:0] dna;
  wire        dna_valid;
  dna_reader dnar (.clk(clk), .rst(rst), .dna(dna), .valid(dna_valid));

  // ---------------------------------------------------------------- ADC monitors
  reg [31:0] ovf_count;
  reg [15:0] peak, peak_hold;
  reg [23:0] peak_win;
  reg [63:0] sample_count;
  wire [15:0] adc_abs = adc[15] ? ~adc : adc;
  always @(posedge clk) begin
    if (rst_dp) begin
      ovf_count    <= 0;
      peak         <= 0;
      peak_hold    <= 0;
      peak_win     <= 0;
      sample_count <= 0;
    end else begin
      sample_count <= sample_count + 1'b1;
      if (adc_ovf) ovf_count <= ovf_count + 1'b1;
      peak_win <= peak_win + 1'b1;
      if (peak_win == 0) begin
        peak_hold <= peak;
        peak      <= adc_abs;
      end else if (adc_abs > peak) begin
        peak <= adc_abs;
      end
    end
  end

  // ---------------------------------------------------------------- status
  localparam [3:0] NRX4 = NRX;
  wire [31:0] signature = {16'h0E5D, 4'd0, 4'd2, 4'd0, NRX4};
  wire [31:0] flags = {unlock_count, 3'd0, wf1_run, wf0_run, rx_run, dna_valid,
                       pll_locked, 1'b0, wf1_bresp_err, wf0_bresp_err,
                       rx_bresp_err, rx_seq_err, wf1_ovf, wf0_ovf, rx_ovf};

  assign sts[ 0*32 +: 32] = signature;                  // 0x00
  assign sts[ 1*32 +: 32] = {wf0_ptr, rx_ptr};          // 0x04 rx, 0x06 wf0
  assign sts[ 2*32 +: 32] = {pps_count, wf1_ptr};       // 0x08 wf1, 0x0a pps fifo
  assign sts[ 3*32 +: 32] = dna[31:0];                  // 0x0c
  assign sts[ 4*32 +: 32] = {7'd0, dna[56:32]};         // 0x10
  assign sts[ 5*32 +: 32] = pps_last;                   // 0x14
  // ---- extensions (not used by the stock driver)
  assign sts[ 6*32 +: 32] = BUILD_ID;                   // 0x18
  assign sts[ 7*32 +: 32] = ovf_count;                  // 0x1c
  assign sts[ 8*32 +: 32] = flags;                      // 0x20
  assign sts[ 9*32 +: 32] = {16'd0, peak_hold};         // 0x24
  assign sts[10*32 +: 32] = sample_count[31:0];         // 0x28
  assign sts[11*32 +: 32] = sample_count[63:32];        // 0x2c
  assign sts[12*32 +: 32] = rx_frames;                  // 0x30
  assign sts[13*32 +: 32] = rx_drops;                   // 0x34
  assign sts[14*32 +: 32] = rx_bursts;                  // 0x38
  assign sts[15*32 +: 32] = {wf1_bursts[15:0], wf0_bursts[15:0]};  // 0x3c

  // ---------------------------------------------------------------- outputs
  reg [8:0] gpio_r;
  always @(posedge clk) gpio_r <= gpio[8:0];
  assign antenna_o  = gpio_r[5:0];
  assign adc_dith_o = gpio_r[6];
  assign adc_pga_o  = gpio_r[7];
  assign led_o      = gpio_r[8];

  assign irq = {pps_edge, wf1_done, wf0_done, rx_done};

endmodule

`default_nettype wire
