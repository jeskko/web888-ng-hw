#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# web888-ng-os's SD card image in the emulator, booted as the board boots
# it (--bootrom: BOOT.BIN = U-Boot SPL from the FAT, U-Boot, a root slot):
#
#   tests/sd-image.sh IMAGE.wic[.xz] [WORKDIR]
#
# On a writable copy of the image (the guest writes to it as to a card):
#   1. first boot with a web888.txt (hostname, admin password, SSH key):
#      the ADC clock set up by U-Boot, slot A, web888-setup and web888d
#      running, the slot marked good; after power-off the password line
#      reads "(set)" and web888-setup.log is on the FAT
#   2. static network from web888.txt; the log is rewritten only because
#      it changed
#   3. slot A without a kernel: U-Boot uses up its tries, slot B boots
#
# Each root slot gets the emulator's DT changes (scripts/emu-dtb.sh). The
# checks log in over SSH with a key made here. Ports: SSH 22322, web 28173.
set -euo pipefail
EMU=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 1 ] || { sed -n '4,17p' "$0" >&2; exit 2; }
IMAGE=$1
W=${2:-$EMU/build/sd-image-test}
SSH_PORT=22322 WEB_PORT=28173
MAC=02:00:5e:88:80:01
export VM_DIR=$W/vm VM_SNAPSHOT=0
VM=$EMU/tests/vm.sh
export MTOOLS_SKIP_CHECK=1

mkdir -p "$W"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
check() { # check DESCRIPTION COMMAND...
	local d=$1
	shift
	if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

IMG=$W/sd.img
case $IMAGE in
*.xz) xz -dc "$IMAGE" > "$IMG" ;;
*) cp --sparse=always "$IMAGE" "$IMG" ;;
esac
truncate -s 2G "$IMG"

# partition N's start (bytes) and size (sectors)
part() {
	sfdisk -d "$IMG" | sed -n "s|^$IMG$1 : start= *\([0-9]*\), size= *\([0-9]*\).*|\1 \2|p"
}
read -r p1 _ < <(part 1)
FAT="$IMG@@$((p1 * 512))"

# debugfs on a root slot: extract, run, put back
slot_debugfs() { # slot_debugfs PARTNO < commands
	local start size
	read -r start size < <(part "$1")
	dd if="$IMG" of="$W/slot.ext4" bs=512 skip="$start" count="$size" status=none
	debugfs -w "$W/slot.ext4" > /dev/null 2>&1
	dd if="$W/slot.ext4" of="$IMG" bs=512 seek="$start" conv=notrunc status=none
	rm -f "$W/slot.ext4"
}

for p in 2 3; do
	read -r start size < <(part $p)
	dd if="$IMG" of="$W/slot.ext4" bs=512 skip="$start" count="$size" status=none
	debugfs -R "dump /boot/zynq-web888.dtb $W/board.dtb" "$W/slot.ext4" > /dev/null 2>&1
	rm -f "$W/slot.ext4"
	[ -s "$W/board.dtb" ] || { echo "no /boot/zynq-web888.dtb in partition $p" >&2; exit 1; }
	"$EMU/scripts/emu-dtb.sh" "$W/board.dtb" "$W/emu.dtb"
	slot_debugfs $p <<EOF
rm /boot/zynq-web888.dtb
write $W/emu.dtb /boot/zynq-web888.dtb
EOF
done

rm -f "$W/key" "$W/key.pub"
ssh-keygen -q -t ed25519 -N '' -C sd-image-test -f "$W/key"
SSH=(ssh -q -p $SSH_PORT -i "$W/key" -o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1)
on() { "${SSH[@]}" "$@"; }

boot() { # boot WAIT_REGEX SECS
	"$VM" start --bootrom --boot-mode sd --sd "$IMG" --mac $MAC --log \
		--ssh-port $SSH_PORT --web-port $WEB_PORT --hpsdr-port 21124
	"$VM" wait "$1" "$2"
}
wait_ssh() {
	for _ in $(seq 60); do
		on true 2> /dev/null && return 0
		sleep 5
	done
	return 1
}
power_off() {
	on poweroff 2> /dev/null || true
	"$VM" wait '(reboot: (Power down|System halted)|System halted)' 120 || true
	"$VM" stop
}
txt() { # web888.txt from lines
	printf '%s\r\n' "$@" | mcopy -o -i "$FAT" - ::web888.txt
}
fat() { mcopy -i "$FAT" "::$1" - 2> /dev/null | tr -d '\r'; }

echo "== 1. first boot"
txt "hostname = emu888" "admin_password = test-password-1" \
	"ssh_key = $(cat "$W/key.pub")"
boot 'login:' 900 || bad "no login prompt"
log=$("$VM" log)
check "U-Boot set the ADC clock" grep -q 'web888: ADC clock 122.88 MHz' <<< "$log"
# the Si5351's registers as the last writes left them (--log), against
# 122.88 MHz from 24.576 MHz: PLLA 30, MultiSynth0 6, CLK0 on, 8 mA
si=$(awk '/si5351: reg/ { r[$3 + 0] = $5 } END {
	n = split("3:0xfe 16:0x4f 26:0xa0 27:0x00 28:0x00 29:0x0d 30:0x00 31:0xf0 32:0x00 33:0x00 42:0x00 43:0x01 44:0x00 45:0x01 46:0x00 47:0x00 48:0x00 49:0x00 183:0xc0", w, " ")
	for (i = 1; i <= n; i++) { split(w[i], kv, ":"); if (r[kv[1]] != kv[2]) print "reg " kv[1] " = " r[kv[1]] ", want " kv[2] }
}' <<< "$log")
check "Si5351 registers for 122.88 MHz${si:+ ($si)}" test -z "$si"
check "Si5351 written at all" grep -q 'si5351: reg' <<< "$log"
check "slot A chosen" grep -q 'web888: slot A' <<< "$log"
wait_ssh || bad "no SSH with the key from web888.txt"
check "root slot A" on 'grep -q rauc.slot=A /proc/cmdline'
check "eth0 (not renamed)" on 'test -e /sys/class/net/eth0'
check "web888-setup ran" on 'systemctl is-active web888-setup'
check "hostname from web888.txt" on 'test "$(hostname)" = emu888'
check "web888d running" on 'systemctl is-active web888d'
check "admin hash in /config" on 'grep -q admin_hash /config/web888d.toml'
check "/boot read-only again" on 'grep -q " /boot vfat ro," /proc/mounts'
check "web UI answers" curl -sk --max-time 20 "https://127.0.0.1:$WEB_PORT/"
on 'sleep 75; systemctl status web888-boot-ok --no-pager' > "$W/boot-ok.txt" 2>&1 || true
check "slot A marked good (tries 3)" on 'test "$(fw_printenv -n BOOT_A_LEFT)" = 3'
power_off
check "password line reads (set)" grep -q '^admin_password = (set)$' < <(fat web888.txt)
check "no made-up password file" test -z "$(fat web888-password.txt)"
fat web888-setup.log > "$W/setup1.log"
check "web888-setup.log on the FAT" grep -q 'no problems' "$W/setup1.log"
cat "$W/setup1.log"

echo "== 2. static network"
txt "hostname = emu888" "admin_password = (set)" "network = static" \
	"address = 10.0.2.15/24" "gateway = 10.0.2.2" "dns = 10.0.2.3" \
	"ssh_key = $(cat "$W/key.pub")"
boot 'login:' 900 || bad "no login prompt"
wait_ssh || bad "no SSH on the static address"
check "static address" on 'grep -q "^Address=10.0.2.15/24" /run/systemd/network/10-web888.network'
check "no DHCP" on '! grep -q "^DHCP" /run/systemd/network/10-web888.network'
check "admin password unchanged" on 'journalctl -b -u web888-setup | grep -q "admin password: as before"'
power_off
fat web888-setup.log > "$W/setup2.log"
check "log says static" grep -q 'network: static 10.0.2.15/24' "$W/setup2.log"

echo "== 3. slot A broken: slot B"
slot_debugfs 2 <<EOF
rm /boot/uImage
rm /boot/zImage
EOF
boot '(login:|no slot has tries left)' 1500 || bad "no login prompt"
log=$("$VM" log)
check "slot A failed until out of tries" grep -q 'web888: slot A did not boot' <<< "$log"
check "slot B chosen" grep -q 'web888: slot B' <<< "$log"
wait_ssh || bad "no SSH on slot B"
check "root slot B" on 'grep -q rauc.slot=B /proc/cmdline'
power_off

echo
if [ $fails = 0 ]; then
	echo "all checks passed"
else
	echo "$fails checks failed (console log: $VM_DIR/console.log)"
	exit 1
fi
