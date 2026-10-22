#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Simultaneous zoomed waterfall + IQ at the same centre: compares the two
# spectra on the waterfall's bins (frequency offset = best correlation lag;
# peaks in only one of them).
#   pair.py HOST FREQ_KHZ ZOOM SECS OUT.npz
import sys, time, threading, websocket, numpy as np
host, fkhz, zoom, secs = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
res = {}
def keep(ws, last):
    if time.time() - last > 1: ws.send("SET keepalive"); return time.time()
    return last
def wf():
    ws = websocket.create_connection(f"ws://{host}:8073/{int(time.time())}/W/F", timeout=5)
    for c in ["SET auth t=kiwi p=", "SET ident_user=pair-probe", f"SET zoom={zoom} cf={fkhz:.3f}",
              "SET maxdb=0 mindb=-160", "SET wf_speed=4", "SET wf_comp=0", "SET interp=0 cic=0", "SET window_func=0"]:
        ws.send(c)
    L, t0, last = [], time.time(), 0
    while time.time() - t0 < secs:
        last = keep(ws, last)
        try: d = ws.recv()
        except websocket.WebSocketTimeoutException: continue
        if isinstance(d, str): d = d.encode()
        if d[:3] == b"W/F":
            xb = int(np.frombuffer(d[4:8], "<u4")[0]); L.append((xb, np.frombuffer(d[16:], np.uint8).astype(float) - 255))
        elif d[:3] == b"MSG" and b"zoom=" in d: res["wfmsg"] = d[4:].decode(errors="replace")
    ws.close(); res["wf"] = L
def iq():
    ws = websocket.create_connection(f"ws://{host}:8073/{int(time.time())}/SND", timeout=5)
    ws.send("SET auth t=kiwi p="); ws.send("SET ident_user=pair-probe")
    Z, t0, last, fs = [], time.time(), 0, 12000.0
    while time.time() - t0 < secs:
        last = keep(ws, last)
        try: d = ws.recv()
        except websocket.WebSocketTimeoutException: continue
        if isinstance(d, str): d = d.encode()
        if d[:3] == b"MSG":
            m = d[4:].decode(errors="replace")
            for kv in m.split():
                if kv.startswith("sample_rate="): fs = float(kv.split("=")[1])
            if "audio_rate=" in m:
                ar = int(m.split("audio_rate=")[1].split()[0])
                for c in [f"SET AR OK in={ar} out=48000", "SET squelch=0 max=0", "SET compression=0",
                          "SET agc=0 hang=0 thresh=-100 slope=6 decay=1000 manGain=50",
                          f"SET mod=iq low_cut=-6000 high_cut=6000 freq={fkhz:.3f}"]:
                    ws.send(c)
        elif d[:3] == b"SND" and d[3] & 0x08:
            x = np.frombuffer(d[3+7+10:], ">i2").astype(float); Z.append(x[0::2] + 1j*x[1::2])
    ws.close(); res["iq"] = (np.concatenate(Z[10:]), fs)
t = [threading.Thread(target=wf), threading.Thread(target=iq)]
[x.start() for x in t]; [x.join() for x in t]
L = res["wf"]; xb = L[-1][0]
a = np.array([l for (b, l) in L if b == xb])
span = 61.44e6 / 2**zoom; binhz = span / 1024
f0 = xb * (61.44e6 / 2**14 / 1024)
fw = f0 + (np.arange(1024) + 0.5) * binhz
wmed = np.median(a, 0)
z, fs = res["iq"]
N = 1 << 14; nseg = len(z) // N
w = np.hanning(N)
P = np.mean([np.abs(np.fft.fftshift(np.fft.fft(z[i*N:(i+1)*N] * w)))**2 for i in range(nseg)], 0)
fi = fkhz*1e3 + (np.arange(N) - N//2) * fs / N
sel = np.where((fw > fkhz*1e3 - 5000) & (fw < fkhz*1e3 + 5000))[0]
ib = np.array([P[(fi >= fw[i]-binhz/2) & (fi < fw[i]+binhz/2)].sum() for i in sel])
idb = 10*np.log10(ib + 1e-9); wdb = wmed[sel]
idb -= np.median(idb); wdb = wdb - np.median(wdb)
print(f"centre {fkhz:.3f} kHz zoom {zoom}: WF {len(a)} lines, start {f0/1e3:.3f} kHz, bin {binhz:.1f} Hz; IQ {len(z)} samples @ {fs:.3f} Hz")
print(" off(Hz)  WF(dB)  IQ(dB)")
for k, i in enumerate(sel):
    if wdb[k] > 6 or idb[k] > 6:
        print(f" {fw[i]-fkhz*1e3:7.0f}  {wdb[k]:6.1f}  {idb[k]:6.1f}")
lags = range(-8, 9)
cc = [np.corrcoef(np.roll(wdb, l), idb)[0,1] for l in lags]
best = list(lags)[int(np.argmax(cc))]
print(f"corr(WF, IQ) lag0 {cc[8]:.2f}; best lag {best} bins ({best*binhz:.0f} Hz) corr {max(cc):.2f}")
np.savez(sys.argv[5], wmed=wmed, fw=fw, P=P, fi=fi)
