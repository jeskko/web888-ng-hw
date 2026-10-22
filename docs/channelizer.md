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

**Noise floor against today's chain** (`examples/chancompare.rs`): the
same ADC samples go through the channelizer (T = 11) and an exact model
of the FPGA RX chain (NCO, CIC N=3 R=256, CIC N=5 R=10,
`web888_iq::ddc`). The samples are white noise at the LTC2208's SNR
plus strong carriers at each path's worst aliasing offsets around six
FT8 dials (3.5–21 MHz). The table gives the USB 300–2700 Hz floor in dB
re full-scale sine:

| case | tuned chain | channelizer |
|---|---|---|
| noise only | −121.5 to −121.7 | −121.5 to −121.6 |
| + 36 carriers at −26 dBFS | +0.1 dB | ≤ +0.1 dB |
| + one carrier per dial at −10 dBFS, worst offset | +0.1 dB | **up to +2 dB** (+61.5 kHz; +1.5 dB in a transition-band case) |

So T = 11 equals today's chain for carriers up to about −20 dBFS. At
−10 dBFS (very strong for HF on this ADC) its aliases sit about 115 dB
down, right at the floor. **T = 12** (110 dB, measured −112) closes
that gap for about 3 more BRAM (≈ 46 of 60): the recommendation if BRAM
allows, with T = 11 as the fallback.

The harness has to wait out the carriers' switch-on (200 ms, longer than
the audio filter's ~60 ms block); measuring earlier showed onset
splatter as a fake +30 dB floor.

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

BRAM: about 47 of 60 at T = 11 and 50 at T = 12, with the chosen
widths and real BRAM layouts (§3.2). This first float-only estimate
(~43) assumed perfect packing.

### 3.2 Fixed-point widths (2026-10-23)

`crates/dsp/src/pfbfx.rs` models the integer datapath, sweeping widths
with `examples/pfbfxmodel.rs`. The 4096-point real FFT is done the FPGA
way: the real branch sums packed into 2048 complex values, a radix-2 FFT,
then a split stage. The model runs on the same 16-bit samples as the
float model and compares the two. The input is a tone at −1 dBFS or
eight tones near full scale, both with ADC noise of 3 LSB rms. The
measure is how far the fixed-point error stays below the ADC noise in a
bin (bins away from the tones).

| choice | error below noise (−1 dBFS tone / 8 tones) | saturations |
|---|---|---|
| 25-bit data, 18-bit twiddles, 18-bit coefficients, halving in all 11 stages | 13.8 / 16.5 dB | 0 |
| same, halving in 5–7 stages | — | yes (tone) |
| 22-bit data, best scaling | ≤ 9 dB | 0 |
| 25-bit data, 18-bit twiddles, 18-bit coefficients, halving 4 first + 4 last | 16.2 / 23.9 dB | 0 |
| **25-bit data, 18-bit twiddles, 20-bit coefficients, halving 4 first + 4 last** | **23.8 / 28.3 dB** | 0 |
| same with 22- or 25-bit coefficients | 25.3 / 28.8 dB | 0 |

* **Chosen** (`FixedSpec::recommended`):
  * 16-bit ADC samples on the DSP48 B port, 20-bit coefficients on A
  * branch sums exact (48-bit accumulators), rounded to 25-bit FFT data
  * 18-bit twiddles
  * a rounded halving after FFT stages 1–4 and 8–11
* The fixed-point error is then ~24 dB below the ADC noise, about +0.02
  dB on the floor. Nothing saturates for a −1 dBFS tone.
* At least 8 halvings are needed: fewer saturate on a near-full-scale
  tone. 16-bit twiddles cost 3–6 dB.
* Output: bins as 32-bit I/Q, scaled so a full-scale sine reads 2^29,
  like today's RX samples, so the server's `rx_to_c32` applies
  unchanged. The 25 significant bits fit easily.
* Bit-exact test vectors wait for the Verilog FFT architecture. A
  radix-2² pipeline rounds at slightly different points than this
  radix-2 model.

**BRAM recount** at T = 12. A BRAM36 holds 2K×18, 16K×2 or 1K×36, so
widths don't pack perfectly:

| memory | layout | BRAM36 |
|---|---|---|
| sample history, 49 152 × 16 bit | 2K×18 | 24 |
| coefficients, 24 576 × 20 bit (symmetric half) | 2K×18 + 16K×2 | ~13.5 |
| FFT delay lines and twiddles, reorder buffer | | ~8 |
| power accumulator, DMA FIFOs | | ~5 |
| **total** | | **~50 of 60** |

At T = 11 it is about 47. That fits, but leaves little for extras.
Keeping the history in DDR doesn't work: every frame reads all M × T
samples, 22 × the input rate, about 5 GB/s.

### 3.3 First estimates (before the model)

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
   and tests done; T sweep, noise floor against today's chain and the
   A9 fine-stage bench in §3.1. Recordings (8 bit, ~48 dB) can't show
   effects at −100 dB; they get a listening check through the iq-backend
   mode instead.
   * float reference: prototype design, analysis filter bank, per-user
     fine stage ✓
   * tests: bin placement, flatness, alias rejection, noise floor
     against the current tuned chain
   * A9 bench of the fine stage per user
2. **Fixed-point model**: word lengths chosen (§3.2,
   `crates/dsp/src/pfbfx.rs`). Bit-exact reference vectors follow once
   the Verilog FFT architecture is fixed.
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
