# Hardware test plan (open bitstream on stock firmware)

## 0. Safety net on a remote unit: the watchdog

A unit nobody can power-cycle (the production unit) must not hang for
good. A hard hang (e.g. an AXI access nothing answers) stalls the CPU. The
Zynq's hardware watchdog then resets the board, if something armed it.
Nothing does on the stock firmware. `tools/wdt` (static ARMv7) arms it for
a test:

    wdt info                    # identity, options; disarms at once
    wdt keep 30 0 &             # kick every 7 s until /tmp/wdt.stop exists
    ...test...
    touch /tmp/wdt.stop         # disarm (magic close)
    wdt hang 30                 # simulate a hang: reset after 30 s

Facts on the stock firmware (production unit, 2026-10-28):
* `cdns_wdt` with `reset-on-timeout` in the DT (a timeout resets the
  board, not just an interrupt), `nowayout=0` (the magic close disarms
  it), and a 10 s default timeout. Options 0x8180: settable timeout,
  keepalive, magic close.
* `info` and `keep 30 40` disarm cleanly; the unit stays up.
* `hang 30`: ping is lost 30 s after arming. The board answers ping again
  25 s later, and ssh a second after that. sdrd, gpsd, chronyd and the
  stock web UI come back by themselves, and chrony sets the clock within
  about a minute (no RTC: the clock starts in the past).
* The SD's FAT partition is mounted read-only but remounted rw when stock
  saves its config. Run `sync` and check `mount` shows `ro` before
  anything that may reset the board.
* Kernel `panic=120` reboots 120 s after a panic; `panic_on_oops=0`.

Limits: the watchdog only runs while `wdt keep` runs. A hang during boot
(before anyone arms it) still needs a power cycle. So on a remote unit,
load test bitstreams at run time (`web888d serve --bitstream PATH`, with
`wdt keep` running) rather than by replacing `websdr_hf.bit` on the SD and
rebooting. The stock driver's device check has then already passed for
this boot.

### 0.1 web888d on a stock unit

First in the emulator (`emu/`: stock kernel and driver against the
`web888-pl` model; done 2026-10-28). web888d opened `/dev/zynqsdr`, read
the signature (12 RX, 2 WF at 122.88 MHz) and streamed RX at 48 kS/s with
waterfalls. It exited on SIGTERM, the driver released the device, and
stock sdrd started again. It also found a bug: musl's
`sched_setscheduler()` is an ENOSYS stub (the skimmers now use the raw
syscall). The emulator's CPU numbers are meaningless (slow syscalls).

On the unit, everything goes to `/tmp/w888` (tmpfs): web888d (CI artifact
`web888d-armv7-musl`), `ui/`, `wdt`, a config and a start/stop script:
* the watchdog first (`wdt keep 30 0`, nice -5), then `rc-service sdrd
  stop`, then web888d;
* `bitstream = "none"`: the stock bitstream that sdrd loaded stays, and
  nothing is reprogrammed;
* web on `127.0.0.1:18073` only (ssh tunnel; the public front end
  forwards to 8073), HPSDR off, no `[report]` (nothing uploaded);
* stop: SIGTERM to web888d, `rc-service sdrd start`, `touch
  /tmp/wdt.stop` (disarms within a kick interval).

Run on the production unit (2026-10-28, ~10 min, stock bitstream
`0xAA55020C`):
* web888d opened the stock driver: 12 RX, 2 WF, 122.88 MHz. RX at 48.0 k
  frames/s with `hw_rate_ok`, no driver messages beyond open and
  release, RSS 18 MB.
* Receiver page (relayed with `socat` + `ssh ... nc`, since the unit's
  sshd allows no port forwarding): audio with 0 underruns and 0 drops, the
  0-61 MHz waterfall, a zoomed waterfall, click-tune, FT8 labels.
* FT8 on 40/30/20 m: ~90 decodes per slot (261/144/333 in 7 slots).
  The decoders (now `SCHED_IDLE`, policy 5) use ~4.5 s of CPU per band
  and slot, as the bench said. DSP threads ~8 %, RX reader ~9 % of a core.
* No PPS correction (`clock_ppm 0`): the unit's GPS has no antenna, so
  there is no fix and no PPS. gpsd connected without a fix.
* Back to stock: web888d stopped on SIGTERM, sdrd started and reopened the
  device, the watchdog disarmed, no reset.
* `bitstream = "auto"` (web888d loads the stock `.bit` itself through
  devcfg; 2026-10-28, with go-ahead): works, 48.1 k frames/s.

**Open bitstream v0.1.0 (`0x0E5D020C`), loaded at run time on the
production unit (2026-10-28): hard hang, reset by the watchdog both times.**
Done step by step (`private/m4-test-kit/load-bit.sh steps`, output
streamed):
1. `cat websdr_hf.bit > /dev/xdevcfg`: exit 0, the load works.
2. SLCR afterwards (`tools/slcr-peek`, PS registers only):
   `FPGA_RST_CTRL = 0` (PL resets released), `LVL_SHFTR_EN = 0xf`,
   `FPGA0_CLK_CTRL = 0x00400500`.
3. The first PL register access (`tools/zynqsdr-probe`: open, then
   `GET_SIGNATURE`) never completed: the board hung, and the watchdog reset
   it about 30 s later. It came back on stock by itself.

So the bitstream configures, but nothing answers on M_AXI_GP0.
`axi_regs.v` answers every address and handles bursts, so the likely
reason is that its clock isn't running (the ADC-clock PLL in `clk_gen.v`
drives `M_AXI_GP0_ACLK`, and the bus reset is synchronised on it), or its
reset stays asserted. The vendor design clocks GP0 from the same kind of
PLL, but takes no reset from the PS (`proc_sys_reset` with a constant
`ext_reset_in`). Next, without any AXI access: put `pll_locked`, a
divided-down heartbeat of the PLL clock and the bus-reset state on EMIO
GPIO inputs, and read them from the PS GPIO controller (`0xE000A068`,
DATA_RO bank 2) through /dev/mem. That read is PS-side and safe even when
the PL's AXI is dead. Longer term: clock GP0 from a PS clock (FCLK) with a
CDC into the ADC domain, so a missing ADC clock can never hang the bus.

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
