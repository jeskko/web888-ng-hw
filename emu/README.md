# Virtual Web-888 (QEMU), work in progress

QEMU 11.1.2 out-of-tree patch set: a `web888` machine (subclass of
`xilinx-zynq-a9`) with `web888-pl`, a model of the FPGA logic
(CFG/STS/PPS FIFO, RX and WF DMA rings with synthetic DDC data per
`../fpga/doc/register-map.md`), Cadence I2C with a 24c64 EEPROM and an
Si5351 stub, and Zynq GPIO. The goal is to boot the **stock** firmware
(kernel with the closed `zynqsdr` driver, stock server) offline against
the model.

Vendor binaries (kernel, initramfs, DTB, SD image) are extracted locally
from the release zip and never committed.

## Status (2026-10-16)

| milestone | state |
|---|---|
| A. QEMU builds; bare-metal test reads registers, RX/WF rings, PPS | done |
| B. stock kernel boots to a shell | in progress (scripts below; not yet verified end to end) |
| C. `zynqsdr` probes, signature/DNA via `tools/zynqsdr-probe` | open |
| D. stock server streams, web UI on forwarded port 8073 | open |

## Files

* `build-qemu.sh`: fetch QEMU 11.1.2, apply `qemu/patches/*`, copy `qemu/files/`, build arm-softmmu
* `make-sdimage.sh`: SD image plus zImage/initramfs/DTB from the release zip (`FW_ZIP=...`)
* `make-dtb.sh`: emulator DT from the vendor DT (changes listed in the script header)
* `run.sh`: boot (`--mac`, `--dna`, `--stock-sig`, `--sig`, `--scene` options)
* `tests/vm.sh`: drive the serial console from scripts
* `scripts/bootbin.py`: boot.bin partition extraction

The stock driver stops delivering data 10 minutes after boot unless the
board MAC matches the one derived from the device DNA. Pass your own
unit's pair with `--mac`/`--dna` (read with `tools/zynqsdr-probe`) for
longer runs.
