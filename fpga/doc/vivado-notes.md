# Vivado notes

Built and timing-clean with **Vivado 2026.1** (`make hf`, `make vhf`).
The block design is created from `vivado/build.tcl`: PS7 (preset
`cfg/ps7_preset.xml`) + `web888_core` as a module reference. Vivado infers
the four AXI3 interfaces, the 122.88 MHz clock and the 4-bit interrupt from
port names and attributes; the generated address map puts the registers at
0x40000000-0x43FFFFFF and gives the HP masters the 512 MB DDR.

## Where it runs

Vivado runs only on the project's CI runner, which holds the one free
Basic licence seat (since 2026-10-22; AMD offers no second free seat):
`make ci`, or a push to `main` (see `../README.md`, CI). The host setup
below is how the first builds were made; the runner has the same needs
(old ncurses sonames: `LD_LIBRARY_PATH=/opt/vivado-compat` in
`.github/workflows/fpga.yml`, and a Basic-only licence file).

## Host setup used (Arch-based Linux)

A local launcher script (set `VIVADO = /path/to/launcher` in `local.mk`) starts Vivado with:

* `libncurses.so.5` / `libtinfo.so.5` symlinks to ncurses 6
  (Vivado still links the old soname);
* `XILINXD_LICENSE_FILE` pointing to a license file that contains only the
  Basic-tier entries. Since 2026.1 a combined license (Basic + Alveo) makes
  Vivado pick the Alveo tier, which does not cover Zynq-7000, and then no
  parts are available at all ("No part matched").

## Timing

Constraint 8.000 ns (125 MHz) for HF, 9.000 ns for VHF, plus 0.4 / 0.5 ns
of setup uncertainty as guardband (`vivado/build.tcl`); the CI timing gate
needs WNS >= 0 with it. Fixed so far: waterfall output rounding/saturation
(extra pipeline stage) and the DMA writer's burst-issue decision
(registered data-available check).

The channelizer (`rtl/fft/`) is placed and routed out of context by
`vivado/synth_pfb.tcl` (`make pfb`) at the HF constraint; its fixes so far
(one carry chain per clock in the FIR's sum and the complex multipliers)
are in `../../docs/channelizer.md` §5.
