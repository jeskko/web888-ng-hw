#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build the emulated SD card from the vendor firmware zip, like flashing a
# real card: one FAT32 partition holding the release files. Also extracts
# zImage, initramfs and DTB from boot.bin for QEMU's direct kernel boot.
#
#   FW_ZIP=/path/to/web-888-alpine-3.20-armv7-20260919.zip ./make-sdimage.sh
#
# Output (never commit these, they are vendor binaries):
#   build/fw/sd.img  build/fw/zImage  build/fw/initramfs.cpio.gz
#   build/fw/vendor.dtb
#
# Options (environment): SD_SIZE_MB (power of two, default 512),
#   OVERLAY_DIR (extra files copied onto the card root after the release).
set -euo pipefail
. "$(dirname "$0")/scripts/common.sh"

SD_SIZE_MB=${SD_SIZE_MB:-512}
check_fw_zip

STAGE=$FW/sd-root
rm -rf "$STAGE"
mkdir -p "$STAGE"
echo ">> unpacking release"
unzip -q "$FW_ZIP" -d "$STAGE"

echo ">> extracting kernel/initramfs/dtb from boot.bin"
python3 -I "$EMU/scripts/bootbin.py" "$STAGE/boot.bin" "$FW"

if [ "${AUTOLOGIN:-1}" = 1 ]; then
    # Emulator convenience: root shell on the serial console without the
    # vendor password. Adds etc/inittab to a copy of the apkovl (Alpine
    # keeps overlay config files over package defaults).
    echo ">> apkovl: serial console auto-login (AUTOLOGIN=0 to keep stock)"
    OVL=$FW/apkovl
    rm -rf "$OVL"
    mkdir -p "$OVL"
    tar -C "$OVL" -xzf "$STAGE/web-888.apkovl.tar.gz"
    cat > "$OVL/etc/inittab" <<'EOF'
# web888 emulator: Alpine default inittab, root auto-login on ttyPS0
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
ttyPS0::respawn:/bin/login -f root
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF
    tar --owner=0 --group=0 -czf "$STAGE/web-888.apkovl.tar.gz" -C "$OVL" $(ls -A "$OVL")
fi

if [ -n "${OVERLAY_DIR:-}" ]; then
    echo ">> adding $OVERLAY_DIR"
    cp -r "$OVERLAY_DIR"/. "$STAGE"/
fi

# MBR + one FAT32 (LBA) partition from 1 MiB to the end
IMG=$FW/sd.img
PART=$FW/sd-part.img
PART_MB=$((SD_SIZE_MB - 1))
rm -f "$IMG" "$PART"
truncate -s "${PART_MB}M" "$PART"
mkfs.vfat -F 32 -n WEB888 "$PART" >/dev/null
echo ">> copying files to FAT"
MTOOLS_SKIP_CHECK=1 mcopy -s -m -i "$PART" "$STAGE"/* ::/
truncate -s "${SD_SIZE_MB}M" "$IMG"
echo 'label: dos
start=2048, type=c, bootable' | sfdisk -q "$IMG"
dd if="$PART" of="$IMG" bs=1M seek=1 conv=notrunc status=none
rm -f "$PART"
echo ">> $IMG ($SD_SIZE_MB MiB)"
