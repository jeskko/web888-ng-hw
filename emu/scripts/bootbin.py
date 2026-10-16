#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""List or extract the partitions of a Zynq-7000 boot image (boot.bin).

Usage: bootbin.py BOOT.BIN [OUTDIR]

The Web-888 boot.bin holds: FSBL, a small jump stub, the DTB (load
0x2000000), a zImage (0x2008000) and a gzip initramfs (0x3000000).
With OUTDIR, writes dtb, zImage and initramfs.cpio.gz there.
"""
import struct
import sys


def partitions(d):
    pht = struct.unpack_from('<I', d, 0x9C)[0]
    for i in range(16):
        w = struct.unpack_from('<16I', d, pht + 64 * i)
        if w[2] == 0:
            break
        yield dict(index=i, length=w[1] * 4, load=w[3], exec=w[4],
                   offset=w[5] * 4)


def main():
    d = open(sys.argv[1], 'rb').read()
    if d[0x24:0x28] != b'XNLX':
        sys.exit('not a Zynq boot image')
    parts = list(partitions(d))
    names = {0x2000000: 'vendor.dtb', 0x2008000: 'zImage',
             0x3000000: 'initramfs.cpio.gz'}
    for p in parts:
        print('part %(index)d off 0x%(offset)07x len 0x%(length)07x '
              'load 0x%(load)08x exec 0x%(exec)08x' % p)
        if len(sys.argv) > 2 and p['load'] in names:
            blob = d[p['offset']:p['offset'] + p['length']]
            with open('%s/%s' % (sys.argv[2], names[p['load']]), 'wb') as f:
                f.write(blob)


if __name__ == '__main__':
    main()
