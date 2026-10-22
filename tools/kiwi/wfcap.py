#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Capture Kiwi waterfall lines (server-default processing) to an .npz.
#   wfcap.py HOST ZOOM CF_KHZ OUT.npz [SECS]
# Saves a[lines, 1024] in dB (byte - 255), x_bin, zoom, cf.
import sys, time, websocket, numpy as np
host, zoom, cf, out = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
secs = float(sys.argv[5]) if len(sys.argv) > 5 else 8
ws = websocket.create_connection(f"ws://{host}:8073/{int(time.time())}/W/F", timeout=5)
for c in ["SET auth t=kiwi p=", "SET ident_user=wf-probe", f"SET zoom={zoom} cf={cf:.3f}",
          "SET maxdb=0 mindb=-160", "SET wf_speed=4", "SET wf_comp=0"]:
    ws.send(c)
lines, msgs, t0, last = [], [], time.time(), 0
while time.time() - t0 < secs:
    if time.time() - last > 1: ws.send("SET keepalive"); last = time.time()
    try: d = ws.recv()
    except websocket.WebSocketTimeoutException: continue
    if isinstance(d, str): d = d.encode()
    if d[:3] == b"MSG":
        m = d[4:].decode(errors="replace")
        if any(k in m for k in ("bandwidth", "zoom", "too_busy", "wf_", "badp", "start")): msgs.append(m[:160])
    elif d[:3] == b"W/F":
        xb, fz, seq = np.frombuffer(d[4:16], "<u4")
        lines.append((xb, fz, np.frombuffer(d[16:], np.uint8).astype(float) - 255))
ws.close()
print("\n".join(msgs))
if not lines: print("no lines"); sys.exit(1)
xb, fz, _ = lines[-1]
a = np.array([l[2] for l in lines if len(l[2]) == 1024])
np.savez(out, a=a, xb=xb, fz=fz, zoom=zoom, cf=cf)
print(f"{len(a)} lines, x_bin {xb}, flags_zoom 0x{fz:x}")
