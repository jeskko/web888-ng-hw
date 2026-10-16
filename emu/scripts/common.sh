# SPDX-License-Identifier: GPL-3.0-or-later
# Shared settings for the emulator scripts (sourced).
EMU=${EMU:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
BUILD=${BUILD:-$EMU/build}
# Vendor firmware release (web-888-alpine-3.20-armv7-20260919.zip). Never
# committed; point FW_ZIP at your local copy.
FW_ZIP=${FW_ZIP:-$EMU/../../upstream/firmware-20260919/fw.zip}
FW_ZIP_SHA256=32da2adb2e307976b467704719ada1505f7ce3795f6819eccc7b94bcb6668d74
FW=$BUILD/fw             # extracted kernel, initramfs, DTB, SD image

check_fw_zip() {
    if [ ! -f "$FW_ZIP" ]; then
        echo "firmware zip not found: $FW_ZIP (set FW_ZIP=...)" >&2
        exit 1
    fi
    if [ ! -f "$FW/.zip-ok" ] || [ "$FW_ZIP" -nt "$FW/.zip-ok" ]; then
        echo ">> verifying $(basename "$FW_ZIP")"
        echo "$FW_ZIP_SHA256  $FW_ZIP" | sha256sum -c --quiet
        mkdir -p "$FW"
        touch "$FW/.zip-ok"
    fi
}
