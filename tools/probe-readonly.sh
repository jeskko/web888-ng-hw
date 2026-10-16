#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Read-only inventory of a running Web-888. Safe on a live unit:
# no /dev/zynqsdr open (driver is single-opener, the server holds it),
# no /dev/mem, no writes outside /tmp, no service restarts.
# Usage: ssh root@unit 'sh -s' < tools/probe-readonly.sh > probe.txt 2>&1

sec() { printf '\n===== %s\n' "$*"; }
run() { sec "$*"; sh -c "$*" 2>&1; }

run 'date; uptime; uname -a'
run 'cat /etc/os-release /etc/alpine-release'
run 'cat /proc/cmdline'
run 'cat /proc/cpuinfo; cat /proc/meminfo | head -5'
run 'dmesg'
run 'ip -d link; ip addr'
run 'cat /proc/iomem'
run 'cat /proc/interrupts'
run 'cat /proc/devices; ls -l /dev'
run 'lsmod; ls /sys/module | head -200'
run 'cat /proc/mtd; cat /proc/partitions; mount; df -h'
run 'ls -laR /sys/class/fpga_manager /sys/class/fpga_region 2>/dev/null; cat /sys/class/fpga_manager/*/state /sys/class/fpga_manager/*/name 2>/dev/null'
run 'ls -l /sys/class/misc/zynqsdr; cat /sys/class/misc/zynqsdr/dev /sys/class/misc/zynqsdr/uevent'
run 'cat /proc/device-tree/model; echo; cat /proc/device-tree/compatible | tr "\0" " "'
run 'command -v dtc >/dev/null && dtc -I fs -O dts /proc/device-tree 2>/dev/null || find /proc/device-tree -maxdepth 3 | sort'
run 'ls -l /proc/device-tree/reserved-memory 2>/dev/null; for f in /proc/device-tree/reserved-memory/*/reg; do echo $f; od -An -tx1 $f; done 2>/dev/null'
run 'cat /proc/sys/vm/*cma* 2>/dev/null; grep -i cma /proc/meminfo'
run 'ps -o pid,ppid,user,vsz,rss,args 2>/dev/null || ps'
run 'for p in $(pidof websdr websdr.bin kiwi.bin web888 2>/dev/null) $(pgrep -f "websdr|kiwi" 2>/dev/null); do echo "--- pid $p: $(tr "\0" " " < /proc/$p/cmdline)"; ls -l /proc/$p/exe /proc/$p/cwd; ls -l /proc/$p/fd; cat /proc/$p/maps; cat /proc/$p/status | grep -i -E "threads|vm|cpus"; done'
run 'netstat -tlnup 2>/dev/null || ss -tlnup'
run 'ls -laR /boot /media/mmcblk0p1 2>/dev/null | head -200'
run 'find / -xdev \( -name "*.bit" -o -name "*.bit.bin" -o -name "*.bin" -o -name "*.dtb" -o -name "boot.bin" -o -name "BOOT.BIN" \) -size +100k 2>/dev/null | while read f; do sha256sum "$f"; ls -l "$f"; done'
run 'ls -la /root /etc/init.d /etc/local.d 2>/dev/null; cat /etc/local.d/*.start 2>/dev/null; rc-status -a 2>/dev/null'
run 'ls /sys/bus/i2c/devices; for d in /sys/bus/i2c/devices/*; do echo "$d $(cat $d/name 2>/dev/null)"; done'
run 'ls /sys/class/gpio /sys/class/leds /sys/class/hwmon 2>/dev/null; cat /sys/bus/iio/devices/iio:device0/in_temp0_* 2>/dev/null'
run 'cat /sys/devices/soc0/* 2>/dev/null'
sec done
