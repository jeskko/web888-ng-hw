#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Milestone A: bare-metal register/DMA/PPS test of the web888-pl model.
set -euo pipefail
EMU=$(cd "$(dirname "$0")/.." && pwd)
QEMU=${QEMU:-$EMU/build/qemu-system-arm}
make -s -C "$EMU/tests/baremetal"
out=$(timeout 30 "$QEMU" -M web888 -smp 1 -display none -serial stdio \
      -monitor none -kernel "$EMU/tests/baremetal/pltest.elf" \
      -global web888-pl.scene=10001000:-20 -global web888-pl.noise= \
      2>&1 | tr -d '\r' | sed '/^RESULT/q' || true)
echo "$out"
grep -q '^RESULT: PASS' <<<"$out"
