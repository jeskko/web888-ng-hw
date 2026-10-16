# 64 MHz-bandwidth instability (stock 13-channel HF bitstream)

Sources: RaspSDR/server issues
[#22](https://github.com/RaspSDR/server/issues/22),
[#32](https://github.com/RaspSDR/server/issues/32),
[#58](https://github.com/RaspSDR/server/issues/58) (Oct–Nov 2024).

## Symptom

- Only with the 64 MHz bandwidth (ADC 122.88 MHz, HF bitstream, then
  13 RX channels). The 32 MHz setting (61.44 MHz, VHF bitstream) was stable on the
  same boards.
- Hits after 30 min to about 7 h, even with the receiver idle (it's not caused
  by FT8 load). Afterwards, retuning has no effect and the audio is a constant
  static, apparently from the last frequency. The server log shows nothing,
  and its tasks and connections look normal (the AXI register path still
  answers; Linux keeps running).
- Board-dependent: only some units. Power supplies and cables were ruled
  out (#32). The vendor first could not reproduce it, and later marked #22 resolved by the new firmware.
- Vendor fix (firmware 20241113; #58 points to the rx-888.com release notes):
  the HF bitstream drops to **12 channels** "for better overall stability"
  (VHF / 32 MHz keeps 13). The current HF bitstream (built 2025-04-13) reports
  `0xAA55020C`.

## Reading

The pattern fits a **marginal-timing (or CDC/reset) failure in the PL datapath
at 122.88 MHz**. It depends on the board, presumably on temperature, and it
goes away at half the clock or with less logic. Once wedged, the
DDC/DMA path no longer reflects NCO writes. It doesn't look like a PS or
software failure. Unknown: whether the vendor's 13-ch build closed timing at
all (Vivado writes bitstreams with negative slack).

## A concrete mechanism: frame slip

The RX ring is a bare stream of NRX-word frames with no sync markers, and the
server deinterleaves by counting. If a DMA engine ever drops or duplicates a
single word (FIFO overflow under HP-port congestion, a datapath reset
mid-frame, a TDM slot glitch), every later frame is shifted. Channels then
decode as each other's I/Q: you hear static, and retuning "your" channel
changes nothing you can hear. That's exactly the reported symptom, and it
never recovers until RX is restarted. Whether the vendor engine drops single
words is unknown. Our first draft did (`axi_ring_writer` dropped per word on
overflow).

## Done in the open FPGA (2026-10-16)

1. **Frame-atomic RX ring.** Words are admitted only as whole frames, so
   overflow drops complete frames (STS 0x34, flag 0).
2. **Reset split.** A PLL unlock resets only the DSP datapath. CFG, the AXI
   slave and the DMA masters run on the PS reset, so there's no config loss and
   no half-finished AXI transaction. The packer zero-pads the interrupted frame.
3. **Self-resync** on an out-of-order token in the shared CIC (flag 3).
4. **Diagnostics**: frames/drops/bursts counters (0x30..0x3C), sticky AXI
   error flags, and a PLL unlock counter (flags[31:16]). A server can watch
   0x30 to detect a stall.
5. **Guardband**: extra setup uncertainty of 0.4 ns (HF: effectively
   131.6 MHz, +7 % over 122.88 MHz) and 0.5 ns (VHF: 117.6 MHz, +6.4 % over
   110.592 MHz), closed with WNS +0.058 / +0.718 ns. Fixes needed for HF:
   registered and replicated AXI write data into CFG, per-channel ADC copies
   for the mixers, and a registered WF integrator input. The remaining limiter is the
   62-bit LUTRAM read-modify-write in the shared RX CIC2 integrator.

`make sim` injects all three faults into a running stream: a 200-clock PLL
unlock, a corrupted token, and a 100 k-clock HP stall that drops 36 frames.
A capture of the continuing stream then still decodes every test channel at
exact level. With per-word drops (the old behaviour) the same capture fails
by 125–150 dB.

## Still to do

* **Stress test** on a board known to show the stock failure (it reproduced
  within hours with the 13-ch HF bitstream), including 13 ch at 122.88 MHz.
* An open driver/server should use the 0x30 counter as a watchdog and
  re-arm RX on a stall.
