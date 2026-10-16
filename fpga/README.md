# Web-888 open FPGA

An open-source replacement for the closed `websdr_hf.bit` / `websdr_vhf.bit`
bitstreams of the Web-888 SDR (Zynq XC7Z010-1CLG400 + LTC2208 16-bit ADC).

It implements the same hardware contract as the vendor design, so it runs
under the **stock firmware and stock `zynqsdr` kernel driver**: copy
`build/hf/websdr_hf.bit` over `/media/mmcblk0p1/websdr_hf.bit` and restart
the server. The contract was recovered from the open server code and the
driver (see `../docs/`), and is documented in `doc/register-map.md`.

**Status: draft.** Simulated and built with Vivado 2026.1 (timing met);
not yet run on hardware.

## Architecture

```
               ┌──────────────── ADC clock domain (122.88 MHz) ─────────────────┐
LTC2208 ─IOB─▶ │ 12 × [NCO ─ mixer ─ CIC1 int (N3)] ─▶ staggered ↓256 sampler    │
               │        └─▶ shared serial CIC: comb1 ─ int2 (N5) ─ ↓R2 ─ comb2 ─ gain ─▶ ring DMA ─▶ HP0
               │ 2 × [NCO ─ mixer ─ CIC N5, R=1..8192, gain-tracking window] ─▶ ring DMA ─▶ HP1/HP2
               │ AXI3 register hub (CFG/STS/PPS FIFO) ◀─ GP0                     │
               │ PPS counter, DNA reader, GPIO, ADC monitors                     │
               └─────────────────────────────────────────────────────────────────┘
```

| block | file | notes |
|---|---|---|
| top (BD module reference) | `rtl/web888_core.v` | ports, register decode, status |
| clocking | `rtl/clk_gen.v` | IBUFDS → zero-delay PLL → BUFG; HF/VHF variants |
| NCO | `rtl/nco.v` | 48-bit phase, quarter-wave ROM + Taylor correction |
| RX front end | `rtl/rx_frontend.v` | 12 ch (hf) / 13 ch (vhf), as stock, CIC1 N=3 R=256, Hogenauer-pruned |
| RX back end | `rtl/rx_serial_cic.v`, `rtl/cic_serial_stages.v` | all 24 paths share one pipeline (LUTRAM state) |
| RX framing | `rtl/rx_chain.v` | `{Q,I}` per channel per sample |
| waterfall | `rtl/wf_ddc.v` | variable-rate CIC with exact power-of-two gain normalisation |
| DMA | `rtl/axi_ring_writer.v` | 16-beat AXI3 bursts into a ring, ≤ 8 outstanding |
| registers | `rtl/axi_regs.v` | byte-strobe CFG, STS, PPS FIFO pop |
| PPS | `rtl/pps_counter.v` | clocks per PPS period → FIFO |
| DNA | `rtl/dna_reader.v` | 57-bit device DNA |

Design choices vs. the vendor bitstream (which uses Xilinx DDS/CIC IP):
plain Verilog only (simulates with Icarus, no IP licences), one shared
time-multiplexed pipeline for everything after the first ×256 decimation,
DSP48s only for mixers, NCO correction and one gain multiplier.

Vivado 2026.1 implementation (HF build, xc7z010-1, 12 RX): **11.9 k LUT (68 %)**,
12.6 k FF (36 %), 57 DSP (71 %), 12.5 BRAM36 (21 %). Timing is met at 125 MHz
with 0.4 ns of extra setup uncertainty as guardband (WNS +0.058 ns, so
effectively 131.6 MHz, +7 % over the 122.88 MHz ADC clock). VHF build (13 RX):
70 % LUT, 76 % DSP, met at 111 MHz with a 0.5 ns guard (WNS +0.718 ns). Vendor design: 84 % LUT, 72 % FF, 75 % DSP, 55 % BRAM.

## Simulation results (`make sim`)

| test | result |
|---|---|
| NCO | 130 dB SFDR |
| register interface | signature, DNA, GPIO, byte-wise/unaligned CFG writes, PPS period: pass |
| RX, 3 channels, R2=5 (96 kHz) | tone frequency/sign exact, level within 0.001 dB of model, 116–122 dB SNR |
| WF0 continuous, R=4 | 4 components (incl. images, CIC droop, aliasing) within 0.001 dB, residual = 16-bit quantisation |
| WF1 one-shot, R=1 (122.88 MS/s) | exactly 256 bursts, no FIFO overflow with randomised HP backpressure |
| AXI | no protocol errors (memory models check burst shape, WLAST, W-before-AW, 4 KB) |

## Usage

```sh
make sim          # Icarus Verilog (PATH or local.mk) + numpy analysis
make hf vhf       # Vivado (PATH or local.mk; see doc/vivado-notes.md)
```

`make tables` regenerates `rtl/gen/` (NCO ROM, RX gain table) from
`scripts/gen_tables.py`.

## Before the first hardware test — things to verify

1. **HP port width**: the vendor FSBL (`boot.bin`) programs the AFI; this
   design assumes 64-bit HP ports like Vivado's default.
2. **DNA bit order**: must equal the vendor's or the stock driver's "genuine"
   check (eth0 MAC = hash(DNA)) fails and data stops 10 min after boot.
   Compare `GET_DNA` under the vendor and the open bitstream.
3. **ADC format/timing**: offset binary assumed (as the working
   red-pitaya-notes port); IOB capture on the PLL clock with the same input
   delays as that port.
4. **Sideband convention / scale**: Q sign (`Q_NEG`) and output levels are
   chosen from the server code; check USB/LSB and S-meter against the vendor
   bitstream.

## Licence

GPL-3.0-or-later, see `../COPYING`. `cfg/ps7_preset.xml` comes from red-pitaya-notes
(MIT, Pavel Demin, see `cfg/LICENSE-red-pitaya-notes`; MIT is GPL-compatible).
