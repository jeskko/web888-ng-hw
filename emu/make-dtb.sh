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
#   * cpu@0: operating-points replaced by the one rate Linux reads from
#     QEMU's SLCR at boot (166.666 MHz), so cpufreq never changes the
#     clock. With the
#     vendor 666/333 MHz table cpufreq-dt tries to switch, clk_set_rate
#     fails with -EBUSY and cpufreq_online() BUG()s. Without any table
#     there is no cpufreq sysfs, and the stock server dies reading
#     scaling_cur_freq.
#   * A9 global and TWD timers clocked from a fixed 100 MHz clock: QEMU's
#     models tick every 10 ns whatever the SLCR says, while Linux would
#     derive CPU/2 from the clock tree (83.33 MHz here: guest time 20 %
#     fast).
#   * usb@e0002000 and its ULPI phy disabled (QEMU's chipidea model has no
#     ULPI viewport; probing only times out).
#
# NG_NODE=1 also turns the vendor `zynqsdr` node into the web888-ng one
# (compatible "web888-ng,sdr" with `reg`, see driver/README.md), for the
# open driver:
#
#   ./make-dtb.sh           -> build/fw/web888-emu.dtb
#   NG_NODE=1 ./make-dtb.sh -> build/fw/web888-emu-ng.dtb   (run.sh --dtb)
set -euo pipefail
. "$(dirname "$0")/scripts/common.sh"

DTS=${DTS:-$EMU/../../upstream/firmware-20260919/boot.dts}
NG_NODE=${NG_NODE:-0}
NAME=web888-emu$([ "$NG_NODE" = 1 ] && echo -ng)
OUT=$FW/$NAME.dtb
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
	emu_timer_clk: emu-timer-clk {
		compatible = "fixed-clock";
		#clock-cells = <0>;
		clock-frequency = <100000000>;
	};
	cpus {
		cpu@0 {
			operating-points = <166666 1000000>;
		};
	};
	axi {
		timer@f8f00200 {
			clocks = <&emu_timer_clk>;
		};
		timer@f8f00600 {
			clocks = <&emu_timer_clk>;
		};
		usb@e0002000 {
			status = "disabled";
		};
	};
	phy0 {
		status = "disabled";
	};
};
EOF
    [ "$NG_NODE" = 1 ] && cat <<EOF

&{/zynqsdr} {
	compatible = "web888-ng,sdr";
	reg = <0x40000000 0xa0>, <0x41000000 0x40>, <0x42000000 0x1000>;
};
EOF
} > "$FW/$NAME.dts"

dtc -q -I dts -O dtb -o "$OUT" "$FW/$NAME.dts"
echo ">> $OUT"
