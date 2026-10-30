# Virtual Web-888 (QEMU)

QEMU 11.1.2 out-of-tree patch set: a `web888` machine (subclass of
`xilinx-zynq-a9`) with `web888-pl`, a model of the FPGA logic
(CFG/STS/PPS FIFO, RX and WF DMA rings with synthetic DDC data per
`../fpga/doc/register-map.md`), Cadence I2C with a 24c64 EEPROM and an
Si5351 stub, and Zynq GPIO. The goal is to boot the **stock** firmware
(kernel with the closed `zynqsdr` driver, stock server) offline against
the model.

Vendor binaries (kernel, initramfs, DTB, SD image) are extracted locally
from the release zip and never committed.

## Status (2026-10-30)

| milestone | state |
|---|---|
| A. QEMU builds; bare-metal test reads registers, RX/WF rings, PPS | done |
| B. stock kernel boots to a shell | done |
| C. `zynqsdr` probes; signature and "Genuine" check with a matching MAC/DNA pair | done |
| D. stock server streams, web UI on forwarded port 8073 | done (`tests/kiwi-check.py`: AM audio tone, waterfall carriers) |
| E. web888d on the stock kernel and driver | done (2026-10-28, before its first run on a unit: RX at 48 kS/s, waterfalls, clean release of the device; found the musl `sched_setscheduler` stub) |
| F. the open driver (`../driver/`) with the Yocto 6.18 kernel and the web888-ng-os image | done: web888d serves HPSDR through it, `driver/test/zsdr-test` passes |
| G. web888-ng-os's SD card image through the boot ROM (`--bootrom --boot-mode sd`): SPL, U-Boot, A/B slots | done: `tests/sd-image.sh` (boot, ADC clock, web888.txt, slot marked good, fallback to slot B) |
| H. updates of that image (RAUC) | done: `tests/ota.sh` (streamed install, power cut during an install, a bad update rolled back) |
| I. chain-loading from the stock firmware (`../tools/chainboot`) | done: our image and the stock kernel both chain-load |

## Files

* `build-qemu.sh`: fetch QEMU 11.1.2, apply `qemu/patches/*`, copy `qemu/files/`, build arm-softmmu
* `make-sdimage.sh`: SD image plus zImage/initramfs/DTB from the release zip (`FW_ZIP=...`)
* `make-dtb.sh`: emulator DT from the vendor DT (changes listed in the script header);
  `NG_NODE=1` gives `web888-emu-ng.dtb` with the open driver's `web888-ng,sdr` node
* `run.sh`: boot (`--mac`, `--dna`, `--stock-sig`, `--sig`, `--scene`, `--dtb` options;
  model properties after `--`, e.g. `-- -global web888-pl.rx-bursts-start=4294940000`
  to start the RX burst counter just before its 32-bit wrap)
* `tests/vm.sh`: drive the serial console from scripts
* `tests/kiwi-check.py`: Kiwi-protocol client; checks audio and waterfall
  end to end (needs python3 `websocket-client` and `numpy`)
* `tests/sd-image.sh`, `tests/ota.sh`: web888-ng-os's SD card image and its
  updates, booted as on a board (each script's header says what it checks)
* `scripts/emu-dtb.sh`: the emulator's DT changes applied to a built DTB
* `scripts/bootbin.py`: boot.bin partition extraction

## Quick start

    FW_ZIP=/path/to/web-888-alpine-3.20-armv7-20260919.zip ./make-sdimage.sh
    ./build-qemu.sh
    tests/vm.sh start --stock-sig      # boots in ~1.5 min, root shell on ttyPS0
    tests/vm.sh wait 'web-888:~# ' 300
    tests/kiwi-check.py                # or open http://localhost:8073/
    tests/vm.sh run 'dmesg | grep zynqsdr'
    tests/vm.sh stop

The stock driver hands the server only zeros once NTP has set the guest
clock (about a minute after boot), unless the board MAC matches the one
derived from the device DNA. Pass a matching pair with `--mac`/`--dna`,
e.g. your own unit's (`GET_DNA` from `tools/zynqsdr-probe`, its eth0
MAC), or put `MAC=` and `DNA=` in `local.conf` (not versioned).

## Limits

* **System calls are slow** (35–80 µs each, ~50× QEMU's usual). ARMv7
  Linux uses software PAN (`CONFIG_CPU_SW_DOMAIN_PAN`), which rewrites
  DACR around every user-memory access, and QEMU flushes its whole TLB on
  each DACR write (`dacr_write()`, "domain not tracked in TLB"). Functional
  tests are fine; CPU load and throughput numbers say nothing about the
  real board. A kernel without SW PAN would be faster here, but that is a
  security feature of the real image.
* **The PL model always answers on the bus**, and its clocks and resets
  are ideal. It could not show the hang the first open bitstream caused
  on a real board (a PL reset held by gated fclk0,
  `../docs/hardware-test-plan.md`): bus, clock and reset behaviour need
  the hardware.
* `--kernel FILE` boots another kernel (e.g. the Yocto 6.18 kernel) with
  the vendor userspace. It has no stock `zynqsdr` driver, so the open
  driver (`../driver/`) can be loaded with `insmod`.

## Emulator changes to the vendor boot

* Device tree (`make-dtb.sh`): initrd location from QEMU, a one-entry CPU
  OPP table at the CPU clock Linux reads at boot (166.666 MHz, so cpufreq
  never switches and guest time stays right; the stock server reads
  cpufreq and crashes without it), USB disabled.
* apkovl: root auto-login on the serial console (`AUTOLOGIN=0` to keep the
  vendor login).
