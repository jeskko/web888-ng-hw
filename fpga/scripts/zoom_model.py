#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bit-exact model of pfb_zoom.v, the zoom engine (docs/channelizer.md §3.9).

A job: bins k0 .. k0 + B - 1, FFT length n = 2^logn, shift s. Of n frames
of the chain's bins (25-bit re, im):

  capture  v = sat22(round(x >> s))                 (half up; 22 + 22 bits)
  window   y = (v * w[t] + 2^16) >> 17              w: 4-term Blackman-
           Harris, periodic, 17-bit (zoom_win.mem at stride 2048 / n)
  passes   p = 1..logn, radix 2, decimation in time, in place: with
           t = b * W (W = e^(-2 pi j / len), 18-bit, the split stage's
           table; the product rounded by 17 bits, half up; W^0: t = b),
           a' = a + t, b' = a - t, then both scaled by the pass's shift
           (rounded half up): with m the largest top five bits of any
           component's size in the bin before the pass (size >> 16), 0 if
           m < 13, 1 if m < 26, else 2 (a butterfly grows a component by
           at most 1 + sqrt 2, so nothing overflows). A bin's exponent e
           is the sum of its passes' shifts.
  out      for each bin, FFT points j = -n/4 .. n/4 - 1: re^2 + im^2 as a
           float32 (mantissa truncated) times 2^(2 (e + s))

So a result is |sum_t w[t] x[t] e^(-2 pi j f t / n)|^2 in units of the
25-bit bins, squared, w scaled to a peak of 1.

  zoom_model.py quality          floor and dynamic range against a float FFT
  zoom_model.py check IN OUT     compare the testbench's dump (sim/out) with
                                 the model; exit 1 on a mismatch
"""
import os
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(HERE, "..", "rtl", "gen")
W = 22                                  # a component's width in the work RAM


def load_mem(name):
    with open(os.path.join(GEN, name)) as f:
        return [int(x, 16) for x in f.read().split()]


WIN = np.array(load_mem("zoom_win.mem") + [131071], dtype=np.int64)  # 0..1024


def _s18(v):
    return v - (1 << 18) if v >> 17 else v


_TW = load_mem("pfb_split_tw.mem")[:1024]
TW_RE = np.array([_s18(x >> 18) for x in _TW], dtype=np.int64)
TW_IM = np.array([_s18(x & 0x3FFFF) for x in _TW], dtype=np.int64)


def window(n):
    """w[t], t = 0..n-1."""
    i = np.arange(n) * (2048 // n)
    return WIN[np.where(i > 1024, 2048 - i, i)]


def twiddle(k):
    """W_4096^k for k < 2048 (arrays): (re, im)."""
    q = k >= 1024
    a = np.where(q, k - 1024, k)
    r, i = TW_RE[a], TW_IM[a]
    return np.where(q, i, r), np.where(q, -r, i)


def bitrev(t, bits):
    r = np.zeros_like(t)
    for b in range(bits):
        r |= ((t >> b) & 1) << (bits - 1 - b)
    return r


def size(v):
    """A component's size: v, or ~v if negative."""
    return np.where(v < 0, ~v, v)


def capture(x, s):
    """25-bit components -> W-bit; (values, saturated)."""
    v = (x + (1 << (s - 1))) >> s if s else x
    c = np.clip(v, -(1 << (W - 1)), (1 << (W - 1)) - 1)
    return c, bool(np.any(c != v))


def f32(p, e2):
    """p * 2^e2 as float32 bits, mantissa truncated."""
    if p == 0:
        return 0
    lead = p.bit_length() - 1
    m = (p << (23 - lead) if lead <= 23 else p >> (lead - 23)) & 0x7FFFFF
    return ((127 + lead + e2) << 23) | m


def fft_bin(re, im, logn):
    """One bin: captured samples in time order -> (re, im, e), in place
    arithmetic as the RTL's (arrays of n, int64)."""
    n = 1 << logn
    # the work RAM's order: bit-reversed time
    idx = bitrev(np.arange(n), logn)
    w = window(n)
    xr = np.empty(n, dtype=np.int64)
    xi = np.empty(n, dtype=np.int64)
    xr[idx] = (re * w + (1 << 16)) >> 17
    xi[idx] = (im * w + (1 << 16)) >> 17
    e = 0
    for p in range(1, logn + 1):
        half = 1 << (p - 1)
        m = max(int(size(xr).max()), int(size(xi).max())) >> (W - 6)
        sh = 0 if m < 13 else 1 if m < 26 else 2
        e += sh
        j = np.arange(half)
        wr, wi = twiddle(j * (4096 >> p))
        a = (np.arange(n >> p)[:, None] << p) + j[None, :]
        b = a + half
        ar, ai, br, bi = xr[a], xi[a], xr[b], xi[b]
        tr = (br * wr - bi * wi + (1 << 16)) >> 17
        ti = (br * wi + bi * wr + (1 << 16)) >> 17
        tr = np.where(j == 0, br, tr)
        ti = np.where(j == 0, bi, ti)
        rnd = (1 << (sh - 1)) if sh else 0
        for dst, val in ((xr, (a, ar + tr)), (xi, (a, ai + ti)), (xr, (b, ar - tr)), (xi, (b, ai - ti))):
            v = (val[1] + rnd) >> sh
            assert v.max() < (1 << (W - 1)) and v.min() >= -(1 << (W - 1)), "pass overflow"
            dst[val[0]] = v
    return xr, xi, e


def job(frames_re, frames_im, logn, s):
    """frames_*: [n][B] 25-bit components. Returns (float32 bit patterns,
    B * n / 2, bins in order, each j = -n/4 .. n/4 - 1; saturated)."""
    n = 1 << logn
    out = []
    sat = False
    for b in range(frames_re.shape[1]):
        cr, s1 = capture(frames_re[:, b], s)
        ci, s2 = capture(frames_im[:, b], s)
        sat |= s1 or s2
        xr, xi, e = fft_bin(cr, ci, logn)
        for j in list(range(n - n // 4, n)) + list(range(n // 4)):
            p = int(xr[j]) ** 2 + int(xi[j]) ** 2
            out.append(f32(p, 2 * (e + s)))
    return out, sat


def bits_to_float(v):
    return np.array([struct.unpack("<f", struct.pack("<I", x))[0] for x in v], dtype=np.float64)


def reference(frames_re, frames_im, logn):
    """The same spectra from the unquantised bins in float."""
    n = 1 << logn
    k = np.arange(n)
    x = 2 * np.pi * k / n
    w = 0.35875 - 0.48829 * np.cos(x) + 0.14128 * np.cos(2 * x) - 0.01168 * np.cos(3 * x)
    z = (frames_re + 1j * frames_im) * w[:, None]
    f = np.fft.fft(z, axis=0)
    sel = list(range(n - n // 4, n)) + list(range(n // 4))
    return (np.abs(f[sel, :]) ** 2).T.reshape(-1)


def quality():
    """The fixed-point spectra against float ones: the noise floor's rise,
    and the floor beside a carrier (its own bin and a neighbour)."""
    rng = np.random.default_rng(1)
    fs_amp = 1 << 24                       # a full-scale sine in a bin
    noise = fs_amp * 10 ** (-110 / 20)     # the ADC's noise in a 30 kHz bin (rms)
    print("noise %.1f LSB rms (25-bit bins); jobs of 2 bins, 40 spectra each" % noise)
    print("%5s %5s %9s | %8s %8s | %s" % ("n", "shift", "carrier", "bin 0", "bin 1", "sat"))
    for logn in (5, 7, 9, 11):
        n = 1 << logn
        for s, cdb in ((3, None), (3, -60), (3, -30), (3, -10), (4, -10), (4, -1)):
            acc_m = np.zeros(n)
            acc_r = np.zeros(n)
            sat = False
            for _ in range(40):
                z = (rng.normal(size=(n, 2)) + 1j * rng.normal(size=(n, 2))) * noise / np.sqrt(2)
                if cdb is not None:
                    # a carrier in bin 0, between two FFT points, random phase
                    f = (n // 8 + 0.37) / n
                    z[:, 0] += fs_amp * 10 ** (cdb / 20) * np.exp(2j * np.pi * (f * np.arange(n) + rng.random()))
                fr = np.round(z.real).astype(np.int64)
                fi = np.round(z.imag).astype(np.int64)
                m, st = job(fr, fi, logn, s)
                sat |= st
                acc_m += bits_to_float(m)
                acc_r += reference(fr, fi, logn)
            # the floor away from the carrier: the lower half of each bin's points
            res = []
            for b in range(2):
                lo = slice(b * (n // 2), b * (n // 2) + n // 4 - 2)
                res.append(10 * np.log10(acc_m[lo].sum() / acc_r[lo].sum()))
            print("%5d %5d %9s | %+7.2f dB %+6.2f dB | %s" % (
                n, s, "none" if cdb is None else "%d dBFS" % cdb, res[0], res[1], "sat" if sat else ""))


def check(path_in, path_out):
    """IN: lines `job LOGN B S`, then n lines of B `re im` pairs (hex,
    25-bit) per frame; OUT: per job a line `sat 0|1`, then B * n / 2 float32
    words (hex)."""
    with open(path_in) as f:
        tok = f.read().split()
    with open(path_out) as f:
        got = f.read().split()
    ti = gi = jobs = 0

    def s25(h):
        v = int(h, 16)
        return v - (1 << 25) if v >> 24 else v

    while ti < len(tok):
        assert tok[ti] == "job", tok[ti]
        logn, nb, s = int(tok[ti + 1]), int(tok[ti + 2]), int(tok[ti + 3])
        ti += 4
        n = 1 << logn
        v = np.array([s25(h) for h in tok[ti:ti + 2 * n * nb]], dtype=np.int64).reshape(n, nb, 2)
        ti += 2 * n * nb
        want, sat = job(v[:, :, 0], v[:, :, 1], logn, s)
        if gi + 2 + len(want) > len(got) or got[gi] != "sat":
            print("job %d: the dump ends early" % jobs)
            return False
        if int(got[gi + 1]) != int(sat):
            print("job %d: sat %s, model %d" % (jobs, got[gi + 1], sat))
            return False
        have = [int(h, 16) for h in got[gi + 2:gi + 2 + len(want)]]
        gi += 2 + len(want)
        for i, (a, b) in enumerate(zip(have, want)):
            if a != b:
                print("job %d (n %d, %d bins, shift %d): point %d is %08x, model %08x" % (
                    jobs, n, nb, s, i, a, b))
                return False
        jobs += 1
    if gi != len(got):
        print("the dump has more than the model")
        return False
    print("zoom_model: %d jobs equal" % jobs)
    return True


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "quality":
        quality()
    elif len(sys.argv) == 4 and sys.argv[1] == "check":
        sys.exit(0 if check(sys.argv[2], sys.argv[3]) else 1)
    else:
        print(__doc__)
        sys.exit(2)
