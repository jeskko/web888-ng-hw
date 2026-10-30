#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# web888-ng-os's over-the-air update (RAUC) in the emulator, on its SD card
# image booted as the board boots it:
#
#   tests/ota.sh IMAGE.wic[.xz] BUNDLE.raucb [WORKDIR]
#
#   1. slot A boots; "rauc install http://..." streams the bundle (served
#      here with range requests) into slot B; U-Boot then boots B, which
#      is marked good once web888d runs
#   2. power cut in the middle of an install into slot A: B still boots
#   3. a bad update: the install into A completes but A doesn't boot
#      (its kernel removed); U-Boot uses up A's tries and goes back to B
#
# A slot written by RAUC has the board's device tree; before booting it,
# the test puts the emulator's changes in (scripts/emu-dtb.sh), from the
# guest. Ports: SSH 22323, web 28174, the bundle server 28180.
set -euo pipefail
EMU=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 2 ] || { sed -n '4,18p' "$0" >&2; exit 2; }
IMAGE=$1 BUNDLE=$2
W=${3:-$EMU/build/ota-test}
SSH_PORT=22323 WEB_PORT=28174 HTTP_PORT=28180
MAC=02:00:5e:88:80:02
export VM_DIR=$W/vm VM_SNAPSHOT=0
VM=$EMU/tests/vm.sh
export MTOOLS_SKIP_CHECK=1

mkdir -p "$W/www"
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

part() { # partition N's start (bytes) and size (sectors)
	sfdisk -d "$IMG" | sed -n "s|^$IMG$1 : start= *\([0-9]*\), size= *\([0-9]*\).*|\1 \2|p"
}
read -r p1 _ < <(part 1)
FAT="$IMG@@$((p1 * 512))"

slot_debugfs() { # slot_debugfs PARTNO < commands
	local start size
	read -r start size < <(part "$1")
	dd if="$IMG" of="$W/slot.ext4" bs=512 skip="$start" count="$size" status=none
	debugfs -w "$W/slot.ext4" > /dev/null 2>&1
	dd if="$W/slot.ext4" of="$IMG" bs=512 seek="$start" conv=notrunc status=none
	rm -f "$W/slot.ext4"
}

# both slots get the emulator's DT; slot B a marker the update must remove
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
echo "the old slot B" > "$W/marker"
slot_debugfs 3 <<EOF
write $W/marker /ota-test-marker
EOF

rm -f "$W/key" "$W/key.pub"
ssh-keygen -q -t ed25519 -N '' -C ota-test -f "$W/key"
SSH=(ssh -q -p $SSH_PORT -i "$W/key" -o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1)
on() { "${SSH[@]}" "$@"; }

boot() { # boot WAIT_REGEX SECS
	"$VM" start --bootrom --boot-mode sd --sd "$IMG" --mac $MAC --log \
		--ssh-port $SSH_PORT --web-port $WEB_PORT --hpsdr-port 21125
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
# emu_dt PARTNO: the emulator's device tree into a slot, from the guest
emu_dt() {
	on "mkdir -p /run/ota-test && mount /dev/mmcblk0p$1 /run/ota-test &&
		cat > /run/ota-test/boot/zynq-web888.dtb && umount /run/ota-test" < "$W/emu.dtb"
}
env_of() { on "fw_printenv -n $1" 2> /dev/null; }
# the console log goes on over reboots in the guest: mark it, then wait
# for (or read) what came after the mark
mark() { mark=$("$VM" log | wc -l); }
since() { "$VM" log | tail -n +$((mark + 1)); }
wait_since() { # wait_since REGEX SECS
	for ((i = 0; i < $2 * 2; i++)); do
		since | grep -Eq -- "$1" && return 0
		sleep 0.5
	done
	return 1
}

# the bundle over HTTP with range requests (RAUC streams it: NBD + verity);
# the guest reaches the host as 10.0.2.2
cp "$BUNDLE" "$W/www/update.raucb"
cat > "$W/serve.py" <<'EOF'
import http.server, os, re, sys

class Ranges(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            self.send_error(404)
            return None
        size = os.path.getsize(path)
        m = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        f = open(path, "rb")
        if not m:
            self.send_response(200)
            self.send_header("Content-Length", str(size))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            self.left = size
            return f
        a, b = m.groups()
        start = int(a) if a else size - int(b)
        end = int(b) if a and b else size - 1
        end = min(end, size - 1)
        f.seek(start)
        self.send_response(206)
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        self.left = end - start + 1
        return f

    def copyfile(self, src, dst):
        while self.left > 0:
            chunk = src.read(min(65536, self.left))
            if not chunk:
                break
            dst.write(chunk)
            self.left -= len(chunk)

    def log_message(self, *args):
        pass

os.chdir(sys.argv[2])
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Ranges).serve_forever()
EOF
python3 -I "$W/serve.py" $HTTP_PORT "$W/www" &
server=$!
trap 'kill $server 2> /dev/null || true; "$VM" stop 2> /dev/null || true' EXIT
URL=http://10.0.2.2:$HTTP_PORT/update.raucb

printf '%s\r\n' "hostname = ota888" "admin_password = test-password-1" \
	"ssh_key = $(cat "$W/key.pub")" | mcopy -o -i "$FAT" - ::web888.txt

echo "== 1. update slot B from slot A"
boot 'login:' 900 || bad "no login prompt"
wait_ssh || bad "no SSH"
check "root slot A" on 'grep -q rauc.slot=A /proc/cmdline'
check "rauc knows the system" on 'rauc status | grep -q "Compatible: *web888"'
check "rauc: booted from A" on 'rauc status | grep -q "Booted from: *rootfs.0 (A)"'
on "rauc install $URL" > "$W/install1.log" 2>&1 || true
check "rauc install (streamed)" grep -q 'Installing .* succeeded' "$W/install1.log"
check "slot B first" test "$(env_of BOOT_ORDER)" = "B A"
check "slot B has 3 tries" test "$(env_of BOOT_B_LEFT)" = 3
emu_dt 3 || bad "no emulator DT in slot B"
mark
on reboot 2> /dev/null || true
wait_since 'web888: slot B' 600 || bad "U-Boot didn't choose slot B"
wait_since 'login:' 900 || bad "no login prompt on slot B"
wait_ssh || bad "no SSH on slot B"
check "root slot B" on 'grep -q rauc.slot=B /proc/cmdline'
check "slot B is the new system (no marker)" on '! test -e /ota-test-marker'
check "web888d running on B" on 'systemctl is-active web888d'
on 'sleep 75' || true
check "slot B marked good (tries 3)" test "$(env_of BOOT_B_LEFT)" = 3
check "rauc: B good" on 'rauc status --detailed | tr -d "\033" | sed "s/\[[0-9;]*m//g" | grep -A4 "\[rootfs.1\]" | grep -q "boot status: good"'
check "web888-boot-ok used rauc" on 'journalctl -b -u web888-boot-ok | grep -q "slot B good (rauc"'

echo "== 2. power cut during an install into slot A"
on "rauc install $URL" > "$W/install2.log" 2>&1 &
installer=$!
sleep 25
"$VM" stop
wait $installer 2> /dev/null || true
boot 'login:' 900 || bad "no login prompt after the power cut"
wait_ssh || bad "no SSH after the power cut"
log=$("$VM" log)
check "U-Boot still chose B" grep -q 'web888: slot B' <<< "$log"
check "root slot B after the power cut" on 'grep -q rauc.slot=B /proc/cmdline'
# RAUC took A out of the boot order when the install began: half
# written, it is never tried
check "slot A out of the boot order" test "$(env_of BOOT_ORDER)" = "B"

echo "== 3. a bad update: slot A doesn't boot, back to B"
on "rauc install $URL" > "$W/install3.log" 2>&1 || true
check "rauc install into A" grep -q 'Installing .* succeeded' "$W/install3.log"
check "slot A first" test "$(env_of BOOT_ORDER)" = "A B"
on 'mkdir -p /run/ota-test && mount /dev/mmcblk0p2 /run/ota-test &&
	rm -f /run/ota-test/boot/zImage /run/ota-test/boot/uImage && umount /run/ota-test' ||
	bad "couldn't break slot A"
mark
on reboot 2> /dev/null || true
wait_since '(login:|no slot has tries left)' 1500 || bad "no login prompt"
log=$(since)
check "slot A failed until out of tries" grep -q 'web888: slot A did not boot' <<< "$log"
check "slot A not booted" test "$(grep -c 'web888: slot A did not boot' <<< "$log")" -ge 3
wait_ssh || bad "no SSH back on slot B"
check "root slot B again" on 'grep -q rauc.slot=B /proc/cmdline'
check "A has no tries left" test "$(env_of BOOT_A_LEFT)" = 0
power_off

echo
if [ $fails = 0 ]; then
	echo "all checks passed"
else
	echo "$fails checks failed (console log: $VM_DIR/console.log)"
	exit 1
fi
