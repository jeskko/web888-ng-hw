# SPDX-License-Identifier: GPL-3.0-or-later
# Web-888 open FPGA
#   make tables      regenerate ROM tables (rtl/gen)
#   make sim         run all simulations (Icarus Verilog) + analysis
#   make hf / vhf    build bitstreams with Vivado (PATH or local.mk)

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

.PHONY: all tables sim sim-nco sim-core hf vhf clean

all: sim

tables: $(TABLES)
$(TABLES): scripts/gen_tables.py
	$(PYTHON) scripts/gen_tables.py

sim: sim-nco sim-core

sim/out:
	mkdir -p $@

sim-nco: $(TABLES) | sim/out
	$(IVERILOG) -g2012 -Wall -o sim/out/tb_nco.vvp sim/tb_nco.v rtl/nco.v
	cd sim && $(VVP) -n out/tb_nco.vvp
	$(PYTHON) sim/analyze.py nco sim/out/nco.txt

sim-core: $(TABLES) | sim/out
	$(IVERILOG) -g2012 -Wall -I rtl -o sim/out/tb_core.vvp sim/tb_core.v $(SIMLIB) $(RTL)
	cd sim && $(VVP) -n out/tb_core.vvp | tee out/tb_core.log
	grep -q "tb_core: PASSED" sim/out/tb_core.log
	$(PYTHON) sim/analyze.py rx  sim/out/rx_mem.txt 5 0:7.073e6 1:7.0775e6 11:14.2e6
	$(PYTHON) sim/analyze.py rx  sim/out/rx_mem2.txt 5 0:7.073e6 1:7.0775e6 11:14.2e6
	$(PYTHON) sim/analyze.py wf  sim/out/wf0_mem.txt 4 6.0745e6
	$(PYTHON) sim/analyze.py wf  sim/out/wf1_mem.txt 1 12.2005e6

hf vhf: $(TABLES)
	mkdir -p build
	$(VIVADO) -mode batch -nojournal -log build/$@.log -source vivado/build.tcl -tclargs $@ $(JOBS)

clean:
	rm -rf sim/out build .Xil
