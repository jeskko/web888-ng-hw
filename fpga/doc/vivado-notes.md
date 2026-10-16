# Vivado notes

Built and timing-clean with **Vivado 2026.1** (`make hf`, `make vhf`).
The block design is created from `vivado/build.tcl`: PS7 (preset
`cfg/ps7_preset.xml`) + `web888_core` as a module reference. Vivado infers
the four AXI3 interfaces, the 122.88 MHz clock and the 4-bit interrupt from
port names and attributes; the generated address map puts the registers at
0x40000000-0x43FFFFFF and gives the HP masters the 512 MB DDR.

## Host setup used (Arch-based Linux)

A local launcher script (set `VIVADO = /path/to/launcher` in `local.mk`) starts Vivado with:

* `libncurses.so.5` / `libtinfo.so.5` symlinks to ncurses 6
  (Vivado still links the old soname);
* `XILINXD_LICENSE_FILE` pointing to a license file that contains only the
  Basic-tier entries. Since 2026.1 a combined license (Basic + Alveo) makes
  Vivado pick the Alveo tier, which does not cover Zynq-7000, and then no
  parts are available at all ("No part matched").

## Timing

Constraint 8.000 ns (125 MHz) for HF, 9.000 ns for VHF. Fixed so far:
waterfall output rounding/saturation (extra pipeline stage) and the DMA
writer's burst-issue decision (registered data-available check).
