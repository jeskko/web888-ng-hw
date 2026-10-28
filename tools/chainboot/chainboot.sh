#!/bin/sh
# Start another kernel from this one (chainboot.ko; no kexec here).
#   chainboot.sh ZIMAGE DTB INITRD|- [go]
# Without "go": a dry run (everything prepared and checked, nothing started).
# The hardware watchdog is the caller's: arm it first (wdt hang 516), so a
# new kernel that never takes over ends in a reset to the stock image.
set -eu
[ $# -ge 3 ] || { echo "usage: $0 ZIMAGE DTB INITRD|- [go]" >&2; exit 2; }
here=$(dirname "$0")
sym() { awk -v s="$1" '$3 == s { print "0x" $1; exit }' /proc/kallsyms; }
R=$(sym soft_restart); P=$(sym kernel_restart_prepare); F=$(sym kernel_read_file_from_path_initns)
for v in "$R" "$P" "$F"; do
    case $v in 0x00000000|"") echo "kernel addresses hidden or missing (kptr_restrict?)" >&2; exit 1 ;; esac
done
for c in /sys/devices/system/cpu/cpu[1-9]*; do
    [ -e "$c/online" ] && [ "$(cat "$c/online")" = 1 ] && echo 0 > "$c/online"
done
[ "$(cat /sys/devices/system/cpu/online)" = 0 ] || { echo "other CPUs still online" >&2; exit 1; }
init=""; [ "$3" = - ] || init="initrd=$3"
go=0; [ "${4:-}" = go ] && go=1
sync
exec insmod "$here/chainboot.ko" zimage="$1" dtb="$2" $init \
    restart="$R" prepare="$P" readfile="$F" go=$go
