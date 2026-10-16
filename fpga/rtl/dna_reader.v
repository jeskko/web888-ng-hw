// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// Reads the 57-bit device DNA once after reset.
// Bit order follows red-pitaya-notes dna_reader (first bit shifted out of
// DNA_PORT ends up in dna[56]). The stock zynqsdr driver derives the
// "genuine" MAC from this value, so the order must match the vendor
// bitstream -- verify on hardware by comparing GET_DNA results.

module dna_reader (
  input  wire        clk,
  input  wire        rst,
  output reg  [56:0] dna,
  output reg         valid
);

  // DNA_PORT clock = clk / 64 (< 100 MHz requirement with lots of margin)
  reg [5:0] div;
  reg       dclk, dread, dshift;
  reg [6:0] nbits;
  reg [1:0] state;
  wire      dout;

  DNA_PORT #(.SIM_DNA_VALUE(57'h1_2345_6789_abcd)) dna_port (
    .DOUT(dout), .CLK(dclk), .DIN(1'b0), .READ(dread), .SHIFT(dshift));

  localparam S_READ = 2'd0, S_SHIFT = 2'd1, S_DONE = 2'd2;

  always @(posedge clk) begin
    if (rst) begin
      div    <= 6'd0;
      dclk   <= 1'b0;
      dread  <= 1'b1;
      dshift <= 1'b0;
      nbits  <= 7'd0;
      state  <= S_READ;
      valid  <= 1'b0;
      dna    <= 57'd0;
    end else begin
      div <= div + 1'b1;
      if (div == 6'd31) dclk <= 1'b1;   // rising edge of DNA clock
      if (div == 6'd63) dclk <= 1'b0;
      case (state)
        S_READ:
          if (div == 6'd31)             // READ is sampled on this edge
            state <= S_SHIFT;
        S_SHIFT:
          if (div == 6'd16) begin       // mid low phase: DOUT is stable
            dread  <= 1'b0;
            dna    <= {dna[55:0], dout};
            nbits  <= nbits + 1'b1;
            dshift <= (nbits != 7'd56);
            if (nbits == 7'd56) begin
              state <= S_DONE;
              valid <= 1'b1;
            end
          end
        default: ;
      endcase
    end
  end

endmodule

`default_nettype wire
