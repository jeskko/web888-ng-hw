# Channelizer bitstream (design note)

Status: **proposal, software model in progress** (2026-10-23). This
would be the core of the open-FPGA milestone (server design §11, M6).
It drops compatibility with the stock server's FPGA interface. The
stock bitstream stays usable as a fallback with its own backend.

## 1. Why

Today, stock and open alike, every RX channel is a tuned receiver at the
full ADC rate: NCO, two multipliers and a first CIC, then decimation.
That costs about 2 DSP48 slices and a block of LUTs per channel before
any rate reduction.

| design | RX channels | LUT | DSP | BRAM36 | timing |
|---|---|---|---|---|---|
| vendor HF | 12 (13 VHF) | 84 % | 75 % | 55 % | met |
| open HF (`fpga/`) | 12 | 68 % | 71 % (57) | 21 % | met at 122.88 MHz with 0.06 ns to spare beyond a 0.4 ns guard |

With 80 DSP and 17.6 k LUTs, that architecture tops out at roughly 16–20
channels, and each channel makes timing harder. The waterfall is two more
tuned receivers whose I/Q the CPU turns into spectra: our biggest CPU cost
(server `doc/m3-multi-user.md` §4).

## 2. The idea

One channelizer splits the whole band at once, and the CPU only finishes
the channels that are in use:

```
ADC 122.88 MS/s real
  └─▶ polyphase filter bank: M = 4096 branches, T taps each
        └─▶ 4096-point real FFT every D = 2048 samples
              └─▶ 2049 bins, 30 kHz apart, each a 60 kS/s complex stream (2× oversampled)
                    ├─▶ bin selector ─▶ DMA: only the bins users or decoders asked for
                    └─▶ |X|² accumulator ─▶ DMA: full-band 0–61.44 MHz power spectrum
```

* **Real input, no real→complex stage.** The filter bank works on the
  real ADC samples and the FFT is real-to-complex. Its band edges are at
  DC and Nyquist, as the ADC's are. A complex intermediate (fs/4 mix +
  half-band) would have put 0–3 MHz (LF/MF/160 m) into a transition band.
* **2× oversampling** (D = M/2) makes every bin flat to ±21 kHz. Each
  bin's output is the band around its centre, sampled at 60 kS/s, with
  everything beyond ±39 kHz rejected. So any channel up to ±6 kHz wide
  whose centre lies within ±15 kHz of a bin centre (always true for one
  bin) is entirely inside that bin. The phase correction for D = M/2 is
  a sign flip of odd bins on odd frames.
* **Per user, on the CPU:**
  * shift by the offset from the bin centre (at most ±15 kHz)
  * decimate 60 → 12 kS/s (the existing audio chain, ×5 instead of ×4)
  * HPSDR at 48 kS/s by a 4/5 resampler

  This is about the work done today per user on 48 kS/s.
* **Channels are limited by CPU and network, not the FPGA:** maybe 24–32
  users on two A9 cores after the planned NEON/decimator work. Bins cost
  60 kS/s × 8 bytes = 480 kB/s each; 64 bins are about 31 MB/s of DMA.
* **Full-band waterfall for free:** |X|² summed per bin over a line
  gives the whole 0–61 MHz at 30 kHz resolution, at any line rate. A
  zoomed view is a CPU zoom-FFT over the bins it covers: one bin per
  30 kHz of span, e.g. 17 bins for a 480 kHz view. That replaces the WF
  slots and their time-sharing.
* **Wide slices are adjacent bins:** CW/RTTY skimmers over 50–100 kHz,
  FT8 on every band, wideband I/Q export (a few MHz) for SDR++ or
  ka9q-radio.

Prior art: ka9q-radio (GPL) runs hundreds of channels from one large FFT
(fast convolution) on a PC with the RX-888; wsprdaemon builds on it.
Polyphase channelizers are standard on FPGAs (CASPER, radio astronomy).

## 3. Numbers

### 3.1 Measured with the float model (2026-10-23)

`cargo run --release -p web888-dsp --example pfbmodel` (server repo):
M = 4096, pass ±21 kHz, stop ±39 kHz. "Worst alias" is the strongest
stopband tone (39–150 kHz from the bin centre) that folds into the
passband, relative to the tone. Ripple is across ±21 kHz.

| T | design | worst alias | ripple |
|---|---|---|---|
| 8 | 90 dB | −52.5 dB | 0.021 dB |
| 9 | 90 dB | −70.1 dB | 0.003 dB |
| 10 | 90 dB | −90.5 dB | 0.0003 dB |
| 11 | 100 dB | **−101.2 dB** | 0.0001 dB |
| 12 | 110 dB | −112.0 dB | < 0.0001 dB |

The Web-888's ADC (LTC2208, 16 bit, about 77 dB SNR over 61 MHz) has a noise
floor near −121 dBFS in a 2.4 kHz SSB channel. A signal at −20 dBFS
aliased 100 dB down stays under it.
* **T = 11** (100 dB) is the default.
* **T = 10** (90 dB) is the fallback if BRAM runs short.

The design attenuation has to match T: asking for more than T taps can
give makes it worse (the 110 dB rows at T ≤ 11).

**Per-user CPU** (`examples/bench.rs`, the `pfb fine stage` line, one A9
core at nice 19 on the production unit, three runs):

| path | per user |
|---|---|
| shift + USB chain from a 60 kS/s bin | **4.4–4.6 %** |
| today's USB chain from a 48 kS/s channel | 3.5–3.7 % |

About 25 % more, from the higher rate plus the shift. Two cores less the
server's other threads leave roughly 30 plain users, or about 25 with
NB/NR on, before the NEON/decimator work.

The waterfall's CPU cost goes away with this design: the full-band
power line comes from the FPGA, and zoom-FFTs run over a few bins.

BRAM at T = 11:
* history: 45 k samples × 16 bit ≈ 20 BRAM36
* coefficients: 22.5 k × 18 bit (symmetric) ≈ 11
* FFT and the rest: about 12
* **total ≈ 43 of 60**

### 3.2 First estimates (before the model)

Prototype filter (Kaiser): pass ±21 kHz, stop ±39 kHz. The transition is
18 kHz at 122.88 MS/s = 1.46·10⁻⁴ cycles/sample; for 100 dB that needs
≈ 44 k taps, so **T ≈ 11 taps per branch**.

| block | DSP | BRAM36 | LUT | notes |
|---|---|---|---|---|
| polyphase FIR | ~24 | ~22 data + ~12 coeffs (symmetric) | ~2 k | 24 MAC per input sample (4096 × 11 per 2048 samples) |
| 4096-pt real FFT, streaming | ~15 | ~6 | ~3 k | as a 2048-pt complex FFT, 1 point/clock |
| power accumulator, bin selector, DMA | 2 | ~6 | ~2 k | |
| registers, PPS, DNA, GPIO (from `fpga/`) | 1 | 0 | ~1.5 k | |
| **total** | **~42** | **~46** | **~8.5 k** | of 80 DSP / 60 BRAM / 17.6 k LUT |

BRAM is the tight resource, more than first guessed: the delay lines hold
M × T input samples. Ways to trade it:
* 90 dB instead of 100 dB (T ≈ 10)
* narrower guaranteed passband (smaller channels near bin edges)
* 14-bit stored samples
* 18-bit coefficient symmetry
* DDR instead of BRAM for the history (the HP ports have bandwidth to
  spare; latency is irrelevant here)

The model gives the real T, word lengths and ripple.

## 4. Server side

* New backend next to the stock-driver one: the `Radio` trait gains (or
  a new trait offers) "bin streams" and a "full-band power line" instead
  of tuned channels. The lease manager leases bins: two users in the
  same bin share its stream, and CPU cost follows users, not bins.
* The fine stage per user is `Shifter` + `AudioChain` at 60 kS/s
  (`crates/dsp/src/pfb.rs`, `PfbChannel`).
* The waterfall becomes zoom-FFTs over bins plus the full-band power
  line. The WF scheduler and slot time-sharing go away for this backend.
* The iq backend can run the same model (complex input), so the whole
  server can be developed against it without the bitstream.

## 5. Plan

1. **Software model** (server `crates/dsp/src/pfb.rs`): float reference
   and tests done; T sweep and A9 fine-stage bench in §3.1. Still to
   do: noise floor against the current chain on recordings, and the
   iq-backend mode.
   * float reference: prototype design, analysis filter bank, per-user
     fine stage ✓
   * tests: bin placement, flatness, alias rejection, noise floor
     against the current tuned chain
   * A9 bench of the fine stage per user
2. **Fixed-point model**: word lengths per stage (ADC 16 bit, filter
   accumulators, FFT growth/scaling), bit-exact reference vectors for the
   Verilog.
3. **Verilog**: polyphase FIR, streaming real FFT, accumulator, bin
   selector, ring DMA; simulated (Icarus/Verilator) against the
   fixed-point vectors; synthesis in CI for resources and timing.
4. **Driver and backend**: registers for bin masks and the power line,
   the server backend, the iq-backend variant.
5. **On the test unit**: noise floor, spurs, alias rejection on the air
   against the stock bitstream; CPU per user.

## 6. Open questions

* Exact T, and whether the history fits in BRAM (§3).
* Bin count: 4096 branches (30 kHz bins) against 2048 (60 kHz bins: half
  the FFT, but the CPU decimates 120 → 12 kS/s per user).
* Do the VHF airband modes (98.304 / 110.592 MHz clocks, undersampling)
  carry over? They should: the bank sees whatever is in the Nyquist zone.
* GPS timestamps per frame (sample counter at each frame) for TDoA-grade
  I/Q: cheap, and planned with M6 anyway.
