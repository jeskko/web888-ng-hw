#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# IQ capture on one audio channel, AGC off; reports the 1-ms power envelope
# and its strongest modulation frequencies (e.g. 100 Hz mains-gated noise).
#   iqcap.py HOST FREQ_KHZ SECS OUT.npy
import sys, time, struct, websocket, numpy as np
host, fkhz, secs = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
ws = websocket.create_connection(f"ws://{host}:8073/{int(time.time())}/SND", timeout=5)
ws.send("SET auth t=kiwi p="); ws.send("SET ident_user=iq-probe")
rate, iq, t0, last = None, [], time.time(), 0
while time.time() - t0 < secs:
    if time.time() - last > 1: ws.send("SET keepalive"); last = time.time()
    try: d = ws.recv()
    except websocket.WebSocketTimeoutException: continue
    if isinstance(d, str): d = d.encode()
    if d[:3] == b"MSG":
        m = d[4:].decode(errors="replace")
        if m.startswith("too_busy"): print(m); sys.exit(1)
        if "sample_rate" in m or "audio_rate" in m:
            for kv in m.split():
                if kv.startswith("sample_rate="): rate = float(kv.split("=")[1])
                if kv.startswith("audio_rate=") and rate is None: rate = float(kv.split("=")[1])
            if "audio_rate" in m:
                ar = int(m.split("audio_rate=")[1].split()[0])
                for c in [f"SET AR OK in={ar} out=48000", "SET squelch=0 max=0", "SET compression=0",
                          "SET agc=0 hang=0 thresh=-100 slope=6 decay=1000 manGain=50",
                          f"SET mod=iq low_cut=-5000 high_cut=5000 freq={fkhz:.3f}"]:
                    ws.send(c)
    elif d[:3] == b"SND":
        body = d[3:]
        flags = body[0]
        if not flags & 0x08: continue
        iq.append(np.frombuffer(body[7+10:], ">i2").astype(float))
ws.close()
x = np.concatenate(iq[5:]); z = x[0::2] + 1j*x[1::2]
fs = rate or 12000.0
p = np.abs(z)**2
print(f"{fkhz/1000:.3f} MHz: {len(z)} IQ samples @ {fs:.1f} Hz, mean power {10*np.log10(p.mean()+1e-9):.1f} dB")
n = int(fs/1000); e = p[:len(p)//n*n].reshape(-1, n).mean(1); edb = 10*np.log10(e+1e-9)
print(f"  1-ms power: p10 {np.percentile(edb,10):.1f} p50 {np.percentile(edb,50):.1f} p90 {np.percentile(edb,90):.1f} dB")
E = np.abs(np.fft.rfft(e - e.mean()))
fe = np.fft.rfftfreq(len(e), 1e-3)
top = np.argsort(E[fe > 5])[::-1][:6]
print("  envelope modulation peaks (Hz):", ", ".join(f"{fe[fe>5][i]:.1f}" for i in top),
      f"| 100 Hz rel {20*np.log10(E[np.argmin(abs(fe-100))]/np.median(E[fe>5])):.1f} dB, 50 Hz rel {20*np.log10(E[np.argmin(abs(fe-50))]/np.median(E[fe>5])):.1f} dB over median")
np.save(sys.argv[4], z)
