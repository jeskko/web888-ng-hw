# SPDX-License-Identifier: GPL-3.0-or-later
## Web-888 pin constraints.
## Pins from rx-888.com/web/design/pinout.html; I/O standards follow the
## RaspSDR/red-pitaya-notes `web888` branch (cfg/ports.xdc), whose open
## bitstreams run on this board: bank 34 (ADC) is 1.8 V, bank 35 is 3.3 V.

### ADC clock (LTC2208 CLKOUT, differential, MRCC pins)
set_property IOSTANDARD DIFF_HSTL_I_18 [get_ports adc_clk_p_i]
set_property IOSTANDARD DIFF_HSTL_I_18 [get_ports adc_clk_n_i]
set_property PACKAGE_PIN U18 [get_ports adc_clk_p_i]
set_property PACKAGE_PIN U19 [get_ports adc_clk_n_i]

### ADC data + overflow
set_property IOSTANDARD LVCMOS18 [get_ports {adc_dat_a_i[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports adc_ofl_i]
set_property IOB TRUE [get_ports {adc_dat_a_i[*]}]
set_property IOB TRUE [get_ports adc_ofl_i]

set_property PACKAGE_PIN V17 [get_ports {adc_dat_a_i[0]}]
set_property PACKAGE_PIN U17 [get_ports {adc_dat_a_i[1]}]
set_property PACKAGE_PIN Y17 [get_ports {adc_dat_a_i[2]}]
set_property PACKAGE_PIN W16 [get_ports {adc_dat_a_i[3]}]
set_property PACKAGE_PIN Y16 [get_ports {adc_dat_a_i[4]}]
set_property PACKAGE_PIN W15 [get_ports {adc_dat_a_i[5]}]
set_property PACKAGE_PIN W14 [get_ports {adc_dat_a_i[6]}]
set_property PACKAGE_PIN Y14 [get_ports {adc_dat_a_i[7]}]
set_property PACKAGE_PIN W13 [get_ports {adc_dat_a_i[8]}]
set_property PACKAGE_PIN V12 [get_ports {adc_dat_a_i[9]}]
set_property PACKAGE_PIN V13 [get_ports {adc_dat_a_i[10]}]
set_property PACKAGE_PIN T14 [get_ports {adc_dat_a_i[11]}]
set_property PACKAGE_PIN T15 [get_ports {adc_dat_a_i[12]}]
set_property PACKAGE_PIN V15 [get_ports {adc_dat_a_i[13]}]
set_property PACKAGE_PIN T16 [get_ports {adc_dat_a_i[14]}]
set_property PACKAGE_PIN V16 [get_ports {adc_dat_a_i[15]}]
set_property PACKAGE_PIN P20 [get_ports adc_ofl_i]

### ADC control (bank 35, 3.3 V)
set_property IOSTANDARD LVCMOS33 [get_ports {adc_pga_o adc_dith_o}]
set_property SLEW SLOW [get_ports {adc_pga_o adc_dith_o}]
set_property DRIVE 8 [get_ports {adc_pga_o adc_dith_o}]
set_property PACKAGE_PIN K14 [get_ports adc_pga_o]
set_property PACKAGE_PIN J15 [get_ports adc_dith_o]

### GPS PPS
set_property IOSTANDARD LVCMOS33 [get_ports pps_i]
set_property PACKAGE_PIN K18 [get_ports pps_i]

### Antenna switch outputs (EXTIO)
set_property IOSTANDARD LVCMOS33 [get_ports {antenna_o[*]}]
set_property SLEW SLOW [get_ports {antenna_o[*]}]
set_property DRIVE 8 [get_ports {antenna_o[*]}]
set_property PACKAGE_PIN G17 [get_ports {antenna_o[0]}]
set_property PACKAGE_PIN G18 [get_ports {antenna_o[1]}]
set_property PACKAGE_PIN H16 [get_ports {antenna_o[2]}]
set_property PACKAGE_PIN H17 [get_ports {antenna_o[3]}]
set_property PACKAGE_PIN J18 [get_ports {antenna_o[4]}]
set_property PACKAGE_PIN H18 [get_ports {antenna_o[5]}]

### LED
set_property IOSTANDARD LVCMOS33 [get_ports led_o]
set_property SLEW SLOW [get_ports led_o]
set_property DRIVE 4 [get_ports led_o]
set_property PACKAGE_PIN F16 [get_ports led_o]

### Timing
## The clock period is set per build (HF 122.88 MHz / VHF 110.592 MHz max)
## in vivado/build.tcl through the ADC_CLK_PERIOD variable; see timing.xdc.

## Slow / asynchronous I/O
set_false_path -from [get_ports pps_i]
set_false_path -to [get_ports {antenna_o[*] led_o adc_pga_o adc_dith_o}]
