# SPDX-License-Identifier: GPL-2.0-or-later
# Module.symvers from the CRCs stock modules import (their __versions):
#   python3 -I symvers.py MODDIR > Module.symvers
import os, struct, sys
crcs = {}
for root, _, files in os.walk(sys.argv[1]):
    for f in files:
        if not f.endswith('.ko'):
            continue
        b = open(os.path.join(root, f), 'rb').read()
        shoff, = struct.unpack_from('<I', b, 0x20)
        es, n, si = struct.unpack_from('<HHH', b, 0x2e)
        sh = [struct.unpack_from('<10I', b, shoff + i * es) for i in range(n)]
        st = sh[si]
        for s in sh:
            nm = b[st[4] + s[0]:].split(b'\0')[0]
            if nm != b'__versions':
                continue
            d = b[s[4]:s[4] + s[5]]
            for i in range(0, len(d), 64):
                c, = struct.unpack_from('<I', d, i)
                sym = d[i + 4:i + 64].split(b'\0')[0].decode()
                if crcs.get(sym, c) != c:
                    sys.exit(f'two CRCs for {sym}')
                crcs[sym] = c
for sym, c in sorted(crcs.items()):
    print(f'0x{c:08x}\t{sym}\tvmlinux\tEXPORT_SYMBOL\t')
