#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build zsdr-test as a static ARMv7 binary with the cross compiler of a
# web888-ng-os Yocto build (runs on the Yocto image and on the vendor
# Alpine userspace alike):
#
#   YOCTO=/data/yocto/web888 driver/test/build-yocto.sh   -> driver/out/zsdr-test
#
# The recipe sysroots are removed by rm_work, so a minimal one is put
# together from sysroots-components in out/sysroot.
set -eu
: "${YOCTO:?set YOCTO to the kas work directory}"
TEST=$(cd "$(dirname "$0")" && pwd)
OUT=$TEST/../out
mkdir -p "$OUT/src"
cp "$TEST"/zsdr-test.c "$OUT"/src/
cp "$TEST"/../web888_sdr.h "$OUT"/
podman run --rm --userns=keep-id --user "$(id -u):$(id -g)" --entrypoint sh \
    -v "$YOCTO":/work:ro -v "$OUT":/drv ghcr.io/siemens/kas/kas:5.5 -c "
set -e
C=/work/build/tmp/sysroots-components/cortexa9t2hf-neon
S=/drv/sysroot
if [ ! -d \$S ]; then
    mkdir -p \$S
    for p in glibc linux-libc-headers libgcc gcc-runtime; do cp -r \$C/\$p/. \$S/; done
fi
R=\$(ls -d /work/build/tmp/work/web888-oe-linux-gnueabi/linux-xlnx/*/recipe-sysroot-native | head -1)
export PATH=\$R/usr/bin/arm-oe-linux-gnueabi:\$PATH
arm-oe-linux-gnueabi-gcc --sysroot=\$S -march=armv7-a -mfloat-abi=hard \
    -mfpu=neon -O2 -Wall -Wextra -static -o /drv/zsdr-test /drv/src/zsdr-test.c -lm"
ls -la "$OUT/zsdr-test"
