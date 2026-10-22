# Kiwi-protocol measurement tools

Small clients for a running Kiwi-protocol server (the stock Web-888 server,
or web888d later): capture waterfall lines and IQ, and compare them. Used
on 2026-10-21/22 to trace bogus-looking waterfall lines above ~24 MHz to
100 Hz mains-gated switch-mode noise picked up by the antenna, not to the
FPGA or server (see web888-ng `doc/design.md` §5.2).

Each connection takes one receiver channel (W/F or SND) for a few
seconds; keep runs short on a unit with users. Needs python3 with
`websocket-client` and `numpy`.

| tool | does |
|---|---|
| `wfcap.py` | waterfall lines → `.npz` |
| `iqcap.py` | IQ on one channel, power-envelope modulation (e.g. 100 Hz) |
| `pair.py` | simultaneous waterfall + IQ at one centre: offset, waterfall-only peaks |
| `texture.py` | noise texture of `wfcap.py` captures: within-line spread, line-to-line steps |

`../../emu/tests/kiwi-check.py` is the pass/fail end-to-end check for the
emulator.
