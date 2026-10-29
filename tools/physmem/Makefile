# SPDX-License-Identifier: GPL-3.0-or-later
# Static ARMv7 binary without an ARM sysroot: clang + lld, no libc.
# (make CC=clang if make's default cc is gcc)
CC     ?= clang
CFLAGS  = --target=armv7a-linux-gnueabihf -mfloat-abi=hard -march=armv7-a \
          -O2 -ffreestanding -fno-stack-protector -nostdlib -static \
          -fuse-ld=lld -Wl,--build-id=none -Wall

physmem: physmem.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f physmem
