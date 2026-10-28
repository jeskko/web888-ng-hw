# wdt

Arms the Linux watchdog for tests on a remote board (see
`docs/hardware-test-plan.md` §0), so a hard hang resets the board instead
of needing a power cycle. Static ARMv7, no libc: `make CC=clang`.

    wdt info | keep TIMEOUT [SECONDS] | hang TIMEOUT
