#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build the device tree for the emulator from the vendor DT (local copy,
# never committed): the decompiled boot.dts if you have one (DTS=...),
# otherwise the DTB that make-sdimage.sh extracted from boot.bin.
#
# Changes against the vendor DT (all documented in README.md):
#   * bootargs: no "initrd=0x3000000,4M"; QEMU loads the initramfs and
#     passes its location in /chosen.
#   * cpu@0: operating-points removed. QEMU's SLCR clock model does not
#     produce the 666/333 MHz the OPP table lists, and cpufreq-dt then
#     BUG()s while trying to switch to a listed frequency.
#   * usb@e0002000 and its ULPI phy disabled (QEMU's chipidea model has no
#     ULPI viewport; probing only times out).
#
#   ./make-dtb.sh           -> build/fw/web888-emu.dtb
set -euo pipefail
. "$(dirname "$0")/scripts/common.sh"

DTS=${DTS:-$EMU/../../upstream/firmware-20260919/boot.dts}
OUT=$FW/web888-emu.dtb
SRC_DTS=$FW/vendor.dts
mkdir -p "$FW"

if [ -f "$DTS" ]; then
    cp "$DTS" "$SRC_DTS"
elif [ -f "$FW/vendor.dtb" ]; then
    dtc -q -I dtb -O dts -o "$SRC_DTS" "$FW/vendor.dtb"
else
    echo "no vendor DT: set DTS=boot.dts or run make-sdimage.sh first" >&2
    exit 1
fi

BOOTARGS=${BOOTARGS:-console=ttyPS0,115200 earlycon modloop=modloop}

{
    cat "$SRC_DTS"
    cat <<EOF

/* ---- web888 emulator overrides ---- */
/ {
	chosen {
		bootargs = "$BOOTARGS";
	};
	cpus {
		cpu@0 {
			/delete-property/ operating-points;
		};
	};
	axi {
		usb@e0002000 {
			status = "disabled";
		};
	};
	phy0 {
		status = "disabled";
	};
};
EOF
} > "$FW/web888-emu.dts"

dtc -q -I dts -O dtb -o "$OUT" "$FW/web888-emu.dts"
echo ">> $OUT"
