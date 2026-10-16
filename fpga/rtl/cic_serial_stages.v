// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// Time-multiplexed CIC building blocks. Each token carries a path index;
// per-path state lives in distributed RAM. A path must not reappear within
// the pipeline depth of one stage (always true here: paths recur every
// >= 256 clocks).

// Comb: y = x - x_prev[path]
module cic_serial_comb #(
  parameter integer W  = 36,
  parameter integer PW = 5
) (
  input  wire                clk,
  input  wire                rst,
  input  wire                in_valid,
  input  wire [PW-1:0]       in_path,
  input  wire signed [W-1:0] in_data,
  output reg                 out_valid,
  output reg  [PW-1:0]       out_path,
  output reg  signed [W-1:0] out_data
);

  reg [W-1:0] mem [0:(1<<PW)-1];
  integer i;
  initial for (i = 0; i < (1<<PW); i = i + 1) mem[i] = 0;

  always @(posedge clk) begin
    out_valid <= in_valid && !rst;
    out_path  <= in_path;
    if (in_valid) begin
      out_data     <= in_data - $signed(mem[in_path]);
      mem[in_path] <= in_data;
    end
  end

endmodule

// Integrator: acc[path] += x; y = updated acc
module cic_serial_integrator #(
  parameter integer W  = 62,
  parameter integer PW = 5
) (
  input  wire                clk,
  input  wire                rst,
  input  wire                in_valid,
  input  wire [PW-1:0]       in_path,
  input  wire signed [W-1:0] in_data,
  output reg                 out_valid,
  output reg  [PW-1:0]       out_path,
  output reg  signed [W-1:0] out_data
);

  reg [W-1:0] mem [0:(1<<PW)-1];
  integer i;
  initial for (i = 0; i < (1<<PW); i = i + 1) mem[i] = 0;

  wire signed [W-1:0] sum = $signed(mem[in_path]) + in_data;

  always @(posedge clk) begin
    out_valid <= in_valid && !rst;
    out_path  <= in_path;
    if (in_valid) begin
      out_data     <= sum;
      mem[in_path] <= sum;
    end
  end

endmodule

`default_nettype wire
