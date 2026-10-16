// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// Synchronous FIFO, first-word-fall-through output.
// Storage is inferred as block RAM (large AW) or distributed RAM (small AW).
// Writes while full are dropped (caller watches `full`).

module sync_fifo #(
  parameter integer W  = 64,
  parameter integer AW = 9
) (
  input  wire          clk,
  input  wire          rst,

  input  wire [W-1:0]  wdata,
  input  wire          wvalid,
  output wire          full,

  output reg  [W-1:0]  rdata,
  output reg           rvalid,
  input  wire          rready,

  output wire [AW:0]   count
);

  reg [W-1:0] mem [0:(1<<AW)-1];
  reg [AW:0]  wptr, rptr;

  wire [AW:0] used  = wptr - rptr;
  wire        empty = (used == 0);
  wire        pop   = !empty && (!rvalid || rready);

  assign full  = used[AW];
  assign count = used + {{AW{1'b0}}, rvalid};

  always @(posedge clk) begin
    if (wvalid && !full)
      mem[wptr[AW-1:0]] <= wdata;
    if (pop)
      rdata <= mem[rptr[AW-1:0]];
  end

  always @(posedge clk) begin
    if (rst) begin
      wptr   <= 0;
      rptr   <= 0;
      rvalid <= 1'b0;
    end else begin
      if (wvalid && !full)
        wptr <= wptr + 1'b1;
      if (pop) begin
        rptr   <= rptr + 1'b1;
        rvalid <= 1'b1;
      end else if (rready) begin
        rvalid <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
