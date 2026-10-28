# Stock firmware: facts from a running unit

Read-only inventory of a Web-888 running the stock 2026-09 release
(`tools/probe-readonly.sh`, plus one `tools/zynqsdr-probe` run with the
server stopped). These are interface facts the open FPGA, driver and server
need to match.

## Software

- Kernel `6.6.110-xilinx` (built 2025-10-18), Alpine 3.20 diskless (tmpfs
  root, `lbu` apkovl, modloop). The SD card (FAT) is mounted read-only at
  `/media/mmcblk0p1`, but the stock server remounts it read-write when it
  saves its configuration (check `mount` and `sync` before anything that
  may reset the board).
- The bitstreams on the card are byte-identical to those in the
  `web-888-alpine-3.20-armv7-20260919` release (sha256 HF `cacb1968…c0b3d6`,
  VHF `298415f0…7513e`).
- The automatic updater replaces `websdr.bin` **and** `websdr_{hf,vhf}.bit`
  (an `update/checksum` file lists all three, and `.old` copies are kept).
- The server runs as OpenRC service `sdrd` under `supervise-daemon` (respawn
  after 2 s, unlimited). `start_pre` copies `websdr.bin` and `config/*` from
  the card to `/root`.
- The server's only device fds are `/dev/i2c-0` (Si5351, EEPROM) and
  `/dev/zynqsdr`. It never `mmap`s the device: all sample data goes through
  the `RX_READ`/`WF_READ` ioctls. It opens `/dev/zynqsdr` once per server
  start.
- Ports: 8073/tcp (web), 40410/udp (server), gpsd on localhost.

## FPGA

- **HF bitstream signature `0xAA55020C`: 12 RX channels**, 2 WF. The VHF
  bitstream (ADC < 100 MHz) has 13 RX (RaspSDR/server#58). The server sets
  the RX frame stride from the signature. See `stability-64mhz.md` for why
  HF went from 13 to 12.
- The `GET_DNA` value fed through the stock driver's device binding
  reproduces the unit's eth0 MAC. This confirms the DNA layout (low word at
  STS 0x0C, high at 0x10) as the stock driver uses it.
- No PL interrupts are registered (the IRQ_F2P lines are unused). CMA is
  16 MiB at 0x1f000000.

## Clocks, resets, watchdog (2026-10-28)

What a bitstream loaded on this firmware finds (read from the PS side:
`tools/slcr-peek`, devcfg sysfs, `tools/wdt`):

- **fclk0 is gated.** devcfg's `fclk/fclk0` (after `fclk_export`) reads
  `enable` 0, rate 50 MHz; the vendor bitstream doesn't use it, and the
  kernel leaves it off. SLCR: `FPGA0_CLK_CTRL` 0x00400500,
  `FPGA_RST_CTRL` 0, `LVL_SHFTR_EN` 0xf.
- **FCLK_RESET0_N stays asserted while fclk0 is gated**, although
  `FPGA_RST_CTRL` reads 0. A PL reset taken from it never releases: that
  hung the board with the open bitstream v0.1.0. Enabling fclk0
  (`echo 1 > .../fclk/fclk0/enable`) released it at once. So the PL must
  run on its own clock (the ADC clock) and reset, as the vendor design
  does.
- Watchdog: `cdns_wdt` with `reset-on-timeout` (a timeout resets the
  board), `nowayout=0`, 10 s default timeout; nothing arms it on the stock
  firmware. Kernel `panic=120`, `panic_on_oops=0`.

## Boot chain (2026-10-29)

- **One FAT partition** (1.8 GB, 25 % used) holds everything. **No U-Boot**:
  `boot.bin` (9 MB, the same file as `x/boot.bin`) is FSBL + a 13-word
  stub at 0x100000 + DTB at 0x2000000 + kernel at 0x2008000 + initrd (4
  MB) at 0x3000000, all loaded by the FSBL (red-pitaya-notes' Alpine
  scheme). The stub unlocks the SLCR, enables the level shifters, sets the
  SCU filter start to 0x02000000 and jumps to the kernel with r2 = the
  DTB. The FSBL is a release build (no debug strings) with the Si5351
  hook.
- `bootargs`: `console=ttyPS0,115200 earlycon earlyprintk
  initrd=0x3000000,4M modloop=modloop` (from the DTB).
- `fw_printenv` reads a U-Boot-format environment from the **I2C EEPROM**
  (0x1800, 1 KB): board data (`serial`, `hw_rev`, `prod_date`,
  `refclock`, MACs) plus an unused `bootcmd`; nothing on the unit runs
  U-Boot.
- The boot ROM can't fall back on SD: "The SD card boot mode does not
  support header search or multiboot" (UG585), so it always loads
  `BOOT.BIN`.
- The kernel has **no kexec** (`sys_kexec_load` is the weak not-implemented
  stub; no `machine_kexec`, no `/sys/kernel/kexec_loaded`). CPU hotplug
  is there (`cpu1/online`). The watchdog driver has no shutdown hook.

## Device tree (live)

```
zynqsdr { compatible = "rx888,zynqsdr";
          gpios = <&gpio0 10 1>, <&gpio0 13 1>, <&gpio0 12 1>,
                  <&gpio0 11 1>, <&gpio0 49 1>;          /* all active-low */
          interrupts = <0 29 1>, <0 30 1>, <0 31 1>, <0 32 1>; };  /* IRQ_F2P[3:0] */
pps     { compatible = "pps-gpio"; gpios = <&gpio0 54 0>; capture-clear; };
fpga-full { compatible = "fpga-region"; fpga-mgr = <&devcfg>; };  /* no PL nodes */
```

GPIO order: 0 HF/VHF switch, 1 AD8370 CLK, 2 AD8370 LATCH, 3 AD8370 DATA,
4 ref-clock select. PPS reaches the kernel on EMIO GPIO 54 (`/dev/pps0`,
used by gpsd and chrony), so the open FPGA routes PPS to `GPIO_I[0]`.

## Load (12 users: 10 FT8 decoders, 4 DRM workers)

`websdr.bin` runs 50 threads with 62 MB RSS. The CPU is about 41 % busy,
the load average about 5.7, and the die temperature (XADC) about 62 °C.
