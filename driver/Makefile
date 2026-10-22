# SPDX-License-Identifier: GPL-2.0-or-later
# Out-of-tree build:
#   make KDIR=/path/to/kernel/build ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
# Yocto's module.bbclass passes KERNEL_SRC (and O=) instead of KDIR.
obj-m := web888_sdr.o

KERNEL_SRC ?= /lib/modules/$(shell uname -r)/build
KDIR ?= $(KERNEL_SRC)

all modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

modules_install:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules_install

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
