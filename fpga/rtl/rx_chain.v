// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1 ns / 1 ps
`default_nettype none

// Complete RX DDC: front end + shared CIC back end + frame packer.
// Output: one 64-bit word {Q, I} per channel per output sample, channel
// order 0..NCH-1 (little endian: I at the lower address), matching the
// server's `s32 I, s32 Q` interleaved frame layout.
//
// `en` low: R2 is (re)latched, decimation phase and packer are reset.
// After `en` rises the first word emitted is channel 0 of a complete frame.
//
// Output is always whole frames of NCH words, even across a datapath reset
// (`dp_rst`, e.g. ADC clock PLL relock) or an internal token-sequence error:
// the packer then pads the open frame with zero words and resyncs on the
// next channel-0 token, so the ring never loses frame alignment.
// `seq_err` is sticky until `en` falls; `resyncs` counts recoveries.

module rx_chain #(
  parameter integer NCH      = 12,
  parameter         ROM_FILE = "sincos_qw.mem"
) (
  input  wire              clk,
  input  wire              rst,       // bus-level reset (packer, counters)
  input  wire              dp_rst,    // datapath reset (DDC state)
  input  wire              en,
  input  wire signed [15:0] adc,
  input  wire [NCH*48-1:0] inc,
  input  wire [15:0]       decim,     // CFG 0x02: stage-2 decimation (total x256)

  output reg               m_valid,
  output reg  [63:0]       m_data,
  output reg               seq_err,
  output reg  [15:0]       resyncs
);

  localparam integer NP = 2 * NCH;
  localparam integer WW = $clog2(NCH + 1);

  reg [5:0] r2;
  always @(posedge clk)
    if (!en) r2 <= (decim == 0) ? 6'd1 : (decim > 63) ? 6'd63 : decim[5:0];

  wire              tv;
  wire [4:0]        tp;
  wire signed [35:0] td;

  // backend reset: datapath reset, RX stopped, or a resync request
  reg  [2:0] resync_hold;
  wire       be_rst = rst || dp_rst || !en || (resync_hold != 0);

  rx_frontend #(.NCH(NCH), .ROM_FILE(ROM_FILE)) fe (
    .clk(clk), .rst(rst || dp_rst), .adc(adc), .inc(inc),
    .tok_valid(tv), .tok_path(tp), .tok_data(td));

  wire              ov;
  wire [4:0]        op;
  wire signed [31:0] od;

  rx_serial_cic #(.NPATH(NP)) be (
    .clk(clk), .rst(be_rst), .r2(r2),
    .in_valid(tv), .in_path(tp), .in_data(td),
    .out_valid(ov), .out_path(op), .out_data(od));

  // packer: wait for path 0, then pair I/Q into 64-bit words.
  // wcnt = words emitted in the current frame; exp = next expected path.
  reg        synced;
  reg [31:0] ihold;
  reg [WW-1:0] wcnt;
  reg [4:0]  exp;
  wire       pad = (wcnt != 0) && !synced;   // finish an interrupted frame

  always @(posedge clk) begin
    m_valid <= 1'b0;
    if (resync_hold != 0) resync_hold <= resync_hold - 1'b1;
    if (rst || !en) begin
      synced      <= 1'b0;
      wcnt        <= 0;
      exp         <= 5'd0;
      seq_err     <= 1'b0;
      resync_hold <= 3'd0;
      if (rst) resyncs <= 16'd0;
    end else if (pad) begin
      m_data  <= 64'd0;
      m_valid <= 1'b1;
      wcnt    <= (wcnt == NCH - 1) ? {WW{1'b0}} : wcnt + 1'b1;
    end else if (dp_rst) begin
      synced <= 1'b0;
      exp    <= 5'd0;
    end else if (ov) begin
      if (synced && op != exp) begin
        // token out of order: drop sync, reset the backend, pad, resync
        synced      <= 1'b0;
        exp         <= 5'd0;
        seq_err     <= 1'b1;
        resyncs     <= resyncs + 1'b1;
        resync_hold <= 3'd7;
      end else if (synced || op == 0) begin
        synced <= 1'b1;
        exp    <= (op == NP - 1) ? 5'd0 : op + 1'b1;
        if (!op[0]) begin
          ihold <= od;
        end else begin
          m_data  <= {od, ihold};
          m_valid <= 1'b1;
          wcnt    <= (wcnt == NCH - 1) ? {WW{1'b0}} : wcnt + 1'b1;
        end
      end
    end
  end

endmodule

`default_nettype wire
