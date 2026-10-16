// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps

// AXI3 write-only memory model for a PS7 HP port.
// Random W backpressure, fixed write-response latency, multiple outstanding
// addresses. Flags protocol errors (W data without an accepted address,
// wrong WLAST position, burst crossing 4 KB).

module axi_mem_slave #(
  parameter integer AW_WORDS = 16,     // memory = 2^AW_WORDS 64-bit words
  parameter integer B_LAT    = 24,
  parameter integer SEED     = 1,
  parameter         NAME     = "hp"
) (
  input  wire        clk,
  input  wire [5:0]  awid,
  input  wire [31:0] awaddr,
  input  wire [3:0]  awlen,
  input  wire [2:0]  awsize,
  input  wire [1:0]  awburst,
  input  wire        awvalid,
  output reg         awready,
  input  wire [63:0] wdata,
  input  wire [7:0]  wstrb,
  input  wire        wlast,
  input  wire        wvalid,
  output reg         wready,
  output reg  [5:0]  bid,
  output wire [1:0]  bresp,
  output reg         bvalid,
  input  wire        bready
);

  reg [63:0] mem [0:(1<<AW_WORDS)-1];
  integer i;
  initial for (i = 0; i < (1<<AW_WORDS); i = i + 1) mem[i] = 64'hdead_beef_dead_beef;

  assign bresp = 2'b00;

  // address queue
  reg [31:0] aq_addr [0:15];
  reg [3:0]  aq_len  [0:15];
  integer aq_wr = 0, aq_rd = 0;
  // response queue (release times)
  integer bq_t [0:63];
  integer bq_wr = 0, bq_rd = 0;
  integer cyc = 0, beat = 0, bursts = 0, errors = 0;
  reg [31:0] lfsr = SEED;

  initial begin awready = 1; wready = 0; bvalid = 0; bid = 0; end

  always @(posedge clk) begin
    cyc  = cyc + 1;
    lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

    if (awvalid && awready) begin
      if (awlen != 4'd15 || awsize != 3'd3 || awburst != 2'b01) begin
        $display("%s: ERROR unexpected burst shape len=%0d size=%0d burst=%0d", NAME, awlen, awsize, awburst);
        errors = errors + 1;
      end
      if ((awaddr & 32'hfff) > 32'hf80) begin
        $display("%s: ERROR burst crosses 4KB at %h", NAME, awaddr);
        errors = errors + 1;
      end
      aq_addr[aq_wr % 16] = awaddr;
      aq_len[aq_wr % 16]  = awlen;
      aq_wr = aq_wr + 1;
    end
    awready <= (aq_wr - aq_rd) < 15;

    if (wvalid && wready) begin
      if (aq_wr == aq_rd) begin
        $display("%s: ERROR W beat without accepted address", NAME);
        errors = errors + 1;
      end else begin
        mem[((aq_addr[aq_rd % 16] >> 3) + beat) & ((1<<AW_WORDS)-1)] = wdata;
        if (wlast != (beat == aq_len[aq_rd % 16])) begin
          $display("%s: ERROR WLAST mismatch at beat %0d", NAME, beat);
          errors = errors + 1;
        end
        if (beat == aq_len[aq_rd % 16]) begin
          beat = 0;
          aq_rd = aq_rd + 1;
          bursts = bursts + 1;
          bq_t[bq_wr % 64] = cyc + B_LAT;
          bq_wr = bq_wr + 1;
        end else begin
          beat = beat + 1;
        end
      end
    end
    wready <= (lfsr[2:0] != 3'd0);   // ~87 % accept rate

    if (bvalid && bready) begin
      bvalid <= 1'b0;
      bq_rd = bq_rd + 1;
    end else if (!bvalid && bq_rd != bq_wr && bq_t[bq_rd % 64] <= cyc) begin
      bvalid <= 1'b1;
    end
  end

  task dump(input [8*64-1:0] fname, input integer first, input integer nwords);
    integer f, k;
    begin
      f = $fopen(fname, "w");
      for (k = 0; k < nwords; k = k + 1)
        $fdisplay(f, "%016h", mem[(first + k) & ((1<<AW_WORDS)-1)]);
      $fclose(f);
    end
  endtask

  // Dump `nwords` consecutive stream words starting at stream word `first`
  // from a ring of `ring_words` words at word address `base` (wraps).
  task dump_ring(input [8*64-1:0] fname, input integer base, input integer ring_words,
                 input integer first, input integer nwords);
    integer f, k;
    begin
      f = $fopen(fname, "w");
      for (k = 0; k < nwords; k = k + 1)
        $fdisplay(f, "%016h", mem[(base + (first + k) % ring_words) & ((1<<AW_WORDS)-1)]);
      $fclose(f);
    end
  endtask

endmodule
