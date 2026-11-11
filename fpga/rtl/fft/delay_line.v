// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// Fixed delay of D clock-enabled cycles: out = the `in` of D enabled
// cycles ago. Short delays are a shift register; long ones a RAM of
// D - 1 words with a registered read-first output, which adds the last
// cycle; from BLOCK_MIN on in block RAM.

module delay_line #(
  parameter integer W = 50,
  parameter integer D = 1024,
  parameter integer BLOCK_MIN = 500
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
      // BLOCK_MIN words and more pinned to block RAM (synthesis otherwise
      // puts them in LUT RAM)
      localparam integer A = $clog2(D - 1);
      reg [W-1:0] q = {W{1'b0}};
      reg [A-1:0] ptr = {A{1'b0}};
      integer i;
      if (D >= BLOCK_MIN) begin : g_block
        (* ram_style = "block" *) reg [W-1:0] mem [0:D-2];
        initial for (i = 0; i < D - 1; i = i + 1) mem[i] = {W{1'b0}};
        always @(posedge clk)
          if (ce) begin
            q        <= mem[ptr];   // read first: written D - 1 cycles ago
            mem[ptr] <= in;
          end
      end else begin : g_auto
        reg [W-1:0] mem [0:D-2];
        initial for (i = 0; i < D - 1; i = i + 1) mem[i] = {W{1'b0}};
        always @(posedge clk)
          if (ce) begin
            q        <= mem[ptr];
            mem[ptr] <= in;
          end
      end
      always @(posedge clk)
        if (ce) ptr <= (ptr == D - 2) ? {A{1'b0}} : ptr + 1'b1;
      assign out = q;
    end
  endgenerate

endmodule

`default_nettype wire
