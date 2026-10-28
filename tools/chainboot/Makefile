# SPDX-License-Identifier: GPL-2.0-or-later
# chainboot.ko for the Web-888's stock kernel (6.6.110-xilinx), see README.md.
#   make KDIR=<configured 6.6.110 tree> SYMVERS=<stock.symvers>
KDIR    ?= linux-6.6
SYMVERS ?= $(CURDIR)/stock.symvers
CROSS   ?= arm-none-eabi-

chainboot.ko: main.c reloc.S Kbuild $(SYMVERS)
	$(MAKE) -C $(KDIR) ARCH=arm CROSS_COMPILE=$(CROSS) M=$(CURDIR) \
	  KBUILD_EXTRA_SYMBOLS=$(SYMVERS) modules

clean:
	$(MAKE) -C $(KDIR) ARCH=arm M=$(CURDIR) clean
