// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// Fixed delay of D clock-enabled cycles: out = the `in` of D enabled
// cycles ago. Short delays are a shift register; long ones a RAM of
// D - 1 words with a registered read-first output (block RAM), which adds
// the last cycle.

module delay_line #(
  parameter integer W = 50,
  parameter integer D = 1024
) (
  input  wire         clk,
  input  wire         ce,
  input  wire [W-1:0] in,
  output wire [W-1:0] out
);

  generate
    if (D <= 32) begin : g_srl
      reg [W-1:0] sr [0:D-1];
      integer i;
      initial for (i = 0; i < D; i = i + 1) sr[i] = {W{1'b0}};
      always @(posedge clk)
        if (ce) begin
          sr[0] <= in;
          for (i = 1; i < D; i = i + 1) sr[i] <= sr[i-1];
        end
      assign out = sr[D-1];
    end else begin : g_ram
      localparam integer A = $clog2(D - 1);
      reg [W-1:0] mem [0:D-2];
      reg [W-1:0] q = {W{1'b0}};
      reg [A-1:0] ptr = {A{1'b0}};
      integer i;
      initial for (i = 0; i < D - 1; i = i + 1) mem[i] = {W{1'b0}};
      always @(posedge clk)
        if (ce) begin
          q        <= mem[ptr];   // read first: written D - 1 cycles ago
          mem[ptr] <= in;
          ptr      <= (ptr == D - 2) ? {A{1'b0}} : ptr + 1'b1;
        end
      assign out = q;
    end
  endgenerate

endmodule

`default_nettype wire
