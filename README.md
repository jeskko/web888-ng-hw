# web888-ng-hw: open FPGA and platform for the Web-888 SDR

Part of **web888-ng**.

An open-source replacement for the closed parts of the
[Web-888](https://www.rx-888.com/web/) receiver's platform layer (Zynq
xc7z010 + LTC2208):

| directory | what | status |
|---|---|---|
| `fpga/` | Open bitstream, a drop-in for the stock `websdr_hf.bit` / `websdr_vhf.bit`: 12 (HF) / 13 (VHF) RX DDCs, 2 waterfall DDCs, DMA, PPS, DNA. Plain Verilog, Icarus simulation, Vivado build. `fpga/rtl/fft/`: a channelizer datapath for a future bitstream (`docs/channelizer.md`). | release v0.2.0: HF **runs on a stock unit** with the stock driver; VHF simulated and timing-clean, not yet on hardware. Channelizer: simulated bit-exact, synthesis in progress |
| `driver/` | Open kernel driver (GPL-2.0-or-later), compatible with the stock `zynqsdr` ioctl ABI | works in the emulator, untested on hardware |
| `emu/` | Virtual Web-888 (QEMU machine with a model of the FPGA logic) for running the stock firmware and the open driver offline | work in progress |
| `tools/` | `probe-readonly.sh` (inventory of a running unit), `zynqsdr-probe` (signature/DNA via the stock driver), `wdt` (watchdog kicker and test, the safety net for test bitstreams), `slcr-peek` (PS-side SLCR and EMIO reads, safe with a dead PL bus), `kiwi/` (Kiwi-protocol measurement clients) | working |
| `docs/` | Interface notes for the stock firmware, stability analysis, hardware test plan, channelizer design, OS base | |

The server side (`web888d`) lives in [web888-ng](https://github.com/jeskko/web888-ng).

## Quick start

```
cd fpga
make sim          # needs iverilog + python3/numpy
make hf vhf       # needs Vivado (2026.1 tested); see fpga/doc/vivado-notes.md
```

Then copy `fpga/build/hf/websdr_hf.bit` to the SD card of a unit running the
stock firmware, or take the bitstreams from a release. See
`docs/hardware-test-plan.md` first (on a unit you can't power-cycle, only
with the watchdog armed).

## Docs

* `fpga/README.md`: design overview, resources, simulation results
* `fpga/doc/register-map.md`: CFG/STS registers (stock-compatible plus extensions)
* `docs/stock-driver.md`: the stock kernel driver's interface (ioctl ABI, PL windows)
* `docs/server-fpga-interface.md`: what the stock server expects from driver and FPGA
* `docs/stock-unit-facts.md`: facts from a running stock unit (DT, PPS, signature)
* `docs/bitstream-and-block-design.md`: what the closed bitstream contains
* `docs/stability-64mhz.md`: why stock HF went from 13 to 12 channels, and how the open design avoids frame-slip wedges
* `docs/hardware-test-plan.md`: how to test on real hardware, and the results so far
* `docs/channelizer.md`: the channelizer bitstream (polyphase bank, radix-2² FFT), design and progress
* `docs/os-base.md`: what the open firmware image is built on (Yocto + RAUC)
* `driver/README.md`, `emu/README.md`: the open driver and the virtual Web-888

## Licence

GPL-3.0-or-later (`COPYING`); the kernel driver (`driver/`) is GPL-2.0-or-later.
`fpga/cfg/ps7_preset.xml` comes from red-pitaya-notes (MIT, Pavel Demin).
Not affiliated with the Web-888 / RX-888 vendor.
