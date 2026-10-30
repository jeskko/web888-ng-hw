# web888-ng-hw: open FPGA and platform for the Web-888 SDR

Part of **web888-ng**.

An open-source replacement for the closed parts of the
[Web-888](https://www.rx-888.com/web/) receiver's platform layer (Zynq
xc7z010 + LTC2208):

| directory | what | status |
|---|---|---|
| `fpga/` | Open bitstreams. `websdr_hf.bit` / `websdr_vhf.bit` are drop-ins for the stock ones: 12 (HF) / 13 (VHF) RX DDCs, 2 waterfall DDCs, DMA, PPS, DNA. `websdr_pfb.bit` is the channelizer: the whole HF band in 30 kHz bins, a power line for the full-band waterfall and a tuner for 32 receivers (`docs/channelizer.md`). Plain Verilog, Icarus simulation, Vivado build on CI. | HF v0.2.0 **runs on stock units** and under web888-ng-os; the channelizer (v0.3.0) has run on the project's unit since 2026-10-29. VHF simulated and timing-clean, not yet on hardware; v0.3.0's own HF/VHF rebuilds not yet on hardware |
| `driver/` | Open kernel driver (GPL-2.0-or-later), compatible with the stock `zynqsdr` ioctl ABI, plus the channelizer's ioctls | **runs on a Web-888** under web888-ng-os, with the HF and the channelizer bitstreams |
| `emu/` | Virtual Web-888 (QEMU machine with a model of the FPGA logic): the stock firmware, the open driver, and web888-ng-os's SD card image booted through the boot ROM as on a board, with tests (`tests/sd-image.sh`, `tests/ota.sh`) | working; the model doesn't run the channelizer |
| `tools/` | `probe-readonly.sh` (inventory of a running unit), `zynqsdr-probe` (signature/DNA via the stock driver), `wdt` (watchdog kicker and test, the safety net for test bitstreams), `slcr-peek` (PS-side SLCR and EMIO reads, safe with a dead PL bus), `chainboot` (start another kernel from the stock firmware, without kexec), `physmem` (/dev/mem reads and writes), `kiwi/` (Kiwi-protocol measurement clients) | working |
| `docs/` | Interface notes for the stock firmware, stability analysis, hardware test plan, channelizer design, OS base | |

The server side (`web888d`) lives in [web888-ng](https://github.com/jeskko/web888-ng),
the SD card image and updates in
[web888-ng-os](https://github.com/jeskko/web888-ng-os).

## Quick start

```
cd fpga
make sim          # needs iverilog + python3/numpy
make hf vhf pfb   # needs Vivado (2026.1 tested); see fpga/doc/vivado-notes.md
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
* `docs/channelizer.md`: the channelizer bitstream (polyphase bank, radix-2² FFT, bins tuner), design and progress
* `docs/os-base.md`: what the open firmware image is built on (Yocto + RAUC)
* `driver/README.md`, `emu/README.md`: the open driver and the virtual Web-888

## Licence

GPL-3.0-or-later (`COPYING`); the kernel driver (`driver/`) is GPL-2.0-or-later.
`fpga/cfg/ps7_preset.xml` comes from red-pitaya-notes (MIT, Pavel Demin).
Not affiliated with the Web-888 / RX-888 vendor.
