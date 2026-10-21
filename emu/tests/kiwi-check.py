#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# End-to-end check of a Kiwi-protocol server (the stock Web-888 server in
# the emulator, later web888d): tune one audio channel, open one
# waterfall, and report what came through.
#
#   tests/kiwi-check.py [--host H] [--port P] [--freq kHz] [--mode am]
#                       [--tone Hz] [--secs N] [--expect-wf kHz,...]
#
# Exit status 0 if audio arrived (and carries --tone, if given) and the
# waterfall shows a peak near each --expect-wf frequency.
#
# Needs python3 with websocket-client and numpy.
import argparse
import struct
import sys
import time

import numpy as np
import websocket


def connect(host, port, stream):
    ws = websocket.create_connection(
        f"ws://{host}:{port}/{int(time.time())}/{stream}", timeout=10)
    ws.send("SET auth t=kiwi p=")
    return ws


def keepalive(ws, last):
    if time.time() - last > 1:
        ws.send("SET keepalive")
        return time.time()
    return last


def msgs(body):
    """MSG frames: space-separated key=value pairs."""
    out = {}
    for kv in body.decode(errors="replace").split(" "):
        k, _, v = kv.partition("=")
        out[k] = v
    return out


def audio(args):
    ws = connect(args.host, args.port, "SND")
    ws.send("SET ident_user=kiwi-check")
    rate = None
    pcm = []
    rssi = []
    t0 = last = time.time()
    while time.time() - t0 < args.secs:
        last = keepalive(ws, last)
        try:
            data = ws.recv()
        except websocket.WebSocketTimeoutException:
            continue
        if isinstance(data, str):
            data = data.encode()
        tag, body = data[:3], data[3:]
        if tag == b"MSG":
            m = msgs(body[1:])
            if "audio_rate" in m:
                rate = int(m["audio_rate"])
                ws.send(f"SET AR OK in={rate} out=48000")
                ws.send("SET squelch=0 max=0")
                ws.send("SET compression=0")
                ws.send("SET agc=1 hang=0 thresh=-100 slope=6 decay=1000 "
                        "manGain=50")
                lo, hi = (-5000, 5000) if args.mode in ("am", "amn") \
                    else (300, 2700)
                ws.send(f"SET mod={args.mode} low_cut={lo} high_cut={hi} "
                        f"freq={args.freq:.3f}")
            if "too_busy" in m or "badp" in m and m["badp"] != "0":
                print(f"audio: rejected: {m}")
                return False
        elif tag == b"SND":
            flags, seq = struct.unpack("<BI", body[0:5])
            (sm,) = struct.unpack(">H", body[5:7])
            rssi.append(0.1 * sm - 127)
            pcm.append(np.frombuffer(body[7:], dtype=">i2"))
    ws.close()
    if not pcm or rate is None:
        print("audio: no SND frames")
        return False
    x = np.concatenate(pcm).astype(float)
    # drop the first second (AGC/filters settling)
    x = x[rate:] if len(x) > 2 * rate else x
    rms = np.sqrt(np.mean(x ** 2)) if len(x) else 0
    print(f"audio: rate {rate} Hz, {len(x)} samples, rms {rms:.0f}, "
          f"S-meter {np.median(rssi):.1f} dBm")
    ok = len(x) > rate and rms > 0
    if args.tone and len(x) > 1024:
        w = np.hanning(len(x))
        spec = np.abs(np.fft.rfft((x - x.mean()) * w))
        f = np.fft.rfftfreq(len(x), 1 / rate)
        band = f > 100
        fb, sb = f[band], spec[band]
        tones = []
        for i in np.argsort(sb)[::-1][:200]:
            if all(abs(fb[i] - fb[j]) > 20 for j in tones):
                tones.append(i)
            if len(tones) == 3:
                break
        peak = fb[tones[0]]
        print("audio: strongest tones " +
              ", ".join(f"{fb[i]:.1f} Hz ({20 * np.log10(sb[i] / sb[tones[0]]):.0f} dB)"
                        for i in tones) + f", expect {args.tone:.0f} Hz")
        ok = ok and abs(peak - args.tone) < 10
    return ok


def waterfall(args):
    ws = connect(args.host, args.port, "W/F")
    ws.send("SET zoom=0 start=0")
    ws.send("SET maxdb=0 mindb=-100")
    ws.send("SET wf_speed=4")
    ws.send("SET wf_comp=0")
    lines = []
    span_khz = None
    t0 = last = time.time()
    while time.time() - t0 < min(args.secs, 8):
        last = keepalive(ws, last)
        try:
            data = ws.recv()
        except websocket.WebSocketTimeoutException:
            continue
        if isinstance(data, str):
            data = data.encode()
        tag, body = data[:3], data[3:]
        if tag == b"MSG":
            m = msgs(body[1:])
            if "bandwidth" in m:
                span_khz = float(m["bandwidth"]) / 1e3
        elif tag == b"W/F":
            body = body[1:]
            lines.append(np.frombuffer(body[12:], dtype=np.uint8))
    ws.close()
    if not lines:
        print("waterfall: no W/F frames")
        return False
    n = len(lines[-1])
    db = np.median(np.array([l for l in lines if len(l) == n]), axis=0)
    db = db.astype(float) - 255           # bytes are dB + 255
    span_khz = span_khz or 30000.0
    khz = (np.arange(n) + 0.5) * span_khz / n
    floor = np.median(db)
    print(f"waterfall: {len(lines)} lines x {n} bins over {span_khz:.0f} kHz, "
          f"floor {floor:.0f} dB")
    order = np.argsort(db)[::-1]
    peaks = []
    for i in order:
        if db[i] < floor + 10 or len(peaks) >= 8:
            break
        if all(abs(i - j) > 3 for j in peaks):
            peaks.append(i)
    for i in sorted(peaks):
        print(f"  peak {khz[i]:9.1f} kHz  {db[i]:6.1f} dB")
    ok = True
    bin_khz = span_khz / n
    for e in args.expect_wf:
        hit = any(abs(khz[i] - e) <= 2 * bin_khz for i in peaks)
        print(f"  expect {e:.1f} kHz: {'ok' if hit else 'MISSING'}")
        ok = ok and hit
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8073)
    ap.add_argument("--freq", type=float, default=10000.0, help="kHz")
    ap.add_argument("--mode", default="am")
    ap.add_argument("--tone", type=float, default=1000.0,
                    help="expected audio tone, Hz (0 = don't check)")
    ap.add_argument("--secs", type=float, default=6.0)
    ap.add_argument("--expect-wf", default="7074,10000,15000",
                    type=lambda s: [float(v) for v in s.split(",") if v],
                    help="kHz list of carriers the waterfall must show")
    args = ap.parse_args()
    a = audio(args)
    w = waterfall(args)
    print("PASS" if a and w else "FAIL")
    sys.exit(0 if a and w else 1)


if __name__ == "__main__":
    main()
