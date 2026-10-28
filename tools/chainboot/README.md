# chainboot: start another kernel without kexec

The stock Web-888 kernel (6.6.110-xilinx) has no kexec. This module does
its job, so a unit nobody can reach can try a new kernel with the stock
image as the fallback (`docs/os-base.md`, "Switching the production unit
remotely"): the hardware watchdog armed first, a new kernel that never
takes over ends in a reset, and the boot ROM starts the stock `BOOT.BIN`.

```sh
wdt set 516                      # (tools/wdt) the timeout, left stopped
chainboot.sh ZIMAGE DTB INITRD   # dry run: prepared, checked, freed
chainboot.sh ZIMAGE DTB INITRD go
```

* **The watchdog**: the module starts it itself, just before the
  shutdown, from the timeout `wdt set` left in its counter register, and
  nothing kicks it. Armed through the driver instead (`wdt hang`), it
  would be stopped by the shutdown: the watchdog core's reboot notifier
  stops an active watchdog on `SYS_DOWN`, and `SYS_RESTART` is
  `SYS_DOWN`. The first chain-load on the unit (2026-10-29) ran like that,
  without the safety net from the shutdown on (it worked). The module
  refuses without a long timeout set (prescaler 4096, about 5 min or
  more), or while the watchdog runs; `nowdt=1` skips it (the emulator has
  no watchdog). The driver's probe leaves a running watchdog alone.

* `chainboot.sh` takes the addresses of `soft_restart`,
  `kernel_restart_prepare` and `kernel_read_file_from_path_initns` from
  `/proc/kallsyms` (not exported), takes the other CPU offline, and loads
  the module.
* The module reads the images into pages outside where they go (DTB
  0x01f00000, zImage 0x02000000, initrd 0x04000000), shuts devices down
  as for a reboot, and calls `soft_restart` (MMU, caches and L2 off) into
  a copy of `reloc.S`, which copies the pages into place and enters the
  zImage with r2 = the DTB. The DTB's bootargs must hold
  `initrd=0x04000000,SIZE`.
* The zImage must sit in the first 128 MB: the decompressor takes RAM to
  start at its load address rounded down to 128 MB.

## Building

The vendor publishes neither this kernel's config nor its headers.
Mainline 6.6.110 with red-pitaya-notes' `linux-6.6.patch` and
`xilinx_zynq_defconfig` (RaspSDR, branch `web888`; an empty
`drivers/net/wireless/realtek/rtl8188eu/` for the Kconfig) gives the same
`struct module` (640 bytes) but other symbol CRCs (`module_layout`
0x1d076ff6 here, 0x85b0361b on the unit). So the module uses the stock
CRCs: `symvers.py` collects them from the stock modules' `__versions`
(2315 symbols from the unit's `/lib/modules`), and modpost takes that file
as `KBUILD_EXTRA_SYMBOLS`. Every symbol the module imports has a stock CRC.

```sh
ssh UNIT 'cd /lib/modules/6.6.110-xilinx && tar cf - $(find . -name "*.ko")' | tar xf - -C mods
python3 -I symvers.py mods > stock.symvers
make KDIR=/path/to/linux-6.6.110 SYMVERS=$PWD/stock.symvers
```

## Tested

In the emulator (`emu/`, the unit's own `boot.bin`), 2026-10-29: the dry
run loads on the stock kernel and frees everything; `go` boots the stock
kernel again with a marked command line, all 512 MB, both CPUs, the
initramfs, the modloop, and the stock server streaming.

On the production unit, 2026-10-29: chain-loading the stock kernel
worked (back in about a minute, `chainboot=1` in `/proc/cmdline`, all
RAM, both CPUs, the stock server), but the watchdog was found stopped
afterwards (above). With the fix, `wdt set 516` and the dry run read the
timeout back (CCR 0x356b) and pass the check. Earlier the dry run (watchdog armed, not
kicked, for 300 s around it) loads, reads the images, frees them; only
the out-of-tree taint; web888d went on undisturbed. BusyBox `insmod`
runs a failing init twice (`finit_module`, then `init_module`): harmless
for the dry run's `-EAGAIN`; with `go` the first never returns.
