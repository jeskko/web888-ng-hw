# SPDX-License-Identifier: GPL-3.0-or-later
# Web-888 open FPGA
#   make tables      regenerate ROM tables (rtl/gen)
#   make sim         run all simulations (Icarus Verilog) + analysis
#   make hf / vhf    build bitstreams with Vivado (PATH or local.mk)
#   make ci          build both on the project's CI runner (scripts/ci-build.sh)
#   make pfb         the channelizer datapath alone, out of context (Vivado)

# Host-specific tool paths go in local.mk (not versioned), e.g.
#   IVERILOG = /opt/iverilog/bin/iverilog
#   VVP      = /opt/iverilog/bin/vvp
#   VIVADO   = /opt/vivado-launcher.sh
-include local.mk
IVERILOG ?= iverilog
VVP      ?= vvp
VIVADO   ?= vivado
PYTHON   ?= python3 -I
JOBS     ?= 8

RTL    := $(wildcard rtl/*.v) rtl/gen/rx_gain_rom.v
TABLES := rtl/gen/sincos_qw.mem rtl/gen/rx_gain_rom.v
SIMLIB := sim/models/unisim_models.v sim/axi_mem_slave.v

.PHONY: all tables sim sim-nco sim-core sim-fft sim-split sim-fir sim-chain pfb hf vhf ci clean

all: sim

tables: $(TABLES)
$(TABLES): scripts/gen_tables.py
	$(PYTHON) scripts/gen_tables.py

sim: sim-nco sim-core sim-fft sim-split sim-fir sim-chain

sim/out:
	mkdir -p $@

sim-nco: $(TABLES) | sim/out
	$(IVERILOG) -g2012 -Wall -o sim/out/tb_nco.vvp sim/tb_nco.v rtl/nco.v
	cd sim && $(VVP) -n out/tb_nco.vvp
	$(PYTHON) sim/analyze.py nco sim/out/nco.txt

sim-fft: | sim/out
	$(IVERILOG) -g2012 -Wall -o sim/out/tb_fft.vvp sim/tb_fft.v rtl/fft/delay_line.v rtl/fft/r22_bf.v rtl/fft/r22_tw.v rtl/fft/r22sdf_fft.v
	cd sim && $(VVP) -n out/tb_fft.vvp | tee out/tb_fft.log
	grep -q "tb_fft: PASSED" sim/out/tb_fft.log

sim-split: | sim/out
	$(IVERILOG) -g2012 -Wall -o sim/out/tb_split.vvp sim/tb_split.v rtl/fft/pfb_split.v
	cd sim && $(VVP) -n out/tb_split.vvp | tee out/tb_split.log
	grep -q "tb_split: PASSED" sim/out/tb_split.log

sim-fir: | sim/out
	$(IVERILOG) -g2012 -Wall -o sim/out/tb_fir.vvp sim/tb_fir.v rtl/fft/pfb_fir.v
	cd sim && $(VVP) -n out/tb_fir.vvp | tee out/tb_fir.log
	grep -q "tb_fir: PASSED" sim/out/tb_fir.log

PFB_RTL := rtl/fft/delay_line.v rtl/fft/r22_bf.v rtl/fft/r22_tw.v rtl/fft/r22sdf_fft.v \
           rtl/fft/pfb_split.v rtl/fft/pfb_fir.v rtl/fft/pfb_chain.v
sim-chain: | sim/out
	$(IVERILOG) -g2012 -Wall -o sim/out/tb_chain.vvp sim/tb_chain.v $(PFB_RTL)
	cd sim && $(VVP) -n out/tb_chain.vvp | tee out/tb_chain.log
	grep -q "tb_chain: PASSED" sim/out/tb_chain.log

sim-core: $(TABLES) | sim/out
	$(IVERILOG) -g2012 -Wall -I rtl -o sim/out/tb_core.vvp sim/tb_core.v $(SIMLIB) $(RTL)
	cd sim && $(VVP) -n out/tb_core.vvp | tee out/tb_core.log
	grep -q "tb_core: PASSED" sim/out/tb_core.log
	$(PYTHON) sim/analyze.py rx  sim/out/rx_mem.txt 5 0:7.073e6 1:7.0775e6 11:14.2e6
	$(PYTHON) sim/analyze.py rx  sim/out/rx_mem2.txt 5 0:7.073e6 1:7.0775e6 11:14.2e6
	$(PYTHON) sim/analyze.py wf  sim/out/wf0_mem.txt 4 6.0745e6
	$(PYTHON) sim/analyze.py wf  sim/out/wf1_mem.txt 1 12.2005e6

# the channelizer datapath alone (out of context): resources and timing
pfb:
	mkdir -p build
	$(VIVADO) -mode batch -nojournal -log build/pfb.log -source vivado/synth_pfb.tcl -tclargs $(JOBS)

hf vhf: $(TABLES)
	mkdir -p build
	$(VIVADO) -mode batch -nojournal -log build/$@.log -source vivado/build.tcl -tclargs $@ $(JOBS)

ci:
	scripts/ci-build.sh

clean:
	rm -rf sim/out build .Xil
