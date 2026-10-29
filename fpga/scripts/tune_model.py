#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bit-exact model of pfb_tune.v, the bins tuner (docs/channelizer.md §3.8).

Each user is a 48-bit frequency word (f / fs * 2^48 at the ADC rate, as the
stock RX NCOs take it). From it: bin k = round(inc / 2^36) (30 kHz bins at
122.88 MHz) and the offset's phase step at the 60 kHz frame rate,
pinc = (inc - k * 2^36) >> 5 (32-bit). Per frame, the user's bin sample x
(25-bit) is turned by the phase p (32-bit, 0 at the frequency's write):
  Y = xr*c + xi*s + j(xi*c - xr*s)        (c, s: sincos(p), 18-bit)
  y = sat18((Y + 2^22) >> 23)             (stored, 18 + 18 bits)
and p += pinc. Disabled users store 0 and keep p. Every frame n with
n % 5 == 4 gives an output per user from the 128-sample history:
  out = (sum_j h[j] * y[n - j] + 2^6) >> 7  (32-bit, a full-scale sine 2^29)

  tune_model.py check IN OUT   compare the testbench's dump (sim/out) with
                               the model; exit 1 on a mismatch
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(HERE, "..", "rtl", "gen")
NU = 32


def load_mem(name, bits):
    with open(os.path.join(GEN, name)) as f:
        v = [int(x, 16) for x in f.read().split()]
    return [x - (1 << bits) if x >> (bits - 1) else x for x in v]


ROM = load_mem("sincos_qw.mem", 18)  # 17-bit unsigned: never negative
TAPS = load_mem("tune_fir.mem", 18)


def sincos(p):
    """nco.v's lookup on a 32-bit phase: (cos, sin), 18-bit."""
    q = (p >> 30) & 3
    a = (p >> 20) & 1023
    f = (p >> 8) & 4095
    addr_s = (~a & 1023) if q & 1 else a
    addr_c = a if q & 1 else (~a & 1023)
    neg_s = q >> 1
    neg_c = (q >> 1) ^ (q & 1)
    d = f - 2048
    s0 = -ROM[addr_s] if neg_s else ROM[addr_s]
    c0 = -ROM[addr_c] if neg_c else ROM[addr_c]
    m = 201 * d
    corr_s = (m * c0 + (1 << 28)) >> 29
    corr_c = (m * s0 + (1 << 28)) >> 29
    return c0 - corr_c, s0 + corr_s


def derive(inc):
    """(bin, pinc) of a 48-bit frequency word."""
    k = min((inc + (1 << 35)) >> 36, 2047)
    d = inc - (k << 36)
    pinc = (d >> 5) & 0xFFFFFFFF
    return k, pinc


def sat18(v):
    return max(-(1 << 17), min((1 << 17) - 1, v))


def run(users, frames):
    """users: [(inc, enabled)] * NU; frames: [{bin: (re, im)}] in order.
    Returns {n: [(i, q)] * NU} for the output frames n % 5 == 4."""
    cfg = [derive(inc) + (en,) for inc, en in users]
    p = [0] * NU
    hist = [[(0, 0)] * 128 for _ in range(NU)]
    out = {}
    for n, fr in enumerate(frames):
        for u, (k, pinc, en) in enumerate(cfg):
            if not en:
                hist[u][n % 128] = (0, 0)
                continue
            xr, xi = fr.get(k, (0, 0))
            c, s = sincos(p[u])
            yr = sat18((xr * c + xi * s + (1 << 22)) >> 23)
            yi = sat18((xi * c - xr * s + (1 << 22)) >> 23)
            hist[u][n % 128] = (yr, yi)
            p[u] = (p[u] + pinc) & 0xFFFFFFFF
        if n % 5 == 4:
            row = []
            for u in range(NU):
                ar = sum(TAPS[j] * hist[u][(n - j) % 128][0] for j in range(len(TAPS)))
                ai = sum(TAPS[j] * hist[u][(n - j) % 128][1] for j in range(len(TAPS)))
                row.append(((ar + 64) >> 7, (ai + 64) >> 7))
            out[n] = row
    return out


def check(path_in, path_out):
    # IN: "U u inc en" lines, then "F n" and "B k re im" lines per frame
    users = [(0, 0)] * NU
    frames = []
    with open(path_in) as f:
        for line in f:
            t = line.split()
            if t[0] == "U":
                users[int(t[1])] = (int(t[2], 16), int(t[3]))
            elif t[0] == "F":
                frames.append({})
            elif t[0] == "B":
                frames[-1][int(t[1])] = (int(t[2]), int(t[3]))
    want = run(users, frames)
    # OUT: "O n" then NU lines "i q"
    got = {}
    with open(path_out) as f:
        cur = None
        for line in f:
            t = line.split()
            if t[0] == "O":
                cur = int(t[1])
                got[cur] = []
            else:
                got[cur].append((int(t[0]), int(t[1])))
    bad = 0
    for n, row in got.items():
        if n not in want:
            print(f"output frame {n}: not one the model makes")
            bad += 1
            continue
        for u, (g, w) in enumerate(zip(row, want[n])):
            if g != w:
                if bad < 10:
                    print(f"frame {n} user {u}: rtl {g} model {w}")
                bad += 1
    peak = max((max(abs(i), abs(q)) for row in got.values() for i, q in row), default=0)
    print(f"tune_model: {len(got)} output frames compared, {bad} mismatches, peak {peak}")
    return bad == 0 and len(got) > 0


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "check":
        sys.exit(0 if check(sys.argv[2], sys.argv[3]) else 1)
    print(__doc__)
    sys.exit(2)
