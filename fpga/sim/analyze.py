#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Analyse simulation dumps against a model of the expected output.

  analyze.py nco out/nco.txt
  analyze.py rx  out/rx_mem.txt <decim2> <ch>:<f_nco> ...
  analyze.py wf  out/wf_mem.txt <decim> <f_nco>

The test input (tb_core.v) is the sum of real sines TONES. After mixing with
exp(-j w_nco n) each sine gives components at +f-f_nco and -f-f_nco with
half its amplitude; these are scaled by the CIC response, aliased into the
output band, and fitted by least squares. Reported per component: measured
vs. predicted level (dB) and the overall residual (SNR of the fit).
"""
import sys
import numpy as np

FS = 122.88e6
TONES = [(7.0745e6, 16384 / 32768), (14.2005e6, 8192 / 32768)]   # (Hz, fraction of FS)
RX_FS_LOG2 = 30   # full-scale DC -> 2^30
WF_FS_LOG2 = 15   # full-scale DC -> 2^15
TOL_DB = 0.05


def phase_inc(f):
    return int(np.floor(f / FS * 2**48 + 0.5))


def nco_freq(f):
    return phase_inc(f) / 2**48 * FS


def cic_gain(f, fs, n, r):
    x = np.pi * f / fs
    if abs(np.sin(x)) < 1e-12:
        return 1.0
    return abs(np.sin(r * x) / (r * np.sin(x))) ** n


def wrap(f, fs):
    return (f + fs / 2) % fs - fs / 2


def components(f_nco, stages, fs_out, scale):
    """stages: list of (fs_in, N, R). Returns [(f_out, amplitude)]."""
    out = []
    for f, a in TONES:
        for fb in (f - f_nco, -f - f_nco):
            g = 1.0
            for fs_in, n, r in stages:
                g *= cic_gain(fb, fs_in, n, r)
            out.append((wrap(fb, fs_out), scale * a / 2 * g))
    return out


def fit(z, fs, comps, floor):
    """Least-squares fit of complex exponentials at the given frequencies."""
    n = np.arange(len(z))
    keep = [(f, a) for f, a in comps if a > floor]
    A = np.stack([np.exp(2j * np.pi * f / fs * n) for f, _ in keep], axis=1)
    c, *_ = np.linalg.lstsq(A, z, rcond=None)
    resid = z - A @ c
    snr = 10 * np.log10(np.sum(np.abs(A @ c) ** 2) / np.sum(np.abs(resid) ** 2))
    ok = True
    for (f, a), ci in zip(keep, c):
        d = 20 * np.log10(abs(ci) / a)
        good = abs(d) < TOL_DB
        ok &= good
        print(f"    {f/1e3:+12.3f} kHz  expect 2^{np.log2(a):6.3f}  got 2^{np.log2(abs(ci)):6.3f}"
              f"  ({d:+.4f} dB) {'ok' if good else 'FAIL'}")
    print(f"    residual: SNR {snr:.1f} dB, rms {np.sqrt(np.mean(np.abs(resid)**2)):.3g}")
    return ok


def load_words(path):
    return np.array([int(l, 16) for l in open(path) if l.strip()], dtype=np.uint64)


def signed(x, bits):
    x = x.astype(np.int64)
    return np.where(x >= 2 ** (bits - 1), x - 2 ** bits, x)


def nco(path):
    d = np.loadtxt(path)
    z = d[:, 0] + 1j * d[:, 1]
    w = np.kaiser(len(z), 20)
    mag = np.abs(np.fft.fft(z * w))
    k = int(np.argmax(mag))
    m = mag.copy()
    m[k - 48:k + 49] = 0
    sfdr = 20 * np.log10(mag[k] / m.max())
    print(f"NCO: |z| mean {np.abs(z).mean():.1f}, SFDR {sfdr:.1f} dB")
    return sfdr > 100


def rx(path, decim2, chans, nch=12, skip=16):
    w = load_words(path)
    nfr = len(w) // nch
    w = w[: nfr * nch].reshape(nfr, nch)
    I = signed(w & np.uint64(0xffffffff), 32)
    Q = signed(w >> np.uint64(32), 32)
    fs_out = FS / 256 / decim2
    ok = True
    for ch, f in chans:
        z = (I[:, ch] + 1j * Q[:, ch])[skip:]
        comps = components(nco_freq(f), [(FS, 3, 256), (FS / 256, 5, decim2)], fs_out, 2.0 ** RX_FS_LOG2)
        print(f"RX ch{ch} (nco {f/1e6:.6f} MHz, {len(z)} samples @ {fs_out/1e3:.1f} kHz):")
        ok &= fit(z, fs_out, comps, floor=2.0 ** RX_FS_LOG2 * 1e-6)
    return ok


def wf(path, decim, f):
    w = load_words(path)
    s = np.empty(2 * len(w), dtype=np.uint64)
    s[0::2] = w & np.uint64(0xffffffff)
    s[1::2] = w >> np.uint64(32)
    z = signed(s & np.uint64(0xffff), 16) + 1j * signed(s >> np.uint64(16), 16)
    fs_out = FS / decim
    comps = components(nco_freq(f), [(FS, 5, decim)], fs_out, 2.0 ** WF_FS_LOG2)
    print(f"WF (nco {f/1e6:.6f} MHz, R={decim}, {len(z)} samples @ {fs_out/1e6:.2f} MHz):")
    return fit(z, fs_out, comps, floor=4.0)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "nco":
        ok = nco(sys.argv[2])
    elif cmd == "rx":
        chans = [(int(a), float(b)) for a, b in (x.split(":") for x in sys.argv[4:])]
        ok = rx(sys.argv[2], int(sys.argv[3]), chans)
    elif cmd == "wf":
        ok = wf(sys.argv[2], int(sys.argv[3]), float(sys.argv[4]))
    else:
        sys.exit(__doc__)
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
