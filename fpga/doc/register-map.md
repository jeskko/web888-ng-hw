# Register map

Compatible with the stock `zynqsdr` kernel driver (firmware web-888-20260919),
see `../../docs/stock-driver.md` for how it was derived. All registers
are in the ADC clock domain, little endian, accessed through PS `M_AXI_GP0`.

| window | phys | size used by stock driver |
|---|---|---|
| CFG | 0x40000000 | 0xA0 |
| STS | 0x41000000 | 0x18 |
| PPS FIFO | 0x42000000 | 4 (read pops) |

CFG accepts byte/halfword writes (the driver uses `strb`/`strh`, and its
unaligned 32-bit store at 0x92 is split into bytes by the kernel's alignment
fix-up) and reads back what was written.

## CFG (read/write)

| offset | width | field |
|---|---|---|
| 0x00 | u16 | control: bit0 RX enable, bit1 WF0 enable, bit2 WF1 enable, bit7 PPS counter enable |
| 0x02 | u16 | RX stage-2 decimation R2 (1..63, driver 5..40); total RX decimation = 256·R2. Latched while RX is disabled |
| 0x04 + 8·ch | u64 | RX channel ch (0..12) NCO increment, f/fs·2^48 (bits 63:48 ignored) |
| 0x6C / 0x78 | u64 | WF0 / WF1 NCO increment |
| 0x74 / 0x80 | u32 | WF0 / WF1 decimation R (1..8192; power of two for exact gain) |
| 0x84 | u32 | GPIO: [5:0] antenna_o, 6 adc_dith_o, 7 adc_pga_o, 8 led_o |
| 0x8C | u32 | RX DMA ring physical address (128-byte aligned) |
| 0x90 | u16 | RX ring length − 1, in 128-byte bursts |
| 0x92 | u32 | WF0 ring address (unaligned) |
| 0x96 | u16 | WF0 ring length − 1 (bursts) |
| 0x98 | u32 | WF1 ring address |
| 0x9C | u16 | WF1 ring length − 1 (bursts) |
| 0x9E | u16 | WF mode, bit n for WF n: 1 = one-shot (256 bursts = 8192 samples, then stop), 0 = continuous ring |

A rising edge of an enable bit restarts that stream at ring offset 0 (after
any outstanding bursts drain), latching address/length/mode at that moment.

## STS (read only)

| offset | width | field |
|---|---|---|
| 0x00 | u32 | signature: [3:0] RX channels (hf build 12, vhf build 13, as stock; `NRX` ≤ 13), [7:4] 1 = the channelizer build (below; then 0 RX and 0 WF: 0x0E5D0010), [11:8] WF channels (2), [31:16] 0x0E5D = open design |
| 0x04 | u16 | RX ring write pointer (completed bursts) |
| 0x06 | u16 | WF0 ring write pointer |
| 0x08 | u16 | WF1 ring write pointer |
| 0x0A | u16 | PPS FIFO entries |
| 0x0C | u64 | device DNA (57 bit) |
| 0x14 | u32 | last PPS period (ADC clocks) |
| 0x18 | u32 | *ext*: build id (yyyymmdd as hex digits) |
| 0x1C | u32 | *ext*: ADC overflow counter (clocks with OVF high) |
| 0x20 | u32 | *ext*: flags, see below |
| 0x24 | u32 | *ext*: ADC peak |sample| over the last 2^24 clocks |
| 0x28 | u64 | *ext*: free-running ADC sample counter (restarts after a PLL relock) |
| 0x30 | u32 | *ext*: RX frames written (cleared on RX start) |
| 0x34 | u32 | *ext*: RX frames dropped whole on FIFO overflow (cleared on RX start) |
| 0x38 | u32 | *ext*: RX bursts completed, not wrapped (cleared on RX start) |
| 0x3C | u32 | *ext*: [15:0] WF0 bursts, [31:16] WF1 bursts (low 16 bits, cleared on start) |

Flags (0x20):

| bit | meaning |
|---|---|
| 0 / 1 / 2 | RX / WF0 / WF1 FIFO overflow (sticky until that stream restarts) |
| 3 | RX token-sequence error seen; the chain resynced itself (sticky until RX restart) |
| 4 / 5 / 6 | RX / WF0 / WF1 AXI write error response (sticky until restart) |
| 8 | ADC clock PLL locked |
| 9 | DNA valid |
| 10 / 11 / 12 | RX / WF0 / WF1 running |
| 31:16 | ADC clock PLL unlock events since power-on (saturating) |

### Wedge detection and recovery

The stock ring format has no sync markers, so losing one word would shift
every later frame and channels would decode as each other's I/Q (the stock
"static, tuning has no effect" failure). The open design guarantees frame
alignment instead:

* RX words enter the FIFO only as whole frames; on overflow a complete frame
  is dropped (0x34, flag 0).
* A PLL unlock resets only the DSP datapath. Registers, the AXI slave and the
  DMA masters keep running (no CFG loss, no half-finished AXI transactions),
  and the packer pads the interrupted frame with zeros.
* An out-of-order token inside the shared CIC resets the RX backend, pads the
  frame and resyncs on channel 0 (flag 3).

A server can detect a stall by checking that 0x30 or 0x38 keeps advancing
while RX runs (12 kHz: about 12 k frames/s).

*ext* registers are outside the window the stock driver maps; they are for an
open driver.

## PPS FIFO (0x42000000)

Each read returns the next PPS period (ADC clocks between consecutive PPS
rising edges) and removes it. Reads with STS 0x0A == 0 return 0. Rising edge
of CFG control bit7 clears the FIFO; the first PPS edge after that only
starts the count.

## Data formats

RX ring: per output sample, NRX little-endian 64-bit words `{Q[31:0], I[31:0]}`
for channels 0..NRX-1. Full-scale DC maps to ±2^30 regardless of R2; a full-scale
real sine gives |I+jQ| = 2^29. Mixing is x·e^(−jωn) (signal at f_nco+Δ appears
at +Δ).

WF ring: 32-bit samples `{Q[15:0], I[15:0]}`, two per 64-bit word (first
sample in the low half). Full-scale DC → ±2^15, independent of R. The first 8
samples after a (re)start are discarded internally (CIC settling).

## Interrupts (IRQ_F2P, unused by the stock driver)

| line | source |
|---|---|
| 0 | RX burst completed (1-clock pulse) |
| 1 | WF0 burst completed |
| 2 | WF1 burst completed |
| 3 | PPS rising edge |

EMIO GPIO 54 carries the raw PPS input for the kernel `pps-gpio` driver.

### WF mode polarity

CFG 0x9E bit n = 1 makes WF n one-shot: one block of 8192 samples (256
bursts), then the stream stops until the next enable edge. Bit n = 0
streams continuously around the ring. The stock driver means to clear the
bit for `WF_START | WF_READ_CONTINUES` (bit 16), but a bug makes it set the
bit for every `WF_START` (`docs/stock-driver.md`); the open driver honours
the flag. The stock server never passes the flag anyway and calls
`WF_START` again for every waterfall line (seen in the emulator), so it
relies on one-shot. Earlier
builds of this bitstream had the polarity inverted, and the stock server
then got a continuous stream: at decimation 1 that is 491 MB/s, more than
the HP port takes. Still to confirm against the stock bitstream on
hardware (`docs/hardware-test-plan.md`).

## The channelizer build (signature 0x0E5D0010)

`web888_core` with `PFB = 1` (`make pfb`, `websdr_pfb.bit`;
`docs/channelizer.md` §3.7) has the polyphase channelizer instead of the
RX and waterfall chains: 2048 bins of 30 kHz at 60 kS/s, at most 64 of
them selected per frame, and a full-band power line. The shared registers
keep their places (GPIO 0x84, PPS, DNA, build id, ADC monitors, flags);
the RX/WF fields read 0. Its bins ring goes out on HP0, its power line
ring on HP1; HP2 is idle. 122.88 MHz (HF) only.

CFG:

| off | width | field |
|---|---|---|
| 0xA0 | u16 | control: bit 0 bins on, bit 1 power line on, [7:4] gen request (the next frame uses the mask written since, and carries this gen) |
| 0xA4 | u32 | bins ring physical address (128-byte aligned) |
| 0xA8 | u16 | bins ring length − 1, in 128-byte bursts |
| 0xAA | u16 | frames per power line (summed |X|², e.g. 20: 3000 lines a second) |
| 0xAC | u32 | power ring physical address |
| 0xB0 | u16 | power ring length − 1, in bursts |

The mask: the EV window, base + 0x3000000 (0x43000000), 64 words written
one at a time; bit b of word w selects bin 32w + b (bin 2047 can't be
selected). Writes go to the bank not in use; then a new gen in 0xA0
switches banks at the next frame. Reads of the window return 0.

STS:

| off | width | field |
|---|---|---|
| 0x40 | u32 | [15:0] bins ring write pointer (bursts done), [31:16] power ring pointer |
| 0x44 | u32 | [3:0] gen in use, 4 truncated (more than 64 set), 5 bins overflow, 6 bins bresp error, 7 power overflow, 8 power bresp error |
| 0x48 | u32 | bin frames written |
| 0x4C | u32 | bin frames dropped (no room in the ring) |
| 0x50 | u32 | power chunks written (16 a line) |
| 0x54 | u32 | power chunks dropped |

Frames in the rings (64-bit words, little-endian; a frame is written whole
or dropped whole):

* bins: header `{0x5042, 1, gen[3:0], 0[7:0], frame[31:0]}`, then each
  selected bin, lowest first, `{Q[31:0], I[31:0]}` (I low; a full-scale
  sine reads 2^29).
* power: per line 16 chunks, each a header `{0x5042, 2, chunk[3:0],
  0[7:0], line[31:0]}` and 64 words `{f32[2j+1], f32[2j]}` (bins 128c ..
  128c + 127, the even bin low; IEEE float32, mantissa truncated).

Interrupts: IRQ_F2P[0] a bins burst written, [1] a power burst written,
[3] PPS edge.
