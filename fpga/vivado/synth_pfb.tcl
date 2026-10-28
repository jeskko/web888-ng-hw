# SPDX-License-Identifier: GPL-3.0-or-later
# The channelizer with its outputs and DMA (rtl/fft/pfb_top.v: the chain,
# bin selector, power line, two ring writers) out of context, for its
# resources and timing (hw/docs/channelizer.md §3.6, §3.7): synthesis,
# placement and routing for the Web-888's part at the HF clock with the
# same guardband as the bitstream (8.0 ns + 0.4 ns setup uncertainty).
# Ports are unconstrained, so only register-to-register paths count.
#
#   vivado -mode batch -source vivado/synth_pfb.tcl -tclargs [JOBS]
#
# Output: build/pfb/{utilization,utilization_hier,timing}.txt, "WNS: x ns".

set jobs [expr {[llength $argv] > 0 ? [lindex $argv 0] : 8}]
set root [file normalize [file join [file dirname [info script]] ..]]
set build [file join $root build pfb]
file mkdir $build
set_param general.maxThreads $jobs

read_verilog [glob [file join $root rtl fft *.v]]
read_verilog [file join $root rtl axi_ring_writer.v] [file join $root rtl sync_fifo.v]
foreach m [glob [file join $root rtl gen pfb_*.mem]] { read_mem $m }

synth_design -top pfb_top -part xc7z010clg400-1 -mode out_of_context
create_clock -period 8.000 -name clk [get_ports clk]
set_clock_uncertainty -setup 0.400 [get_clocks clk]
report_utilization -file [file join $build utilization_synth.txt]

opt_design
place_design
phys_opt_design
route_design

report_utilization -file [file join $build utilization.txt]
report_utilization -hierarchical -hierarchical_depth 2 -file [file join $build utilization_hier.txt]
report_timing_summary -max_paths 10 -file [file join $build timing.txt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "WNS: $wns ns"
if {$wns < 0} { puts "WARNING: timing not met" }
