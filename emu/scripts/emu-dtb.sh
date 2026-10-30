#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The emulator's device tree changes (make-dtb.sh explains each) applied to
# a built Zynq-7000 DTB, e.g. the one web888-ng-os installs in a root slot
# (/boot/zynq-web888.dtb), which U-Boot loads under --bootrom:
#
#   scripts/emu-dtb.sh IN.dtb OUT.dtb
#
# cpu@0 gets QEMU's one rate (166.666 MHz), the A9 global and TWD timers a
# fixed 100 MHz clock, USB and its ULPI phy are disabled.
set -euo pipefail
[ $# = 2 ] || { sed -n '4,11p' "$0" >&2; exit 2; }
in=$1 out=$2
cp "$in" "$out"
# a phandle no compiled tree uses (dtc numbers from 1)
ph=0x7e570001
fdtput -c "$out" /emu-timer-clk
fdtput -t s "$out" /emu-timer-clk compatible fixed-clock
fdtput -t u "$out" /emu-timer-clk '#clock-cells' 0
fdtput -t u "$out" /emu-timer-clk clock-frequency 100000000
fdtput -t x "$out" /emu-timer-clk phandle $ph
fdtput -t u "$out" /cpus/cpu@0 operating-points 166666 1000000
fdtput -t x "$out" /axi/timer@f8f00200 clocks $ph
fdtput -t x "$out" /axi/timer@f8f00600 clocks $ph
fdtput -t s "$out" /axi/usb@e0002000 status disabled
fdtput -t s "$out" /phy0 status disabled
