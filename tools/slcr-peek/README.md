# slcr-peek

Prints Zynq SLCR registers that say whether the PL can work (PL resets,
level shifters, PL clock 0). These are PS-side reads through /dev/mem, so
they are safe even when the PL's AXI port is dead. `slcr_peek gpio [N]` samples the open bitstream's liveness bits on EMIO. Static ARMv7, no libc:
`make CC=clang`.
