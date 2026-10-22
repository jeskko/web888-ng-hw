# Hardware test plan (open bitstream on stock firmware)

## 1. Prepare a stock SD card

The unit ships without one. Follow the vendor guide
(https://www.rx-888.com/web/guide/requirements.html):
- SD/SDHC 200 MB–32 GB (no SDXC), FAT32.
- Unzip the release from the downloads page straight into the card root
  (no subfolder). Use the 20260919 release (zip sha256 `32da2adb…6668d74`),
  or record the new one and hash its `.bit` files.
- Boot once, then `dd` the card as the stock baseline and back up `config/`.
- **Turn off automatic updates** in the admin UI. The updater also replaces
  the `.bit` files and would quietly put stock back during a long run.
- Swapping bitstreams means replacing `websdr_{hf,vhf}.bit` in the card root.
  Keep the originals as `.orig`.

## 2. Baseline with the stock bitstream

Record the following, once in 64 MHz mode (`websdr_hf.bit`) and once in 32 MHz
mode (`websdr_vhf.bit`, 13 RX):
- `dmesg`: FPGA signature, "Genuine Web-888 Detected".
- eth0 MAC, and `GET_DNA` (`tools/zynqsdr-probe`; stop `sdrd` first).
- Server levels for a known signal (S-meter, waterfall), USB/LSB behaviour.
- WF mode polarity: with `sdrd` stopped, `WF_START` and count the samples
  `WF_READ` returns (8192 then stop = one-shot = mode bit 1). The stock
  driver always sets the bit, so continuous (bit 0) can only be checked
  with the open driver (section 4, `zsdr-test`).

## 3. Open bitstream

Copy `fpga/build/hf/websdr_hf.bit` and **reboot**. The stock driver's device
check is sticky per boot, so a service restart after stock passed would not
re-check the DNA. Then check, in this order:

1. `dmesg`: signature `0x0E5D020C` (our VHF: `0x0E5D020D`) and **"Genuine
   Web-888 Detected"**. If the second is missing, the DNA bit order differs
   from the stock bitstream's: compare `GET_DNA` under stock and ours, then fix
   `fpga/rtl/dna_reader.v`. Do this before debugging the signal path: on a
   mismatch the stock driver hands the server zeros once NTP has set the
   clock (`docs/stock-driver.md`), which looks like a dead ADC.
2. The server starts, with audio and waterfall present (ADC format, PLL lock, DMA).
3. Tuning accuracy and sideband (`Q_NEG`), levels vs. stock (scale).
4. Waterfall zoom levels, time-shared mode with > 2 users.
5. PPS / GPS clock correction, antenna GPIO, attenuator, dither/PGA, LED.
6. VHF/airband modes with `websdr_vhf.bit`.
7. Long run (> 10 min, then hours). Watch the extension status registers
   (`fpga/doc/register-map.md`): flags 0x20 (overflow, sequence and AXI errors,
   PLL unlock count), and check that RX frames 0x30 keep advancing while
   drops 0x34 stay at 0.

## 4. Open driver (web888-ng-os image)

Only after section 3 passed. Boot the web888-ng-os image (6.18 kernel,
open driver `web888-sdr`, no bitstream loaded at boot), console attached:

1. Before any bitstream load, `cat /sys/class/fpga_manager/fpga0/state`
   and `busybox devmem 0xF8000900; busybox devmem 0xF8000240` (level
   shifters, fabric resets) if available. Then `exec 3</dev/zynqsdr` must
   fail with "No such device" and `dmesg` must show "PL not ready". **The
   board must not hang**: this is the check the emulator can't do. If it
   hangs, the driver's SLCR test is not enough.
2. `web888d serve --bitstream websdr_hf.bit`: "fpga_manager" in its
   log, then the signature in `dmesg`, then streaming as in section 3.
3. `driver/test/zsdr-test` (stop web888d first). The emulator-specific
   checks (carrier in channel 0, attenuator level, overrun skip) need an
   antenna signal or a signal generator at 15 MHz; the rest must pass.
4. Reload the bitstream while nothing has the device open (`web888d`
   stopped, load again through `fpga_manager`), then open again.

## 5. Revert

Copy the `.orig` files back, or restore the baseline image.
