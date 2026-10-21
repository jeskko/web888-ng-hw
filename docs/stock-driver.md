# Stock `zynqsdr` kernel driver: interface notes

Interoperability notes for the stock firmware (web-888-20260919, kernel
`6.6.110-xilinx`), where the driver is built into the kernel, not a module.
They describe the interface the stock driver expects from the PL, so that the
open bitstream can run unchanged on stock firmware. The driver functions are
`zynqsdr_probe`, `zynqsdr_ioctl`, `zynqsdr_open` and `zynqsdr_remove`
(kallsyms names).

## Driver structure
- `misc_register` → `/dev/zynqsdr`; one opener at a time (`mutex_trylock`, 3 retries × 1 s).
- probe: 5 GPIOs from DT (`of_get_named_gpio` index 0..4), checks 4 IRQs exist (**never requested — driver polls**).
- open: `ioremap` PL windows, reads signature, inits mutex, runs genuine check (below).
- DMA buffers: `dma_alloc_attrs(0x7FC00)` per stream, allocated lazily on first RX_START / WF_START, kept until close.
- Reads: `dma_sync_single_for_cpu` + `copy_to_user` from a 0x7FC00-byte ring; HW write pointer read from status regs.

## PL address windows
| phys | size | content |
|---|---|---|
| 0x40000000 | 0xA0 | CFG (= hub `cfg_data[1279:0]`) |
| 0x41000000 | 0x18 | STS (= hub `sts_data[191:0]`) |
| 0x42000000 | 0x1000 | PPS FIFO read port (hub AXIS slave from `pps_cnt`) |

## CFG register map (0x40000000)
| off | width | field | written by |
|---|---|---|---|
| 0x00 | u16 | control. bit0 = RX enable (0 = reset), bit(n+1) = WF n enable, bit7 = PPS counter enable | RX_START, WF_START, PPS_START |
| 0x02 | u16 | RX stage-2 CIC decimation (5..40; total = ×256) | RX_START |
| 0x04 + 8·ch | u64 | RX ch NCO phase increment (f/fs·2^48), ch = 0..12 → 0x04..0x6B (= `rx_cfg[831:0]`) | RX_PARAM |
| 0x6C + 12·n | u64 | WF n NCO phase increment | WF_PARAM |
| 0x74 + 12·n | u32 | WF n CIC decimation (1..8192), n = 0..1 → 0x6C..0x83 (= `wf_cfg[191:0]`) | WF_PARAM |
| 0x84 | u32 | GPIO word: [5:0] antenna, 6 dither, 7 PGA, 8 LED | SET_GPIO (read back by GET_GPIO) |
| 0x8C | u32 | RX DMA ring phys addr | RX_START (first) |
| 0x90 | u16 | RX DMA ring length − 1 in 128-byte units (0x0FF7 → 0x7FC00 B) | RX_START (first) |
| 0x92 + 6·n | u32 | WF n DMA ring phys addr (unaligned!) | WF_START |
| 0x96 + 6·n | u16 | WF n DMA ring length − 1 in 128-byte units (0x0FF7) | WF_START |
| 0x9E | u16 | WF mode: bit n = 1 → one-shot (stop after a block), 0 → continuous (ioctl arg bit 16) | WF_START |

Hub must accept byte/halfword strobes and unaligned word access at 0x92/0x98 (compiler may split).

## STS register map (0x41000000)
| off | width | field |
|---|---|---|
| 0x00 | u32 | signature: byte0 = #RX channels (12 on current stock, 0xAA55020C), byte1 = #WF channels (2); printed "FPGA Signature: 0x%x" |
| 0x04 | u16 | RX DMA write pointer, 128-byte units |
| 0x06 + 2·n | u16 | WF n DMA write pointer, 128-byte units |
| 0x0A | u16 | PPS FIFO not-empty / count (PPS_READ returns -EBUSY if 0) |
| 0x0C | u64 | FPGA device DNA (57 bit, DNA_PORT): GET_DNA, device binding |
| 0x14 | u32 | not referenced by driver (likely pps_tick / ovf) |

PPS_READ reads one u32 from 0x42000000 (ADC clocks between PPS edges).

## ioctl table (type 'Z')
| cmd | nr | name | arg | action |
|---|---|---|---|---|
| 0x40045a00 | 0 | AD8370_SET | u8 code | bit-bang 8 bits MSB-first: GPIO latch=0, clk; data,clk↑,clk↓ ×8; latch=1 |
| 0x40045a01 | 1 | MODE_SET | bool | GPIO HF/VHF switch |
| 0x40045a02 | 2 | CLK_SET | bool | GPIO ref clock select |
| 0x80085a03 | 3 | GET_DNA | →u64 | STS 0x0C |
| 0x40045a04 | 4 | RX_START | decim 5..40 | clr ctrl.0; set decim; alloc+program ring; set ctrl.0 |
| 0x400c5a05 | 5 | RX_PARAM | {u32 ch, u64 inc} | CFG 0x04+8ch |
| 0xc00c5a06 | 6 | RX_READ | {u32 ch?, void* buf, u32 len}→{.., read} | needs ctrl.0; copy from ring up to HW ptr (STS 0x04 ×128) |
| 0x40045a07 | 7 | SET_GPIO | u32 | CFG 0x84 |
| 0x80045a08 | 8 | GET_GPIO | →u32 | CFG 0x84 |
| 0x80045a09 | 9 | GET_SIGNATURE | →u32 | STS 0x00 |
| 0x40045a0a | 10 | WF_START | ch \| bit16 continuous | clr ctrl.(ch+1); alloc+program ring; set mode bit; set ctrl.(ch+1) |
| 0x400c5a0b | 11 | WF_PARAM | {u16 ch, u16 decim, u64 inc} | CFG 0x6C+12ch (only rewrites on change) |
| 0xc00e5a0c | 12 | WF_READ | {u16 ch, void* buf, u32 len}→{.., read} | needs ctrl.(ch+1); ptr STS 0x06+2ch |
| 0x40045a14 | 20 | PPS_START | bool | clr ctrl.7, udelay(50), set ctrl.7 if arg |
| 0x80045a15 | 21 | PPS_READ | →u32 | -EBUSY if STS 0x0A == 0 else read PPS FIFO |

GPIO DT order (index → use): 0 HF/VHF switch, 1 AD8370 CLK, 2 AD8370 LATCH, 3 AD8370 DATA, 4 ref-clk select
(website: MIO 10 / 13 / 12 / 11 / 49).

## Device binding ("Genuine Web-888")
- On open, the stock driver checks that the **eth0 MAC address matches a value
  derived from the FPGA device DNA** (STS 0x0C). On a match it prints
  "Genuine Web-888 Detected".
- Without a match, `RX_READ`/`WF_READ` deliver samples only until a deadline
  set at driver probe: probe time + 600 s. The ring keeps running, but the
  server receives only zeros. The deadline is in **wall-clock time**
  (`ktime_get_with_offset`, apparently `TK_OFFS_REAL`). Probe runs at boot
  while the clock still reads 1970, so the first NTP or `swclock` step
  passes the deadline. In practice data stops as soon as the clock is set,
  not after 10 minutes. The emulator (`emu/`) shows this: with a
  non-matching MAC the stock server shows zero audio and waterfall about a
  minute after boot.
- The check is sticky per boot: once it passes, later opens skip it. After a
  failed check, the next open (e.g. a server restart) checks again.
- Consequences:
  - The open bitstream reports the real device DNA at STS 0x0C, so a genuine
    board keeps working with the stock driver. The DNA_PORT bit order must
    match the stock bitstream's (to be verified on hardware; see
    `hardware-test-plan.md`).
  - To test DNA with the stock kernel, **reboot** with the open bitstream in
    place. A service restart after stock already passed won't re-check.
  - Don't change the eth0 MAC on a dev unit that runs the stock kernel.
  - The open driver will not have this check.

## Notes for the open FPGA
- All DMA is a ring of 128-byte bursts with a 16-bit burst pointer exported to STS; no descriptors, no interrupts needed.
- WF one-shot mode: write one block then stop (TDM sharing); continuous: wrap the ring.
- The vendor's IRQ_F2P[3:0] lines exist in DT but are unused by the driver — an open driver could use them.
