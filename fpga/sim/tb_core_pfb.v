// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps

// The channelizer build of web888_core (PFB = 1) through its registers:
// the signature, the bin mask through the EV window and its gen, the bins
// ring on HP0 and the power line ring on HP1, the STS counters and the
// interrupts. A 3.0 MHz tone must show in bin 100 (30 kHz bins) in both
// streams. The datapath's values are tb_top's (bit-exact to the model).

module tb_core_pfb;

  localparam real FS     = 122.88e6;
  localparam real TCLK   = 1.0e9 / FS;
  localparam real F1     = 3.0e6;        // bin 100, -12 dBFS
  localparam integer PPS_PERIOD = 100000;

  // ---------------------------------------------------------------- clocks
  reg adc_clk = 0;
  always #(TCLK/2) adc_clk = ~adc_clk;

  // ADC: offset binary, data changes on falling edge
  reg  [15:0] adc_dat = 16'h8000;
  integer n = 0;
  real    v;
  integer vi;
  always @(negedge adc_clk) begin
    v  = 8192.0 * $sin(6.283185307179586 * F1 * n / FS);
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
  wire [7:0]  emio_gpio;
  assign pps_gpio = emio_gpio[0];
  reg         fclk = 0;
  always #10 fclk = ~fclk;   // 50 MHz
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

  web888_core #(.ROM_FILE("../rtl/gen/sincos_qw.mem"), .BUILD_ID(32'h2026_1029),
                .PFB(1), .PFB_COEF_PREFIX("../rtl/gen/pfb_coef_"),
                .PFB_TW_PREFIX("../rtl/gen/pfb_tw_"),
                .PFB_SPLIT_FILE("../rtl/gen/pfb_split_tw.mem")) dut (
    .adc_clk_p_i(adc_clk), .adc_clk_n_i(~adc_clk), .adc_dat_a_i(adc_dat), .adc_ofl_i(1'b0),
    .adc_pga_o(adc_pga), .adc_dith_o(adc_dith), .pps_i(pps), .antenna_o(antenna), .led_o(led),
    .ps_resetn(ps_resetn), .clk_out(clk_out), .irq(irq), .emio_gpio(emio_gpio), .fclk(fclk),
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

  // ---------------------------------------------------------------- test
  localparam [31:0] EV = 32'h4300_0000;
  localparam integer PW_BASE = 32'h0001_0000;     // power ring (byte address)
  integer errors = 0;
  integer i, f, irq_bins = 0, irq_power = 0;
  reg [31:0] d;
  reg [63:0] w;

  always @(posedge clk_out) begin
    if (irq[0]) irq_bins = irq_bins + 1;
    if (irq[1]) irq_power = irq_power + 1;
  end

  task check(input [8*40-1:0] what, input [31:0] got, input [31:0] want);
    begin
      if (got !== want) begin
        $display("FAIL %0s = %h, want %h", what, got, want);
        errors = errors + 1;
      end else
        $display("ok   %0s = %h", what, got);
    end
  endtask

  // the whole mask: bins b0, b1, b2 (-1: none)
  task set_mask(input integer b0, input integer b1, input integer b2, input [3:0] gen);
    reg [31:0] m;
    begin
      for (i = 0; i < 64; i = i + 1) begin
        m = 0;
        if (b0 >= 0 && b0 / 32 == i) m = m | (32'd1 << (b0 % 32));
        if (b1 >= 0 && b1 / 32 == i) m = m | (32'd1 << (b1 % 32));
        if (b2 >= 0 && b2 / 32 == i) m = m | (32'd1 << (b2 % 32));
        gp_write(EV + 4*i, m, 4'hf);
      end
      w32(32'ha0, {8'd0, gen, 2'b0, 2'b11});        // bins + power on, gen_req
    end
  endtask

  // |{Q, I}| of a bin word, roughly (max of the parts)
  function [31:0] mag(input [63:0] x);
    reg [31:0] a, b;
    begin
      a = x[31] ? -x[31:0] : x[31:0];
      b = x[63] ? -x[63:32] : x[63:32];
      mag = a > b ? a : b;
    end
  endfunction

  // f32 bits as a real (normal numbers)
  function real f32(input [31:0] b);
    begin
      f32 = (b[30:23] == 0) ? 0.0
          : (b[31] ? -1.0 : 1.0) * (1.0 + b[22:0] / 8388608.0) * (2.0 ** (b[30:23] - 127));
    end
  endfunction

  integer hdr, nb, gen2_at;
  real p100, p2;
  initial begin
    repeat (20) @(posedge adc_clk);
    ps_resetn = 1;
    while (dut.rst) @(posedge clk_out);
    repeat (10) @(posedge clk_out);

    r32(STS + 32'h00, d); check("signature", d, 32'h0E5D0010);
    r32(STS + 32'h18, d); check("build id", d, 32'h20261029);
    r32(EV, d);           check("ev window reads 0", d, 0);

    // rings: bins at 0 (64 bursts), power at PW_BASE (2048 bursts: no wrap
    // in this test), a power line every 2 frames
    w32(32'ha4, 32'd0);
    w32(32'ha8, {16'd2, 16'd63});
    w32(32'hac, PW_BASE);
    w32(32'hb0, 32'd2047);
    set_mask(1, 100, 2046, 4'd1);
    r32(CFG + 32'ha8, d); check("cfg 0xa8 readback", d, {16'd2, 16'd63});

    // the chain's latency (its history: 23 blocks of 2048 samples) and a
    // few frames
    repeat (2048 * 32) @(posedge clk_out);
    r32(STS + 32'h44, d); check("gen 1, no flags", d, 32'h1);
    r32(STS + 32'h48, d); check("bins frames > 3", d > 3, 1);
    r32(STS + 32'h4c, d); check("bins drops", d, 0);
    r32(STS + 32'h50, d); check("power chunks >= 16", d >= 16, 1);
    r32(STS + 32'h54, d); check("power drops", d, 0);
    r32(STS + 32'h40, d); check("both ring pointers moved", d[15:0] != 0 && d[31:16] != 0, 1);

    // bins: header, then bins 1, 100, 2046 (4 words a frame, no wrap yet);
    // the last two whole frames before the pointer (the first ones carry
    // the simulation's uninitialised FIR history)
    r32(STS + 32'h40, d);
    hdr = (d[15:0] * 16 / 4 - 2) * 4;
    w = rx_mem.mem[hdr];
    check("bins header magic/type/gen", w[63:40], {16'h5042, 4'd1, 4'd1});
    check("bin 100 > 30x bin 1", mag(rx_mem.mem[hdr + 2]) > 30 * mag(rx_mem.mem[hdr + 1]), 1);
    check("bin 100 > 30x bin 2046", mag(rx_mem.mem[hdr + 2]) > 30 * mag(rx_mem.mem[hdr + 3]), 1);
    w = rx_mem.mem[hdr + 4];
    check("next header", w[63:40], {16'h5042, 4'd1, 4'd1});
    check("frame count steps", w[31:0], rx_mem.mem[hdr][31:0] + 1);

    // power line: 16 chunks of a header and 64 words; bin 100 in chunk 0,
    // word 1 + 50, the even bin low. The second line in the ring (the
    // first may carry the uninitialised history).
    hdr = PW_BASE / 8 + 1040;
    w = wf0_mem.mem[PW_BASE / 8];
    check("power ring starts with chunk 0", w[63:40], {16'h5042, 4'd2, 4'd0});
    nb = 0;
    for (f = 0; f < 16; f = f + 1) begin
      w = wf0_mem.mem[hdr + f * 65];
      if (w[63:44] !== {16'h5042, 4'd2} || w[43:40] !== f[3:0]) begin
        $display("FAIL power chunk %0d header %h", f, w);
        nb = nb + 1;
      end
    end
    check("power line: bad chunk headers", nb, 0);
    p100 = f32(wf0_mem.mem[hdr + 1 + 50][31:0]);
    p2   = f32(wf0_mem.mem[hdr + 1 + 1][31:0]);
    $display("     power bin 100 %g, bin 2 %g", p100, p2);
    check("power bin 100 > 1000x bin 2", p2 > 0.0 && p100 > 1000.0 * p2, 1);

    // a new mask: bin 100 alone, gen 2
    set_mask(100, -1, -1, 4'd2);
    repeat (2048 * 6) @(posedge clk_out);
    r32(STS + 32'h44, d); check("gen 2", d[3:0], 4'd2);
    // find a gen-2 frame in the ring: a header followed by one bin
    gen2_at = -1;
    for (hdr = 0; hdr < 1024 - 2 && gen2_at < 0; hdr = hdr + 1) begin
      w = rx_mem.mem[hdr];
      if (w[63:40] === {16'h5042, 4'd1, 4'd2}) gen2_at = hdr;
    end
    check("a gen-2 frame in the ring", gen2_at >= 0, 1);
    if (gen2_at >= 0) begin
      w = rx_mem.mem[gen2_at + 2];
      check("gen-2 frame has one bin", w[63:40], {16'h5042, 4'd1, 4'd2});
      check("its bin is the tone", mag(rx_mem.mem[gen2_at + 1]) > 1000, 1);
    end

    check("bins interrupts", irq_bins > 0, 1);
    check("power interrupts", irq_power > 0, 1);
    r32(STS + 32'h20, d); check("no RX/WF running", d[12:10], 0);

    if (errors == 0) $display("tb_core_pfb: PASSED");
    else             $display("tb_core_pfb: FAILED (%0d errors)", errors);
    $finish;
  end

endmodule
