# web888-sdr: open kernel driver

GPL-2.0-or-later. Replaces the closed `zynqsdr` driver that is built into
the vendor kernel. Written only from `../docs/stock-driver.md` and
`../fpga/doc/register-map.md` (no vendor code).

Status: **builds, not yet tested**. Compiles warning-free (`W=1`) as an
out-of-tree module against the 6.18 kernel of the Yocto image
(web888-ng-os, linux-xlnx 6.18.10). Next: load it in the QEMU virtual
Web-888 (`../emu/`) on that image and run web888d against it.

## What it does

* `/dev/zynqsdr` with the stock ioctl ABI (`web888_sdr.h`, type `'Z'`,
  numbers 0..21, same structure layouts), so the stock server and web888d's
  `zynqsdr` backend work unchanged. One opener at a time; open and close
  stop all streams, as with the stock driver.
* Works with the stock bitstream (signature `0xAA55xxxx`) and the open one
  (`0x0E5Dxxxx`).
* No device-binding ("genuine") check.
* DMA rings: three 0x7FC00-byte buffers (RX, WF0, WF1) allocated once at
  probe, cached, synced before each copy. A stream stop can never race
  with freeing its buffer.

Extensions (open bitstream):

* `poll()`: `POLLIN` when a running stream has data, `POLLPRI` for a PPS
  period. The PL raises an interrupt per 128-byte burst (tens of thousands
  per second for RX, far more for a wide waterfall), so the driver enables
  a stream's interrupt only while a reader waits in `poll()` and disables
  it again at the first one.
* RX overrun detection: STS 0x38 counts bursts without wrapping, so a
  lapped ring is visible. The driver skips to the newest half ring on a
  frame boundary (keeps frame alignment for the reader) and counts the
  loss.
* `ZSDR_GET_STATS`: FPGA extension registers (build id, flags, ADC
  overflow and peak, frame/burst/drop counters) and the driver's overrun
  counters.
* sysfs on the platform device: `signature`, `bitstream`.

## Device tree

Binds to either node:

```dts
/* vendor DT: no reg, fixed addresses 0x40000000 / 0x41000000 / 0x42000000 */
zynqsdr {
	compatible = "rx888,zynqsdr";
	interrupt-parent = <&intc>;
	interrupts = <0 29 1>, <0 30 1>, <0 31 1>, <0 32 1>;
	gpios = <&gpio0 10 1>, <&gpio0 13 1>, <&gpio0 12 1>, <&gpio0 11 1>,
		<&gpio0 49 1>;
};

/* web888-ng */
sdr@40000000 {
	compatible = "web888-ng,sdr";
	reg = <0x40000000 0xa0>, <0x41000000 0x40>, <0x42000000 0x1000>;
	interrupt-parent = <&intc>;
	interrupts = <0 29 1>, <0 30 1>, <0 31 1>, <0 32 1>;	/* RX, WF0, WF1, PPS */
	gpios = <&gpio0 10 1>, <&gpio0 13 1>, <&gpio0 12 1>, <&gpio0 11 1>,
		<&gpio0 49 1>;	/* HF/VHF, AD8370 CLK, LATCH, DATA, ref clock */
};
```

The GPIOs are driven with **raw** levels: the vendor DT marks them
active-low, but the stock driver used the legacy raw GPIO API, so raw
levels reproduce the stock pin states.

## Build

```
make KDIR=<kernel build dir> ARCH=arm CROSS_COMPILE=arm-oe-linux-gnueabi-
```

In the Yocto image it will be a module recipe in `meta-web888`.
