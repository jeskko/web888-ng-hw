# OS base for the open firmware

Status: **decided 2026-10-22: Yocto + RAUC**, built on a self-hosted runner. Decides what the open Web-888 image is built
on once it no longer reuses the vendor's Alpine release.

## Requirements

1. **SD card read-only in normal operation**; written only when the
   configuration changes and on updates.
2. Survives power loss at any moment (units are remote, nobody on site).
3. Safe remote updates, ideally A/B with automatic rollback.
4. Small RAM footprint: 512 MB in total, most of it for the SDR server.
5. Reproducible builds on a standard GitHub Actions runner.
6. Easy to add our parts: FSBL/boot loader, kernel + DT, bitstream,
   `web888d` (static musl), optional decoders as separate processes.
7. Mainline LTS kernel with `fpga_manager`; time without an RTC (NTP,
   GPS PPS through gpsd/chrony).
8. Low upkeep for a small volunteer project.

## Options (state in October 2026)

| base | armv7/Zynq | read-only model | updates | effort | footprint | main risk |
|---|---|---|---|---|---|---|
| **Alpine diskless** (vendor's choice; red-pitaya-notes) | good: 3.24 ships armv7 | root in tmpfs; `lbu commit` writes an overlay tarball to FAT | copy files to FAT by hand; no rollback | low | whole userland unpacked into RAM | FAT writes not power-safe, no A/B |
| **Buildroot + RAUC** | excellent; any kernel | squashfs root A/B + small config partition | A/B with U-Boot boot counter, signed bundles | medium | smallest | we track CVEs ourselves (LTS branch helps) |
| **Yocto 6.0 "Wrynose"** (+ meta-xilinx / AMD EDF) | excellent, vendor-backed, LTS to 2030 | `read-only-rootfs` + data partition | meta-rauc / meta-swupdate | high | small | CI needs a self-hosted runner (see below) |
| **Debian armhf** + overlayroot | supported (trixie) | bolted on (overlay on tmpfs) | apt (not atomic) or DIY | medium | large (systemd, ~60–120 MB) | writable by design; armhf long-term future unclear |
| **OpenWrt** | `zynq` target alive (6.18), no Web-888 board | squashfs + **always writable** overlay | sysupgrade, no A/B | medium | very small | overlay model conflicts with requirement 1 |
| NixOS, Fedora IoT, balenaOS, Ubuntu Core | no binary cache / armv7 dropped / no Zynq / heavy | — | — | — | — | not viable |

Footprint figures are estimates, not measurements.

Correction to an earlier assumption: upstream
[red-pitaya-notes](https://github.com/pavel-demin/red-pitaya-notes) has **no
Web-888 target** (checked 2026-10-22). Web-888 support lives only in the
RaspSDR fork, last updated April 2025 (Alpine 3.20, kernel 6.6). Upstream
now uses Alpine 3.24 with a 6.18.38 kernel, its own small second-stage loader instead
of U-Boot, and patches `xilinx_devcfg` back in (`/dev/xdevcfg`) rather
than using `fpga_manager`. Useful as a reference, but not something we can
pick up as is.

## Recommendation

**Yocto 6.0 "Wrynose" (LTS to April 2030) + meta-xilinx + meta-rauc,
U-Boot**, set up with `kas` so a build is one command from a pinned layer
list.

Buildroot and Yocto give the same result on the device: read-only root,
config partition, A/B with rollback. Yocto's usual drawback, CI cost,
doesn't apply because a self-hosted runner is available at no cost. What
remains are its advantages in the build and release process: SBOM, CVE and
licence tooling, tested reproducibility, a 4-year LTS, alignment with
AMD's BSP, product variants and an SDK (details below). Buildroot stays
the fallback if the runner goes away. Alpine is what the vendor ships, but
it has no rollback and its config save writes a tarball to FAT, the least
power-safe write there is.

### Self-hosted runner

The repositories are public, so the runner must not run untrusted code:

* The Yocto workflow runs only on pushes to `main` and on tags, never on
  `pull_request`. PRs from forks build only on GitHub-hosted runners (lint,
  tests, the `kas` config check).
* Ephemeral runner: a fresh VM or container per job, no long-lived
  credentials; release signing keys never live on the runner.
* Network: outbound internet only, no route to the internal network or
  the production unit.
* The same host serves the shared-state cache and the source downloads over
  HTTP (`SSTATE_MIRRORS`, `PREMIRRORS`). Contributors point their local
  builds at it, and incremental builds take minutes. Writes come only from
  the CI job.

### Buildroot vs Yocto in CI

Yocto's documented host needs (140 GB disk, 32 GB RAM) are for a graphical
image. A console image like ours needs less. These are estimates, not
measurements:

| | Buildroot + RAUC | Yocto + meta-xilinx + meta-rauc |
|---|---|---|
| clean build, 4 cores | ~30–60 min | ~2–4 h |
| disk | ~5–10 GB | ~40–60 GB (with `rm_work`) |
| incremental | ~5–15 min with download/ccache cache | ~10–20 min with a warm shared-state cache of 10–30+ GB |
| standard GitHub runner (4 CPU, 16 GB, 14 GB SSD; 10 GB Actions cache) | fits | doesn't fit: self-hosted runner (~8 cores, 32 GB, 200+ GB) or paid runners, plus a shared-state cache server |

On the device both give the same result (read-only squashfs root, config
partition, RAUC A/B with rollback). Yocto's extras are in the build and
release process: SPDX SBOMs, CVE checks and licence manifests, tested
binary reproducibility, a 4-year LTS, AMD BSP alignment (FSBL from the
Vivado hardware export), easy product variants, an SDK. Buildroot covers
the GPL obligations with `legal-info` and has simpler, faster builds, and
its image-only model suits an appliance.

### Proposed SD layout

| part | content | mounted |
|---|---|---|
| p1 FAT | `BOOT.BIN` (FSBL + U-Boot), U-Boot env (two redundant copies) | not mounted in normal operation |
| p2 / p3 | rootfs A / B: squashfs with kernel, DT, bitstream, `web888d` | read-only, never written except by an update |
| p4 ext4 (small) | configuration | read-only; remounted read-write only while saving |
| p5 ext4 (optional) | larger data (recordings, decoder logs) if wanted | user's choice |

* **Config save**: remount p4 read-write, write a temp file, fsync it,
  rename it over the old file, fsync the directory, remount read-only. Use
  `data=journal` or f2fs. A power cut leaves either the old or the new file.
* **Updates**: a RAUC bundle carries rootfs, kernel, DT and bitstream and
  goes to the inactive slot. U-Boot boots it with a try counter; `web888d`
  marks the slot good once the radio is streaming, otherwise the next boot
  falls back. `BOOT.BIN` is the one item without A/B: update it rarely, by
  writing a copy and renaming it.
* **Steady-state writes**: only the U-Boot boot counter (a few bytes per
  boot). Logs go to tmpfs or remote syslog; no periodic clock stamps
  (chrony + gpsd/PPS set the time).
* **Licences**: Buildroot's GPL-2.0 does not reach the images it builds.
  RAUC is LGPL-2.1. The open kernel driver stays GPL-2.0-or-later
  (compatible with the kernel); everything else as before.

### Testing in the emulator

The QEMU virtual Web-888 (`emu/`) can boot the new image as well. That lets
us test A/B updates, rollback after a failed boot, and power cuts during a
config save or an update, all offline and repeatable. Hardware time is
then only needed for what the emulator can't model.

### Steps

1. `meta-web888` layer + `kas` config: machine `web888` (Zynq-7010, our
   DT, U-Boot with redundant env), 6.18 LTS kernel with `fpga_manager`,
   image recipe with a squashfs root, our packages (`web888d`, bitstream).
   **Done** (web888-ng-os; still the vendor-derived DT and no boot files
   for the real board).
2. Boot it in the emulator against `web888-pl`. The stock `zynqsdr` driver
   is built into the vendor kernel and is not available on ours, so radio
   access on this image needs the open kernel driver. **Done**: the open
   driver (`driver/`) loads, and web888d serves HPSDR through it.
3. RAUC A/B + config partition; power-loss tests in the emulator. The
   configuration partition is done; RAUC A/B and the power-loss tests
   are not.
4. CI on the self-hosted runner builds the image. **Done**; the bitstream
   comes from a web888-ng-hw release (recipe `web888-bitstream`, checked
   by SHA-256).

The open driver works in the emulator but is untested on hardware. Until
it is, units run the vendor firmware, with web888d on it where wanted (as
on the production unit since 2026-10-28; `hardware-test-plan.md`).

## Switching the production unit remotely (evaluated 2026-10-29)

The unit can't be power-cycled or reached locally, so the first boot of
our image must not depend on a working image. Facts in
`stock-unit-facts.md` §Boot chain: one FAT partition, no U-Boot, the boot
ROM always loads `BOOT.BIN`, the stock kernel has no kexec.

**Proposed: the stock image stays the golden image; ours is chain-loaded
under the hardware watchdog.** `BOOT.BIN` and the partition table are
never touched.

1. From stock Linux, set the SWDT's longest timeout (`wdt set 516`:
   programmed, then stopped); the module starts it right before the
   shutdown (armed through the driver, the shutdown would stop it: the
   reboot notifier stops an active watchdog), reset on expiry, unkicked.
2. A small kernel module for the stock 6.6.110-xilinx kernel (kexec's
   job without kexec, `tools/chainboot`): CPU1 offlined first, our
   zImage, DTB and initramfs in pages outside their destinations, devices
   shut down as for a reboot, `soft_restart` into a relocation stub.
3. Our image keeps the watchdog running (`cdns_wdt` built in,
   `clk_ignore_unused` so its clock isn't gated) and starts kicking it only
   when web888d streams **and** someone confirms over the network within
   the timeout. Its root is a squashfs file on the FAT, mounted read-only.
4. Anything that goes wrong (a hang in the module, the jump, our kernel,
   the driver, the PL bus, no network) ends in a watchdog reset; the boot
   ROM loads the stock `BOOT.BIN` and the unit is back as it is today.
5. Later, for every boot: an early service in the stock apkovl
   chain-loads ours, with an attempt counter in REBOOT_STATUS[31:24]
   (kept over non-POR resets) to stop after failures. A new `BOOT.BIN`
   only once a test unit has run it.

What the safety net rests on, and how to check it before the first try:

| assumption | check |
|---|---|
| a SWDT timeout resets this board and it comes back on stock | **shown** (2026-10-28, `hardware-test-plan.md` §0): `wdt hang 30` and two real AXI hangs, back on stock in about 25 s each time |
| it can be armed for several minutes, with nothing kicking it, through a jump | `wdt hang` arms it through the driver and leaves it unkicked; the stock driver has no shutdown hook, so nothing stops it. **516 s accepted** and read back on the unit, disarmed cleanly (2026-10-29) |
| the new kernel doesn't stop or ungate the SWDT before our userspace runs | `cdns_wdt` source; the module's dry run (below) shows the timer still counting after the jump |
| the module works on the stock kernel | **in the emulator** (`tools/chainboot`, 2026-10-29): built against mainline 6.6.110 + the vendor's public patch and defconfig, with the stock modules' CRCs; on the unit's own `boot.bin` the dry run loads and frees cleanly, and `go` boots the stock kernel again (all RAM, both CPUs, initramfs, the stock server streaming). **Dry run on the unit passed** (2026-10-29, watchdog armed unkicked for 300 s during it: loads, reads the images, frees, kernel tainted only as out-of-tree, web888d unaffected). **Chain-loading the stock kernel on the unit worked** (2026-10-29: back in about a minute with `chainboot=1`), but the watchdog was off afterwards: the shutdown's reboot notifier had stopped it. Fixed (the module starts it itself); **repeated with the fix: the watchdog ran through the shutdown, the jump and the new kernel's boot** (ZMR 0x33, 516 s, read after the jump; then disarmed) |
| our image mounts the FAT read-only | image config, checked in the emulator |

What would still need hands on site: a hardware state that survives a
watchdog reset but not a power cycle (none seen in the three resets so
far).

## Not verified

* Debian's long-term armhf plans; Ubuntu 26.04 armhf images.
* No public RAUC example for Zynq-7000 was found. The mechanism is plain
  U-Boot, so the risk is low.

## Sources

* red-pitaya-notes: <https://github.com/pavel-demin/red-pitaya-notes> (`scripts/alpine.sh`), <https://pavel-demin.github.io/red-pitaya-notes/alpine/>; fork <https://github.com/RaspSDR/red-pitaya-notes>
* Alpine downloads: <https://www.alpinelinux.org/downloads>
* Debian trixie: <https://www.debian.org/releases/trixie/>; armhf baseline discussion <https://lists.debian.org/debian-arm/2025/10/msg00063.html>
* Fedora ARMv7 retirement: <https://www.fedoraproject.org/wiki/Changes/RetireARMv7>
* NixOS on ARM: <https://wiki.nixos.org/wiki/NixOS_on_ARM>
* Buildroot: <https://buildroot.org/download.html>, <https://fosdem.org/2026/schedule/event/1y-of-buildroot-lts>
* Yocto 6.0: <https://www.cnx-software.com/2026/05/14/yocto-project-6-0-wrynose-released-with-linux-6-18-lts/>
* AMD EDF: <https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/embedded-software/embedded-development-framework.html>
* OpenWrt zynq target: <https://github.com/openwrt/openwrt/tree/main/target/linux/zynq>
* RAUC in U-Boot: <https://docs.u-boot.org/en/latest/develop/bootstd/rauc.html>
