#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Boot the virtual Web-888: stock kernel + initramfs from boot.bin, the SD
# image from the release zip, the emulated FPGA logic (web888-pl).
#
#   ./run.sh [options] [-- extra qemu args]
#
# Options:
#   --mac XX:XX:XX:XX:XX:XX  board MAC (EEPROM @0x10 and the emulated NIC)
#   --eeprom-mac XX:...      EEPROM @0x10 only (ff:ff:ff:ff:ff:ff = blank):
#                            the NIC keeps --mac, standing in for what the
#                            FSBL leaves in the GEM's address registers
#   --dna 0xHEX              FPGA device DNA reported in STS 0x0C (57 bit)
#   --boot-mode MODE         the SLCR boot-mode pins: qspi (default), sd,
#                            nor, jtag (U-Boot picks its environment by it)
#   --stock-sig              report the stock HF signature 0xAA55020C
#   --sig 0xHEX              any signature (low nibble = RX channels)
#   --scene "f:dB[:am[:depth]],..."  RF scene (Hz, dBFS; optional AM)
#   --noise DBFS_HZ          white noise density ("" = none)
#   --web-port N             host port forwarded to guest 8073 (default 8073)
#   --ssh-port N             host port forwarded to guest 22 (default 2222)
#   --hpsdr-port N           host UDP port forwarded to guest 1024 (default 1024)
#   --smp N                  CPUs (default 2)
#   --bootrom                boot as the board's boot ROM does: BOOT.BIN
#                            from the SD card's first (FAT) partition, its
#                            first-stage loader (FSBL / U-Boot SPL) at 0 on
#                            CPU0, CPU1 off until released (as Linux's
#                            SMP bring-up expects); no --kernel/--initrd/
#                            --dtb. Use --boot-mode sd with U-Boot.
#   --kernel FILE            kernel zImage instead of the vendor one
#   --initrd FILE|none       initramfs instead of the vendor one, or none
#   --sd FILE                SD card image instead of build/fw/sd.img
#   --append ARGS            kernel command line (overrides the DT's)
#   --dtb FILE               device tree instead of build/fw/web888-emu.dtb
#   --snapshot               don't write changes back to the SD image
#   --log                    log PL register writes / Si5351 writes to stderr
#
# The stock zynqsdr driver hands the server zeros (from the first NTP
# clock step, i.e. about a minute after boot) unless the eth0 MAC belongs
# to the FPGA DNA (its genuine-unit check). Give the emulator a matching
# pair, e.g. your own unit's: --dna <GET_DNA from zynqsdr_probe> --mac
# <that unit's eth0 MAC>. Defaults can go in local.conf next to this
# script (not versioned; shell syntax, sets MAC= and DNA=).
set -euo pipefail
. "$(dirname "$0")/scripts/common.sh"

QEMU=${QEMU:-$BUILD/qemu-system-arm}
MAC=02:88:88:00:00:01
DNA=
SIG=
SCENE=
NOISE=
NOISE_SET=0
WEB_PORT=8073
SSH_PORT=2222
HPSDR_PORT=1024
SMP=2
SNAPSHOT=
LOG=0
KERNEL=
INITRD=
SD=
APPEND=
EXTRA=()
[ -f "$EMU/local.conf" ] && . "$EMU/local.conf"

while [ $# -gt 0 ]; do
    case "$1" in
    --mac) MAC=$2; shift 2 ;;
    --eeprom-mac) EEPROM_MAC=$2; shift 2 ;;
    --boot-mode) BOOT_MODE=$2; shift 2 ;;
    --dna) DNA=$2; shift 2 ;;
    --stock-sig) SIG=0xAA55020C; shift ;;
    --sig) SIG=$2; shift 2 ;;
    --scene) SCENE=$2; shift 2 ;;
    --noise) NOISE=$2; NOISE_SET=1; shift 2 ;;
    --web-port) WEB_PORT=$2; shift 2 ;;
    --ssh-port) SSH_PORT=$2; shift 2 ;;
    --hpsdr-port) HPSDR_PORT=$2; shift 2 ;;
    --smp) SMP=$2; shift 2 ;;
    --bootrom) BOOTROM=1; shift ;;
    --kernel) KERNEL=$2; shift 2 ;;
    --initrd) INITRD=$2; shift 2 ;;
    --sd) SD=$2; shift 2 ;;
    --append) APPEND=$2; shift 2 ;;
    --dtb) DTB=$2; shift 2 ;;
    --snapshot) SNAPSHOT=,snapshot=on; shift ;;
    --log) LOG=1; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    -h|--help) sed -n '3,33p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
    esac
done

KERNEL=${KERNEL:-$FW/zImage}
SD=${SD:-$FW/sd.img}
INITRD=${INITRD:-$FW/initramfs.cpio.gz}
if [ "${BOOTROM:-0}" = 1 ]; then
    [ -e "$SD" ] || { echo "missing $SD" >&2; exit 1; }
    ROM=$EMU/build/bootrom
    mkdir -p "$ROM"
    # BOOT.BIN from the first partition, as the boot ROM reads it
    off=$(sfdisk -d "$SD" | sed -n 's/.*: start= *\([0-9]*\),.*/\1/p' | head -n 1)
    MTOOLS_SKIP_CHECK=1 mcopy -i "$SD@@$((off * 512))" ::BOOT.BIN "$ROM/BOOT.BIN" ||
        { echo "no BOOT.BIN on $SD" >&2; exit 1; }
    # its first stage (boot header: source offset 0x30, length 0x34)
    python3 -I - "$ROM/BOOT.BIN" "$ROM/fsbl.bin" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
assert d[0x24:0x28] == b'XNLX', 'not a Zynq boot image'
off, ln = struct.unpack_from('<II', d, 0x30)
open(sys.argv[2], 'wb').write(d[off:off + ln])
PY
    # CPU0 starts at its reset vector, 0; CPU1 stays powered off until
    # the SLCR releases it (the web888 machine), where the boot ROM would
    # park it
    BOOT=(-device "loader,file=$ROM/fsbl.bin,addr=0x0,force-raw=on")
else
BOOT=(-kernel "$KERNEL")
[ "$INITRD" != none ] && BOOT+=(-initrd "$INITRD")
[ -n "$APPEND" ] && BOOT+=(-append "$APPEND")
for f in "$QEMU" "$KERNEL" "$SD"; do
    [ -e "$f" ] || { echo "missing $f (run build-qemu.sh, make-sdimage.sh)" >&2; exit 1; }
done
if [ -z "${DTB:-}" ]; then
    DTB=$FW/web888-emu.dtb
    [ -e "$DTB" ] || "$EMU/make-dtb.sh"
fi
BOOT+=(-dtb "$DTB")
fi

PL=()
[ -n "$DNA" ] && PL+=(-global "web888-pl.dna=$DNA")
[ -n "$SIG" ] && PL+=(-global "web888-pl.signature=$SIG")
[ -n "$SCENE" ] && PL+=(-global "web888-pl.scene=$SCENE")
[ "$NOISE_SET" = 1 ] && PL+=(-global "web888-pl.noise=$NOISE")
if [ "$LOG" = 1 ]; then
    PL+=(-global web888-pl.log=on -global web888-si5351.log=on)
fi

exec "$QEMU" -M "web888,mac=${EEPROM_MAC:-$MAC}${BOOT_MODE:+,boot-mode=$BOOT_MODE}" -m 512M -smp "$SMP" \
    -display none -serial mon:stdio \
    "${BOOT[@]}" \
    -drive "if=sd,index=0,format=raw,file=$SD$SNAPSHOT" \
    -nic "user,mac=$MAC,hostfwd=tcp::$WEB_PORT-:8073,hostfwd=tcp::$SSH_PORT-:22,hostfwd=udp::$HPSDR_PORT-:1024" \
    "${PL[@]}" "${EXTRA[@]}"
