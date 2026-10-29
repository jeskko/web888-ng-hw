# physmem

Reads and writes physical memory through /dev/mem on the stock firmware
(no devmem there): `r32 ADDR`, `w32 ADDR VALUE`, `dump ADDR LEN` (raw bytes
to stdout, e.g. the ramoops region a chain-loaded kernel left before a
watchdog reset). Static ARMv7, no libc: `make CC=clang`.
