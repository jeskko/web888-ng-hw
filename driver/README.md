# web888-sdr: open kernel driver

GPL-2.0-or-later. Replaces the closed `zynqsdr` driver that is built into
the vendor kernel. Written only from `../docs/stock-driver.md` and
`../fpga/doc/register-map.md` (no vendor code).

Status: **works in the emulator, untested on hardware**. Compiles
warning-free (`W=1`) against the 6.18 kernel of the Yocto image
(web888-ng-os, linux-xlnx 6.18.10). In the QEMU virtual Web-888
(`../emu/run.sh --kernel <6.18 zImage>`, vendor userspace) an unmodified
web888d serves HPSDR through it, and `test/zsdr-test` passes every ioctl
check with both signatures and both DT nodes: RX levels and channel order,
ring overrun skip with frame alignment, WF one-shot and continuous, PPS,
`poll()` wakeups by interrupt, GPIO word, attenuator (carrier level
follows the code), error codes, unbind while open.

## What it does

* `/dev/zynqsdr` with the stock ioctl ABI (`web888_sdr.h`, type `'Z'`,
  numbers 0..21, same structure layouts), so the stock server and web888d's
  `zynqsdr` backend work unchanged. One opener at a time; open and close
  stop all streams, as with the stock driver.
* Works with the stock bitstream (signature `0xAA55xxxx`) and the open one
  (`0x0E5Dxxxx`).
* No device-binding ("genuine") check.
* No PL access before the first open(): at boot the bitstream is usually
  not loaded yet, and an access to an unconfigured (or reloading, or
  reset) PL never completes and hangs the CPU. open() first checks the
  Zynq SLCR (PS-PL level shifters on, fabric reset 0 released), then the
  signature, and fails with `ENODEV` otherwise. `pl_check=0` (module
  parameter) skips the SLCR check, e.g. in the emulator before the
  bitstream is loaded through fpga_manager. The signature and build id
  are read at each open; sysfs shows the cached values ("unknown" before
  the first open).
* Unbinding (sysfs) while the device is open is safe: the open file keeps
  the driver state, its ioctls fail with `ENODEV` and `poll()` reports
  `POLLHUP`.
* DMA rings: three 0x7FC00-byte buffers (RX, WF0, WF1) allocated once at
  probe, cached, synced before each copy. A stream stop can never race
  with freeing its buffer.

Extensions (open bitstream):

* `poll()`: `POLLIN` when a running stream has data, `POLLPRI` for a PPS
  period. The PL raises an interrupt per 128-byte burst (tens of thousands
  per second for RX, far more for a wide waterfall), so the driver enables
  a stream's interrupt only while a reader waits in `poll()` for it and
  disables it again at the first one. `POLLIN` means any running stream
  has data.
* RX overrun detection: STS 0x38 counts bursts since RX start (extended
  to 64 bits in the driver), so a lapped ring is visible. When the reader
  falls within 1/8 ring of being lapped, the driver skips to the newest
  half ring on a frame boundary (keeps frame alignment for the reader) and
  counts the loss.
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

In the Yocto image: recipe `web888-sdr` in `meta-web888` (autoloaded).
For quick cycles, `YOCTO=<kas work dir> ./build-yocto.sh` builds
`out/web888_sdr.ko` against the image's kernel in seconds.

## Test

`test/zsdr-test` checks every ioctl against the emulator's PL model
(default scene; it needs the device to itself, so stop `sdrd` first).
`YOCTO=<kas work dir> test/build-yocto.sh` builds it as a static ARMv7
binary (`out/zsdr-test`), which runs on the Yocto image and the vendor
userspace alike.

```
emu/tests/vm.sh start --kernel <6.18 zImage> [--stock-sig] [--dtb build/fw/web888-emu-ng.dtb]
# in the guest: insmod web888_sdr.ko pl_check=0; rc-service sdrd stop; ./zsdr-test
```

`zsdr-test --pl-up` (emulator only) sets the SLCR the way fpga_manager
leaves it after a load, to exercise the PL readiness check with
`pl_check=1`.
