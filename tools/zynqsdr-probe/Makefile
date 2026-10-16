# SPDX-License-Identifier: GPL-3.0-or-later
# Static ARMv7 binary without an ARM sysroot: clang + lld, no libc.
CC     ?= clang
CFLAGS  = --target=armv7a-linux-gnueabihf -mfloat-abi=hard -march=armv7-a \
          -O2 -ffreestanding -fno-stack-protector -nostdlib -static \
          -fuse-ld=lld -Wl,--build-id=none -Wall

zynqsdr_probe: zynqsdr_probe.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f zynqsdr_probe
