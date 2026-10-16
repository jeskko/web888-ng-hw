// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// Counts ADC clocks between GPS PPS rising edges.
// Each complete period is pushed into a small FIFO (read by PPS_READ through
// the hub) and kept in `last`. A rising edge of `en` (PPS_START) clears the
// FIFO; the first edge after that only starts the measurement.

module pps_counter (
  input  wire        clk,
  input  wire        rst,
  input  wire        en,
  input  wire        pps_in,       // asynchronous

  output wire [31:0] fifo_data,
  output wire        fifo_valid,
  input  wire        fifo_pop,
  output wire [15:0] fifo_count,
  output reg  [31:0] last,
  output wire        edge_pulse
);

  (* ASYNC_REG = "TRUE" *) reg [2:0] sync;
  always @(posedge clk) sync <= {sync[1:0], pps_in};
  assign edge_pulse = sync[1] && !sync[2];

  reg        en_d, armed;
  reg [31:0] cnt;
  reg        push;
  reg [31:0] push_val;

  always @(posedge clk) begin
    push <= 1'b0;
    en_d <= en;
    if (rst || !en) begin
      armed <= 1'b0;
      cnt   <= 32'd0;
    end else begin
      cnt <= cnt + 1'b1;
      if (edge_pulse) begin
        if (armed) begin
          push     <= 1'b1;
          push_val <= cnt + 1'b1;   // clocks from previous edge to this one
          last     <= cnt + 1'b1;
        end
        armed <= 1'b1;
        cnt   <= 32'd0;
      end
    end
  end

  wire [4:0] cnt_w;
  sync_fifo #(.W(32), .AW(4)) fifo (
    .clk(clk), .rst(rst || (en && !en_d)),
    .wdata(push_val), .wvalid(push), .full(),
    .rdata(fifo_data), .rvalid(fifo_valid), .rready(fifo_pop),
    .count(cnt_w));

  assign fifo_count = {11'd0, cnt_w};

endmodule

`default_nettype wire
