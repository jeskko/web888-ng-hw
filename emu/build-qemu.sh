#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fetch QEMU, add the web888 machine (hw/emu/qemu/{files,patches}) and build
# qemu-system-arm only. Re-running copies the model sources again and does
# an incremental build.
#
#   ./build-qemu.sh            # -> build/qemu-11.1.2/build/qemu-system-arm
#   BUILD=/some/dir ./build-qemu.sh
set -euo pipefail

EMU=$(cd "$(dirname "$0")" && pwd)
BUILD=${BUILD:-$EMU/build}
QEMU_VER=11.1.2
QEMU_SHA256=731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016
TARBALL=qemu-$QEMU_VER.tar.xz
SRC=$BUILD/qemu-$QEMU_VER
JOBS=${JOBS:-$(nproc)}

mkdir -p "$BUILD/dl"
if [ ! -f "$BUILD/dl/$TARBALL" ]; then
    echo ">> downloading $TARBALL"
    curl -fL -o "$BUILD/dl/$TARBALL.part" "https://download.qemu.org/$TARBALL"
    mv "$BUILD/dl/$TARBALL.part" "$BUILD/dl/$TARBALL"
fi
echo "$QEMU_SHA256  $BUILD/dl/$TARBALL" | sha256sum -c --quiet

if [ ! -f "$SRC/.web888-patched" ]; then
    echo ">> extracting"
    rm -rf "$SRC"
    tar -C "$BUILD" -xf "$BUILD/dl/$TARBALL"
    for p in "$EMU"/qemu/patches/*.patch; do
        echo ">> applying $(basename "$p")"
        patch -d "$SRC" -p1 --forward < "$p"
    done
    touch "$SRC/.web888-patched"
fi

# new model sources (copied every time so edits are picked up)
(cd "$EMU/qemu/files" && find . -type f) | while read -r f; do
    if ! cmp -s "$EMU/qemu/files/$f" "$SRC/$f"; then
        install -D -m 644 "$EMU/qemu/files/$f" "$SRC/$f"
    fi
done

if [ ! -f "$SRC/build/build.ninja" ]; then
    echo ">> configuring"
    (cd "$SRC" && ./configure --target-list=arm-softmmu \
        --disable-docs --disable-werror --enable-slirp \
        --disable-gtk --disable-sdl --disable-opengl --disable-vnc \
        --disable-xen --disable-kvm --disable-tools --disable-guest-agent)
fi

echo ">> building"
ninja -C "$SRC/build" -j "$JOBS" qemu-system-arm
ln -sf "$SRC/build/qemu-system-arm" "$BUILD/qemu-system-arm"
echo ">> done: $BUILD/qemu-system-arm"
"$BUILD/qemu-system-arm" -machine help | grep -E '^web888 ' || {
    echo "web888 machine missing" >&2; exit 1; }
