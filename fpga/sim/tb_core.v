// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps

// Full-core test: drives web888_core through the GP0 register interface with
// the same access patterns as the stock zynqsdr driver, captures the three
// HP DMA streams in memory models and dumps them for sim/analyze.py.

module tb_core;

  localparam real FS     = 122.88e6;
  localparam real TCLK   = 1.0e9 / FS;
  localparam real F1     = 7.0745e6;     // tone 1, -6 dBFS
  localparam real F2     = 14.2005e6;    // tone 2, -12 dBFS
  localparam integer PPS_PERIOD = 100000;
  localparam integer RX_DECIM   = 5;      // fs_out = 96 kHz
  localparam integer RX_FRAMES  = 320;
  localparam integer NRX        = 12;

  // ---------------------------------------------------------------- clocks
  reg adc_clk = 0;
  always #(TCLK/2) adc_clk = ~adc_clk;

  // ADC: offset binary, data changes on falling edge
  reg  [15:0] adc_dat = 16'h8000;
  integer n = 0;
  real    v;
  integer vi;
  always @(negedge adc_clk) begin
    v  = 16384.0 * $sin(6.283185307179586 * F1 * n / FS) +
          8192.0 * $sin(6.283185307179586 * F2 * n / FS);
    vi = $rtoi(v < 0 ? v - 0.5 : v + 0.5);
    adc_dat <= vi[15:0] ^ 16'h8000;
    n = n + 1;
  end

  reg pps = 0;
  integer pc = 0;
  always @(posedge adc_clk) begin
    pc  = pc + 1;
    pps <= (pc % PPS_PERIOD) < 1000;
  end

  reg ps_resetn = 0;

  // ---------------------------------------------------------------- DUT
  wire        clk_out;
  wire [3:0]  irq;
  wire        pps_gpio, adc_pga, adc_dith, led;
  wire [5:0]  antenna;

  reg  [11:0] awid = 0, arid = 0;
  reg  [31:0] awaddr, araddr, wdata;
  reg  [3:0]  wstrb;
  reg         awvalid = 0, wvalid = 0, arvalid = 0, bready = 0, rready = 0;
  wire        awready, wready, bvalid, arready, rvalid, rlast;
  wire [11:0] bid, rid;
  wire [1:0]  bresp, rresp;
  wire [31:0] rdata;

  `define HP_WIRES(p) \
    wire [5:0] p``_awid, p``_wid, p``_arid; wire [31:0] p``_awaddr, p``_araddr; \
    wire [3:0] p``_awlen, p``_awcache, p``_awqos, p``_arlen, p``_arcache, p``_arqos; \
    wire [2:0] p``_awsize, p``_awprot, p``_arsize, p``_arprot; \
    wire [1:0] p``_awburst, p``_awlock, p``_arburst, p``_arlock, p``_bresp; \
    wire p``_awvalid, p``_awready, p``_wlast, p``_wvalid, p``_wready, p``_bvalid, p``_bready, p``_arvalid, p``_rready; \
    wire [63:0] p``_wdata; wire [7:0] p``_wstrb; wire [5:0] p``_bid;
  `HP_WIRES(rx)
  `HP_WIRES(wf0)
  `HP_WIRES(wf1)

  `define HP_CONN(p) \
    .m_axi_``p``_awid(p``_awid), .m_axi_``p``_awaddr(p``_awaddr), .m_axi_``p``_awlen(p``_awlen), \
    .m_axi_``p``_awsize(p``_awsize), .m_axi_``p``_awburst(p``_awburst), .m_axi_``p``_awlock(p``_awlock), \
    .m_axi_``p``_awcache(p``_awcache), .m_axi_``p``_awprot(p``_awprot), .m_axi_``p``_awqos(p``_awqos), \
    .m_axi_``p``_awvalid(p``_awvalid), .m_axi_``p``_awready(p``_awready), .m_axi_``p``_wid(p``_wid), \
    .m_axi_``p``_wdata(p``_wdata), .m_axi_``p``_wstrb(p``_wstrb), .m_axi_``p``_wlast(p``_wlast), \
    .m_axi_``p``_wvalid(p``_wvalid), .m_axi_``p``_wready(p``_wready), .m_axi_``p``_bid(p``_bid), \
    .m_axi_``p``_bresp(p``_bresp), .m_axi_``p``_bvalid(p``_bvalid), .m_axi_``p``_bready(p``_bready), \
    .m_axi_``p``_arid(p``_arid), .m_axi_``p``_araddr(p``_araddr), .m_axi_``p``_arlen(p``_arlen), \
    .m_axi_``p``_arsize(p``_arsize), .m_axi_``p``_arburst(p``_arburst), .m_axi_``p``_arlock(p``_arlock), \
    .m_axi_``p``_arcache(p``_arcache), .m_axi_``p``_arprot(p``_arprot), .m_axi_``p``_arqos(p``_arqos), \
    .m_axi_``p``_arvalid(p``_arvalid), .m_axi_``p``_arready(1'b0), .m_axi_``p``_rid(6'd0), \
    .m_axi_``p``_rdata(64'd0), .m_axi_``p``_rresp(2'd0), .m_axi_``p``_rlast(1'b0), \
    .m_axi_``p``_rvalid(1'b0), .m_axi_``p``_rready(p``_rready)

  web888_core #(.ROM_FILE("../rtl/gen/sincos_qw.mem"), .BUILD_ID(32'h2026_1016)) dut (
    .adc_clk_p_i(adc_clk), .adc_clk_n_i(~adc_clk), .adc_dat_a_i(adc_dat), .adc_ofl_i(1'b0),
    .adc_pga_o(adc_pga), .adc_dith_o(adc_dith), .pps_i(pps), .antenna_o(antenna), .led_o(led),
    .ps_resetn(ps_resetn), .clk_out(clk_out), .irq(irq), .pps_gpio(pps_gpio),
    .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(4'd0), .s_axi_awsize(3'd2),
    .s_axi_awburst(2'b01), .s_axi_awlock(2'b00), .s_axi_awcache(4'd0), .s_axi_awprot(3'd0),
    .s_axi_awqos(4'd0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wid(awid), .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(1'b1),
    .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bid(bid), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(4'd0), .s_axi_arsize(3'd2),
    .s_axi_arburst(2'b01), .s_axi_arlock(2'b00), .s_axi_arcache(4'd0), .s_axi_arprot(3'd0),
    .s_axi_arqos(4'd0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rlast(rlast),
    .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    `HP_CONN(rx), `HP_CONN(wf0), `HP_CONN(wf1));

  `define HP_MEM(p, seed) \
    axi_mem_slave #(.SEED(seed), .NAME(`"p`")) p``_mem ( \
      .clk(clk_out), .awid(p``_awid), .awaddr(p``_awaddr), .awlen(p``_awlen), .awsize(p``_awsize), \
      .awburst(p``_awburst), .awvalid(p``_awvalid), .awready(p``_awready), .wdata(p``_wdata), \
      .wstrb(p``_wstrb), .wlast(p``_wlast), .wvalid(p``_wvalid), .wready(p``_wready), \
      .bid(p``_bid), .bresp(p``_bresp), .bvalid(p``_bvalid), .bready(p``_bready));
  `HP_MEM(rx, 11)
  `HP_MEM(wf0, 22)
  `HP_MEM(wf1, 33)

  // ---------------------------------------------------------------- GP0 BFM
  task gp_write(input [31:0] a, input [31:0] d, input [3:0] s);
    begin
      @(posedge clk_out);
      awaddr <= a; wdata <= d; wstrb <= s;
      awvalid <= 1; wvalid <= 1; bready <= 1;
      fork
        begin @(posedge clk_out); while (!awready) @(posedge clk_out); awvalid <= 0; end
        begin @(posedge clk_out); while (!wready)  @(posedge clk_out); wvalid  <= 0; end
      join
      while (!bvalid) @(posedge clk_out);
      @(posedge clk_out); bready <= 0;
    end
  endtask

  task gp_read(input [31:0] a, output [31:0] d);
    begin
      @(posedge clk_out);
      araddr <= a; arvalid <= 1; rready <= 1;
      @(posedge clk_out); while (!arready) @(posedge clk_out);
      arvalid <= 0;
      while (!rvalid) @(posedge clk_out);
      d = rdata;
      @(posedge clk_out); rready <= 0;
    end
  endtask

  // driver-style helpers
  localparam [31:0] CFG = 32'h4000_0000, STS = 32'h4100_0000, PPSF = 32'h4200_0000;

  task w32(input [31:0] off, input [31:0] d); gp_write(CFG + off, d, 4'hf); endtask
  task w16(input [31:0] off, input [15:0] d);   // strh
    gp_write(CFG + (off & ~3), {d, d} , off[1] ? 4'b1100 : 4'b0011);
  endtask
  task w8(input [31:0] off, input [7:0] d);     // strb
    gp_write(CFG + (off & ~3), {d, d, d, d}, 4'b0001 << off[1:0]);
  endtask
  task w32u(input [31:0] off, input [31:0] d);  // unaligned str, kernel fixup = 4 x strb
    begin w8(off, d[7:0]); w8(off+1, d[15:8]); w8(off+2, d[23:16]); w8(off+3, d[31:24]); end
  endtask
  task r32(input [31:0] a, output [31:0] d); gp_read(a, d); endtask

  function [47:0] phase_inc(input real f);
    real r, hi;
    begin
      r  = f / FS * 281474976710656.0;     // 2^48
      hi = $floor(r / 16777216.0);
      phase_inc = {$rtoi(hi), 24'd0} + $rtoi(r - hi * 16777216.0 + 0.5);
    end
  endfunction

  task set_rx_freq(input integer ch, input real f);
    reg [47:0] p;
    begin
      p = phase_inc(f);
      w32(4 + 8*ch, p[31:0]);
      w32(8 + 8*ch, {16'd0, p[47:32]});
    end
  endtask

  reg [31:0] ctrl_shadow = 0;
  task ctrl_set(input integer bitn, input integer val);
    begin
      if (val) ctrl_shadow = ctrl_shadow | (1 << bitn);
      else     ctrl_shadow = ctrl_shadow & ~(1 << bitn);
      w16(0, ctrl_shadow[15:0]);
    end
  endtask

  // ---------------------------------------------------------------- test
  integer errors = 0;
  reg [31:0] d, d2, d0;
  integer k;

  task check(input [8*48-1:0] what, input [31:0] got, input [31:0] exp);
    if (got !== exp) begin
      $display("FAIL %0s: got %h expected %h", what, got, exp);
      errors = errors + 1;
    end else
      $display("ok   %0s = %h", what, got);
  endtask

  initial begin
    $display("tb_core: start");
    repeat (10) @(posedge adc_clk);
    ps_resetn = 1;
    repeat (100) @(posedge clk_out);

    // identification (open(): signature, DNA after ~3.7k clocks)
    r32(STS + 0, d);   check("signature", d, {16'h0E5D, 8'h02, 8'(NRX)});
    repeat (4000) @(posedge clk_out);
    r32(STS + 32'h0c, d);  check("dna lo", d, 32'h6789_abcd);
    r32(STS + 32'h10, d);  check("dna hi", d, 32'h0001_2345);
    r32(STS + 32'h18, d);  check("build id", d, 32'h2026_1016);

    // GPIO (SET_GPIO_MASK / GET_GPIO_MASK)
    w32(32'h84, 32'h1c5);
    r32(CFG + 32'h84, d);  check("gpio readback", d, 32'h1c5);
    repeat (3) @(posedge clk_out);
    check("antenna_o", {26'd0, antenna}, 32'h05);
    check("dith/pga/led", {29'd0, adc_dith, adc_pga, led}, 32'h7);

    // RX: tune channels (RX_PARAM), RX_START(decim)
    set_rx_freq(0,  F1 - 1500.0);    // tone appears at +1500 Hz
    set_rx_freq(1,  F1 + 3000.0);    // -3000 Hz
    set_rx_freq(11, F2 - 500.0);     // +500 Hz
    for (k = 2; k < 11; k = k + 1) set_rx_freq(k, 1.0e6 * k);
    ctrl_set(0, 0);
    w16(2, RX_DECIM);
    w32(32'h8c, 32'h1000_0000);
    w8(32'h90, 8'hf7); w8(32'h91, 8'h0f);
    ctrl_set(0, 1);

    // PPS_START(1)
    ctrl_set(7, 0);
    ctrl_set(7, 1);

    // WF0: continuous, decim 4, tone at +1 MHz  (WF_PARAM + WF_START(0))
    w32(32'h6c, phase_inc(F1 - 1.0e6) & 32'hffffffff);
    w32(32'h70, {16'd0, phase_inc(F1 - 1.0e6) >> 32});
    w32(32'h74, 4);
    ctrl_set(1, 0);
    w32u(32'h92, 32'h1010_0000);
    w8(32'h96, 8'hf7); w8(32'h97, 8'h0f);
    w16(32'h9e, 16'h0000);                 // bit0 = 0: continuous (WF_READ_CONTINUES)
    ctrl_set(1, 1);

    // WF1: one-shot at decim 1 (full 122.88 MS/s burst), tone at +2 MHz
    w32(32'h78, phase_inc(F2 - 2.0e6) & 32'hffffffff);
    w32(32'h7c, {16'd0, phase_inc(F2 - 2.0e6) >> 32});
    w32(32'h80, 1);
    ctrl_set(2, 0);
    w32(32'h98, 32'h1020_0000);
    w8(32'h9c, 8'hf7); w8(32'h9d, 8'h0f);
    w16(32'h9e, 16'h0002);                 // bit1 = 1: one-shot (plain WF_START)
    ctrl_set(2, 1);

    // let it run
    k = 0;
    while (k < RX_FRAMES * NRX / 16) begin
      repeat (5000) @(posedge clk_out);
      r32(STS + 4, d);
      k = d[15:0];
    end

    r32(STS + 4, d);  r32(STS + 8, d2);
    $display("ptr: rx %0d wf0 %0d wf1 %0d, pps fifo %0d", d[15:0], d[31:16], d2[15:0], d2[31:16]);
    check("wf1 one-shot bursts", {16'd0, d2[15:0]}, 32'd256);
    r32(STS + 32'h20, d);
    check("overflow flags", d & 32'h7, 32'h0);

    // PPS_READ
    r32(STS + 8, d);
    if (d[31:16] == 0) begin $display("FAIL pps fifo empty"); errors = errors + 1; end
    r32(PPSF, d);   check("pps period", d, PPS_PERIOD);
    r32(STS + 32'h14, d); check("pps last", d, PPS_PERIOD);

    // AXI protocol errors seen by the memory models
    errors = errors + rx_mem.errors + wf0_mem.errors + wf1_mem.errors;

    rx_mem.dump("out/rx_mem.txt", 32'h1000_0000 >> 3, RX_FRAMES * NRX);
    wf0_mem.dump("out/wf0_mem.txt", 32'h1010_0000 >> 3, 4096);
    wf1_mem.dump("out/wf1_mem.txt", 32'h1020_0000 >> 3, 4096);

    // ------------------------------------------------------------ robustness
    // RX keeps running throughout; the ring must stay frame-aligned.
    r32(STS + 32'h30, d);  check("rx frames > 0", {31'd0, d != 0}, 32'd1);
    r32(STS + 32'h34, d);  check("rx drops", d, 32'd0);
    r32(STS + 32'h20, d);  check("error flags", d & 32'hffff_007f, 32'h0);

    // 1. ADC clock PLL unlock for 200 clocks
    force dut.pll_locked = 1'b0;
    repeat (200) @(posedge clk_out);
    release dut.pll_locked;
    repeat (20000) @(posedge clk_out);
    r32(CFG + 32'h8c, d);  check("cfg kept over unlock", d, 32'h1000_0000);
    r32(STS + 32'h20, d);  check("unlock count", d >> 16, 32'd1);

    // 2. corrupted token sequence at the backend output (one clock)
    @(posedge clk_out);
    while (!(dut.rx.ov && dut.rx.op == 5'd6)) @(posedge clk_out);
    #1 force dut.rx.op = 5'd9;
    @(posedge clk_out); #1 release dut.rx.op;
    repeat (20000) @(posedge clk_out);
    r32(STS + 32'h20, d);  check("rx seq_err flag", (d >> 3) & 1, 32'd1);

    // 3. HP port stall long enough to overflow the RX FIFO
    force rx_mem.wready = 1'b0;
    force rx_mem.awready = 1'b0;
    repeat (100000) @(posedge clk_out);
    release rx_mem.wready;
    release rx_mem.awready;
    repeat (20000) @(posedge clk_out);
    r32(STS + 32'h20, d);  check("rx overflow flag", d & 1, 32'd1);
    r32(STS + 32'h34, d);
    if (d == 0) begin $display("FAIL no frames dropped"); errors = errors + 1; end
    else $display("ok   rx frames dropped = %0d", d);
    r32(STS + 32'h20, d);  check("bresp errors", (d >> 4) & 7, 32'd0);
    check("still running", (d >> 10) & 1, 32'd1);

    // capture RX_FRAMES frames of the continuing stream
    r32(STS + 32'h38, d0);
    repeat ((RX_FRAMES + 8) * 256 * RX_DECIM + 20000) @(posedge clk_out);
    k = ((d0 * 16) / NRX + 4) * NRX;            // a frame boundary after d0
    rx_mem.dump_ring("out/rx_mem2.txt", 32'h1000_0000 >> 3, 16 * 4088, k, RX_FRAMES * NRX);
    errors = errors + rx_mem.errors;

    $display("tb_core: %0s (%0d errors)", errors ? "FAILED" : "PASSED", errors);
    $finish;
  end

endmodule
