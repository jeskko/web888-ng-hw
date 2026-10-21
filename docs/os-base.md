# OS base for the open firmware

Status: proposal, 2026-10-22. Decides what the open Web-888 image is built
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

**Buildroot (LTS branch) + U-Boot + RAUC**, with Alpine diskless as a
bring-up platform only if we need a quick image before that exists.

Buildroot is the only option that meets every requirement without fighting
the base. Yocto would also do, but costs far more to maintain and to build
in CI. Alpine is what the vendor ships and is quick to start, but it has no
rollback and its config save writes a tarball to FAT, which is the least
power-safe write there is.

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

1. Buildroot external tree (`BR2_EXTERNAL`) in this repo: Zynq-7010
   defconfig, 6.18 LTS kernel, our DT, U-Boot with redundant env.
2. Boot it in the emulator against `web888-pl`. The stock `zynqsdr` driver
   is built into the vendor kernel and is not available on ours, so radio
   access on this image needs the open kernel driver.
3. RAUC A/B + config partition; power-loss tests in the emulator.
4. CI builds the image; the Vivado bitstream comes in as an artifact.

Until the open kernel driver exists, the vendor kernel (with the stock
driver) stays in use, as planned.

## Not verified

* Which Buildroot branch becomes the next LTS (2025.02 is LTS until March 2028).
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
