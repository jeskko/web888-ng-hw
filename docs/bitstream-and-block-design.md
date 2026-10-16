# Web-888 closed FPGA: what is known from public artifacts

Sources: rx-888.com/web/design/fpga.html (and its block diagrams),
official firmware image `web-888-alpine-3.20-armv7-20260919.zip`.

## Shipped bitstreams

| file | header | built | sha256 |
|---|---|---|---|
| websdr_hf.bit  (1 244 764 B) | `system_wrapper;COMPRESS=TRUE;UserID=0XFFFFFFFF;Version=2023.1`, part `7z010clg400` | 2025-04-13 14:07 | cacb1968…c0b3d6 |
| websdr_vhf.bit (1 249 832 B) | same | 2025-04-13 14:21 | 298415f0…7513e |

- Vivado 2023.1, block design top `system_wrapper`, compressed, **not encrypted**.
- FPGA has not been rebuilt since 2025-04-13 even though the server has kept changing → the HW/SW contract is stable.
- Separate HF and VHF builds (VHF = 2nd Nyquist zone, 118–150 MHz input; probably different ADC clock / DDS setup).

## Boot / PS facts (from boot.bin DTB and red-pitaya-notes `web888` branch)

- DDR: 512 MB (`memory@0 reg = <0 0x20000000>`).
- Standard `xlnx,zynq-devcfg-1.0` + `fpga-region`/`fpga-mgr` → bitstream loadable at runtime.
- No PL nodes in DTB → server presumably uses `/dev/mem` (see `server-fpga-interface.md`).
- PS config: Red Pitaya `cfg/red_pitaya.xml` with SPI0/1 off, SD CD off. DDR part param MT41J256M16 (Red Pitaya default).
- FSBL hook (`patches/red_pitaya_fsbl_hooks.c`) programs Si5351 @0x60 over i2c0 (CLK0 = ADC+FPGA clock, CLK2 = ext clock out); EEPROM @0x50.
- Pinout: matches `cfg/ports.xdc` on red-pitaya-notes `web888` branch (ADC D[15:0], OVF P20, clk U18/U19 diff, PPS K18, antenna_o[5:0], PGA K14, DITH J15, LED F16).
  - NOTE: XDC uses LVCMOS18 / DIFF_HSTL_I_18 for ADC bank; website says "all pins 3.3V CMOS". Must be checked against hardware (bank VCCO) before committing.

## Top-level block design (fpga_overall.png)

All clocked from ADC clock (122.88 MHz) via `util_ds_buf` → `adc_buf_v1_0` (register ADC data).

| instance | IP | notes |
|---|---|---|
| hub_0 | `web888_hub_v1_0` | AXI GP0 slave; `cfg_data[1279:0]`, `sts_data[191:0]`, `s00_axis` (from pps_cnt). Same pattern as Pavel Demin's `axi_hub`. |
| config_0 | `web888_config_v1_0` | slices cfg_data[1279:0] into: `rx_cfg[831:0]` (13×64-bit phase incr.), `rx_decim_o[7:0]`, `rx_dma_len[15:0]`, `rx_dma_addr[31:0]`, `rx_reset`, `wf_cfg[191:0]`, `wf_dma_addr_0/1[31:0]`, `wf_dma_len_0/1[15:0]`, `wf_mode0/1`, `wf_reset[1:0]`, `antenna_o[5:0]`, `led_o`, `adc_dith_o`, `adc_pga_o`, `pps_reset`, `ovf_set[15:0]` |
| rx_0 | hierarchy | 13-ch DDC → AXI HP0 |
| wf_0 | hierarchy | 2-ch waterfall DDC → AXI HP1, HP2 |
| pps_cnt | `web888_pps_v1_0` | `pps_tick[26:0]` + AXIS FIFO of PPS timestamps to hub |
| ovf_mod | `web888_adc_ovf_v1_0` | ADC overflow counter/threshold (`ovf_set[15:0]`) |
| dna_0 | `web888_dna_read_v1_0` | 57-bit device DNA (likely used for licensing/ID) |
| signature_0 | xlconstant 32 bit | design ID word |
| concat_0 | xlconcat → `sts_data[191:0]` | in0[31:0] signature?, in5[63:0] DNA, rx/wf sts_data[15:0] (DMA positions), pps_tick, ovf... |
| int_0 | xlconcat 4 bit → `IRQ_F2P[3:0]` | DMA `done` interrupts (rx, wf0, wf1, ...) |

## RX hierarchy (fpga_rx.png, fpga_rx_all.png)

Per channel n = 0..12:
`port_slicer` (64 bit of din[831:0]) → Pavel `axis_constant` → Xilinx **DDS Compiler** (phase in, 32-bit sin|cos out)
→ 2× `port_slicer` (16 bit) → 2× Xilinx **Multiplier** 16×16→32 with ADC B[15:0]
→ 2× Xilinx **CIC Compiler** (stage 1: N=3, R=256 → 480 kS/s)
→ `web888_rx_serial_comb_v1_0` (26 AXIS inputs → 1 TDM stream, padded)
→ Xilinx **CIC Compiler** multichannel `cic_reuse` (stage 2: N=5, R=40 → 12 kS/s, programmable rate via `axis_variable` `rate_decim` cfg[7:0])
→ `cic_cutoff_channel_axis_v1_0` → `web888_dma_v1_0` (min_addr, cfg_data[15:0] len, user_resetn, wf_mode) → m_axi (HP0).
Output I/Q 32 bit each.

## WF hierarchy (fpga_wf.png)

Two independent channels (din1[191:0] = 2×64-bit phase + 2×16-bit rate + …):
`axis_constant` → DDS Compiler → 2× Multiplier → 2× `axis_variable` (rate) → 2× **`web888_cic_v1_0` (custom variable-rate CIC)**
→ `web888_wf_comb_v1_0` (I+Q → one AXIS stream) → `web888_dma_v1_0` → m_axi / m_axi1 (HP1/HP2).
`wf_mode`: continuous loop vs. one-shot (TDM sharing among users). Output 16-bit I/Q.

## Utilisation (post-impl, fpga_res.png)
LUT 84 %, LUTRAM 26 %, FF 72 %, BRAM 55 %, DSP 75 %, IO 29 %, BUFG 9 %. Timing met at 122.88 MHz.

## Reusable open components
- Pavel Demin red-pitaya-notes (MIT): `port_slicer`, `axis_constant`, `axis_variable`, `axi_hub`, `axis_red_pitaya_adc`, `axis_ram_writer`, build scripts — the closed design visibly uses these.
- RaspSDR/red-pitaya-notes `web888` branch: board XDC, PS config, FSBL Si5351 init, device trees, working open-source sdr_receiver / hpsdr / ft8 / wspr bitstreams for this exact board.
- KiwiSDR Beagle_SDR_GPS `verilog/` (GPL): RX/WF/GPS Verilog, has xc7z007s target; server software is derived from it.
