#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build web888_sdr.ko against the kernel of a web888-ng-os Yocto build,
# without a Yocto recipe round trip (quick edit/compile/load cycles):
#
#   YOCTO=/data/yocto/web888 driver/build-yocto.sh      -> driver/out/web888_sdr.ko
#
# YOCTO is the kas work directory (contains build/). Runs in the kas
# container (rootless podman). The shared kernel tree has no modpost and
# no Module.symvers, so a writable copy with both is made in out/kba.
set -eu
: "${YOCTO:?set YOCTO to the kas work directory}"
DRV=$(cd "$(dirname "$0")" && pwd)
OUT=$DRV/out
T=$YOCTO/build/tmp
KB=$(ls -d "$T"/work/web888-oe-linux-gnueabi/linux-xlnx/*/ | head -1)
mkdir -p "$OUT"
cp "$DRV"/web888_sdr.c "$DRV"/web888_sdr.h "$DRV"/Makefile "$OUT"/
if [ ! -f "$OUT/kba/Module.symvers" ]; then
    rm -rf "$OUT/kba"
    cp -a "$T/work-shared/web888/kernel-build-artifacts" "$OUT/kba"
    cp "$KB"/linux-web888-standard-build/Module.symvers "$OUT/kba/"
    need_prepare=1
else
    need_prepare=0
fi
podman run --rm --userns=keep-id --user "$(id -u):$(id -g)" --entrypoint sh \
    -v "$YOCTO":/work:ro -v "$OUT":/drv ghcr.io/siemens/kas/kas:5.5 -c "
set -e
R=\$(ls -d /work/build/tmp/work/web888-oe-linux-gnueabi/linux-xlnx/*/recipe-sysroot-native | head -1)
export PATH=\$R/usr/bin/arm-oe-linux-gnueabi:\$R/usr/bin:\$PATH
K='make -s -C /work/build/tmp/work-shared/web888/kernel-source O=/drv/kba ARCH=arm CROSS_COMPILE=arm-oe-linux-gnueabi-'
[ $need_prepare = 1 ] && \$K modules_prepare
\$K M=/drv W=1 modules"
ls -la "$OUT/web888_sdr.ko"
