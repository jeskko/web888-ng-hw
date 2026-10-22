#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Waterfall noise texture from wfcap.py files: spread within a line, the
# whole-line component (line-to-line steps, e.g. bursty noise caught by some
# snapshots only) and correlation across bins and lines.
#   texture.py A.npz [B.npz ...]
import sys, numpy as np
for p in sys.argv[1:]:
    d = np.load(p); a = d["a"]
    a = a[:, 100:924]                      # skip span edges
    dev = a - np.median(a, 0)              # remove per-bin mean (signals, slope)
    linec = dev.mean(1)                    # whole-line component
    r = dev - linec[:, None]
    def cf(x, k): return np.mean([np.corrcoef(l[:-k], l[k:])[0,1] for l in x])
    fr = [cf(r, k) for k in (1, 2, 4, 8, 16)]
    tr = [np.corrcoef(r[:-k].ravel(), r[k:].ravel())[0,1] for k in (1, 2)]
    print(f"{p:16s} zoom {int(d['zoom'])} cf {float(d['cf'])/1e3:6.2f} MHz  cell std {r.std():4.2f} dB, line-common std {linec.std():4.2f} dB | "
          f"freq corr lag1/2/4/8/16 " + " ".join(f"{v:5.2f}" for v in fr) + f" | line corr lag1/2 " + " ".join(f"{v:5.2f}" for v in tr))
