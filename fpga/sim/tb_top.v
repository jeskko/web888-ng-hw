// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// The channelizer with its DMA (pfb_top), ADC samples to DDR: vectors/
// adc.hex in, both rings in AXI memory models (random backpressure), then
// read back as software would and compared with the model:
// * bins: seven selected bins of the two frames (headers, then {Q, I} =
//   bins.hex << 5), sixteen words, one burst
// * power: one line of the two frames, sixteen chunks (power.hex)

module tb_top;
  localparam integer W = 25, N = 2048, NS = 47104, VF = 2, NB = 7;
  localparam integer PW_BASE = 32'h0001_0000;   // the power ring (bytes)

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
            .SPLIT_FILE("../rtl/gen/pfb_split_tw.mem")) dut (
    .clk(clk), .rst(rst), .adc(adc_in),
    .bins_enable(bins_en), .mask_we(mask_we), .mask_addr(mask_addr), .mask_data(mask_data),
    .gen_req(gen_req), .gen(gen), .truncated(truncated),
    .bins_addr(32'd0), .bins_len_m1(16'd63), .bins_ptr(bins_ptr), .bins_overflow(bins_ovf),
    .bins_frames(bins_frames), .bins_drops(bins_drops), .bins_bresp_err(bins_berr),
    .power_enable(power_en), .power_frames(16'd2), .power_addr(PW_BASE), .power_len_m1(16'd127),
    .power_ptr(power_ptr), .power_overflow(power_ovf), .power_frames_out(power_frames_out),
    .power_drops(power_drops), .power_bresp_err(power_berr),
    `AXI_PORTS(bn),
    `AXI_PORTS(pw));

`define MEM(p, seed) \
  axi_mem_slave #(.SEED(seed), .NAME(`"p`")) p``_mem ( \
    .clk(clk), .awid(p``_awid), .awaddr(p``_awaddr), .awlen(p``_awlen), .awsize(p``_awsize), \
    .awburst(p``_awburst), .awvalid(p``_awvalid), .awready(p``_awready), .wdata(p``_wdata), \
    .wstrb(p``_wstrb), .wlast(p``_wlast), .wvalid(p``_wvalid), .wready(p``_wready), \
    .bid(p``_bid), .bresp(p``_bresp), .bvalid(p``_bvalid), .bready(p``_bready));
  `MEM(bn, 5)
  `MEM(pw, 6)

  // ADC samples from the first clock (the chain runs through reset; its
  // frames start with its first sample, as the vectors')
  integer t = 0;
  always @(posedge clk) t <= t + 1;
  wire signed [15:0] adc_in = (t < NS) ? adc_v[t] : 16'sd0;

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
    if (errors == 0) $display("tb_top: PASSED (ADC to DDR: %0d bin frames, a power line)", VF);
    else $display("tb_top: FAILED (%0d errors)", errors);
    $finish;
  end

  initial begin
    #2_000_000;
    $display("tb_top: FAILED (timeout: bins ptr %0d, power ptr %0d)", bins_ptr, power_ptr);
    $finish;
  end

endmodule

`default_nettype wire
