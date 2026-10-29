# SPDX-License-Identifier: GPL-3.0-or-later
# Build the Web-888 open bitstream.
#
#   vivado -mode batch -source vivado/build.tcl -tclargs hf     ;# 122.88 MHz ADC clock
#   vivado -mode batch -source vivado/build.tcl -tclargs vhf    ;# 61.44 .. 110.592 MHz
#   vivado -mode batch -source vivado/build.tcl -tclargs pfb    ;# the channelizer, 122.88 MHz
#
# Output: build/<variant>/websdr_<variant>.bit (+ reports). The file is a
# drop-in for /media/mmcblk0p1/websdr_<variant>.bit on the stock firmware.
#
# Tested against: not yet (written without Vivado at hand) -- expect to fix
# small things on the first run, see doc/vivado-notes.md.

set variant [lindex $argv 0]
if {$variant eq ""} { set variant hf }
set jobs [expr {[llength $argv] > 1 ? [lindex $argv 1] : 8}]

set root [file normalize [file join [file dirname [info script]] ..]]
set build [file join $root build $variant]
file mkdir $build

switch -- $variant {
  hf  { set clkin_ps 8138; set pll_mult 8;  set xdc_period 8.000; set nrx 12; set guard_ns 0.400; set pfb 0 }
  vhf { set clkin_ps 9042; set pll_mult 14; set xdc_period 9.000; set nrx 13; set guard_ns 0.500; set pfb 0 }
  pfb { set clkin_ps 8138; set pll_mult 8;  set xdc_period 8.000; set nrx 12; set guard_ns 0.400; set pfb 1 }
  default { error "unknown variant '$variant' (hf|vhf|pfb)" }
}
set build_id [expr 0x[clock format [clock seconds] -format %Y%m%d]]

# ---------------------------------------------------------------- project
create_project -force web888_$variant [file join $build vivado] -part xc7z010clg400-1
set_property target_language Verilog [current_project]

add_files [glob [file join $root rtl *.v] [file join $root rtl gen *.v]]
add_files [file join $root rtl gen sincos_qw.mem]
# the channelizer (PFB build): its RTL and ROM tables, found by name
if {$pfb} {
  add_files [glob [file join $root rtl fft *.v]]
  add_files [glob [file join $root rtl gen pfb_*.mem]]
  add_files [file join $root rtl gen tune_fir.mem]
}

# RX channel count follows the vendor: 12 at 122.88 MHz (13 was unstable on
# some boards there), 13 in the vhf bitstream (ADC <= 110.592 MHz; the stock
# server names this choice `use_13ch`).

# Timing guardband: extra setup uncertainty on top of the clock period
# (guard_ns above): hf effectively 7.6 ns (131.6 MHz, +7.1 % over
# 122.88 MHz), vhf 8.5 ns (117.6 MHz, +6.4 % over 110.592 MHz), so boards on the slow
# corner or running hot keep real slack. (A shorter create_clock period
# would push the PLL VCO out of range in DRC.) The stock 13-ch HF bitstream
# failed on some boards at 122.88 MHz (docs/stability-64mhz.md).

# per-variant timing constraints
set tf [open [file join $build timing.xdc] w]
puts $tf "create_clock -period $xdc_period -name adc_clk \[get_ports adc_clk_p_i\]"
puts $tf "set_input_delay -clock adc_clk -max 4.000 \[get_ports {adc_dat_a_i\[*\] adc_ofl_i}\]"
puts $tf "set_input_delay -clock adc_clk -min 1.300 \[get_ports {adc_dat_a_i\[*\] adc_ofl_i}\]"
puts $tf "set_clock_uncertainty -setup $guard_ns \[get_clocks -of_objects \[get_pins -hierarchical -filter {NAME =~ *clkgen/pll/CLKOUT0}\]\]"
puts $tf "set_property BITSTREAM.GENERAL.COMPRESS TRUE \[current_design\]"
close $tf
add_files -fileset constrs_1 [list [file join $root constraints web888.xdc] [file join $build timing.xdc]]

# ---------------------------------------------------------------- block design
create_bd_design system

create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps_0
set_property CONFIG.PCW_IMPORT_BOARD_PRESET [file join $root cfg ps7_preset.xml] [get_bd_cells ps_0]
set_property -dict [list \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_USE_S_AXI_HP0 {1} CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
  CONFIG.PCW_USE_S_AXI_HP1 {1} CONFIG.PCW_S_AXI_HP1_DATA_WIDTH {64} \
  CONFIG.PCW_USE_S_AXI_HP2 {1} CONFIG.PCW_S_AXI_HP2_DATA_WIDTH {64} \
  CONFIG.PCW_USE_FABRIC_INTERRUPT {1} CONFIG.PCW_IRQ_F2P_INTR {1} \
  CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE {1} CONFIG.PCW_GPIO_EMIO_GPIO_IO {8} \
  CONFIG.PCW_EN_RST0_PORT {1} CONFIG.PCW_EN_CLK0_PORT {1} \
] [get_bd_cells ps_0]

apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config {make_external "FIXED_IO, DDR" Master "Disable" Slave "Disable"} [get_bd_cells ps_0]

create_bd_cell -type module -reference web888_core core_0
set_property -dict [list \
  CONFIG.NRX $nrx \
  CONFIG.CLKIN_PERIOD_PS $clkin_ps \
  CONFIG.PLL_MULT $pll_mult \
  CONFIG.BUILD_ID $build_id \
  CONFIG.PFB $pfb \
] [get_bd_cells core_0]

connect_bd_intf_net [get_bd_intf_pins ps_0/M_AXI_GP0] [get_bd_intf_pins core_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins core_0/m_axi_rx]  [get_bd_intf_pins ps_0/S_AXI_HP0]
connect_bd_intf_net [get_bd_intf_pins core_0/m_axi_wf0] [get_bd_intf_pins ps_0/S_AXI_HP1]
connect_bd_intf_net [get_bd_intf_pins core_0/m_axi_wf1] [get_bd_intf_pins ps_0/S_AXI_HP2]

connect_bd_net [get_bd_pins core_0/clk_out] \
  [get_bd_pins ps_0/M_AXI_GP0_ACLK] [get_bd_pins ps_0/S_AXI_HP0_ACLK] \
  [get_bd_pins ps_0/S_AXI_HP1_ACLK] [get_bd_pins ps_0/S_AXI_HP2_ACLK]
connect_bd_net [get_bd_pins ps_0/FCLK_RESET0_N] [get_bd_pins core_0/ps_resetn]
connect_bd_net [get_bd_pins core_0/irq]      [get_bd_pins ps_0/IRQ_F2P]
connect_bd_net [get_bd_pins core_0/emio_gpio] [get_bd_pins ps_0/GPIO_I]
connect_bd_net [get_bd_pins ps_0/FCLK_CLK0] [get_bd_pins core_0/fclk]

# board ports: name direction msb (-1 = scalar)
foreach {name dir msb} {
  adc_clk_p_i I -1  adc_clk_n_i I -1  adc_dat_a_i I 15  adc_ofl_i I -1
  adc_pga_o   O -1  adc_dith_o  O -1  pps_i       I -1  antenna_o O 5  led_o O -1
} {
  if {$msb < 0} { create_bd_port -dir $dir $name } \
  else          { create_bd_port -dir $dir -from $msb -to 0 $name }
  connect_bd_net [get_bd_ports $name] [get_bd_pins core_0/$name]
}

# address map: registers at 0x40000000 (64 MB window), HP ports see DDR
assign_bd_address -target_address_space /ps_0/Data \
  -offset 0x40000000 -range 64M [get_bd_addr_segs core_0/s_axi/reg0]
assign_bd_address

validate_bd_design
save_bd_design

set wrapper [make_wrapper -files [get_files system.bd] -top]
add_files -norecurse $wrapper
set_property top system_wrapper [current_fileset]

# ---------------------------------------------------------------- synthesise
# first on its own: a per-module utilisation report even if placement
# fails (a resource over-used)
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  error "synthesis failed"
}
open_run synth_1
report_utilization -hierarchical -hierarchical_depth 6 \
  -file [file join $build synth_utilization_hier.txt]
report_utilization -file [file join $build synth_utilization.txt]
# each memory's mapping (block or distributed), where the tool has it
catch {report_ram_utilization -detail -file [file join $build synth_utilization_ram.txt]}
close_design

# ---------------------------------------------------------------- implement
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "implementation failed"
}

open_run impl_1
report_utilization    -file [file join $build utilization.txt]
report_timing_summary -file [file join $build timing.txt]
report_timing -setup -max_paths 50 -nworst 1 -sort_by group -file [file join $build timing_paths.txt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "WNS: $wns ns"

set bit [glob [file join $build vivado web888_$variant.runs impl_1 *.bit]]
file copy -force $bit [file join $build websdr_$variant.bit]
puts "bitstream: [file join $build websdr_$variant.bit] (BUILD_ID [format 0x%08x $build_id])"
if {$wns < 0} { puts "WARNING: timing not met" }
